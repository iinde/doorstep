import SwiftUI
import AVKit
import RingClient
@preconcurrency import WebRTC

/// The Wall: every camera live, the Day Strip, and the latest Moments.
/// Spec: docs/DESIGN-BRIEF.md (section 2, 3, 8).
public struct WallView: View {
    let devices: [RingDevice]
    let events: [RingEvent]
    @ObservedObject var streamManager: MultiStreamManager
    let onFocus: (RingDevice) -> Void
    let onSettings: () -> Void

    /// Clip currently playing in place of a tile's live video, keyed by device id.
    @State private var playing: [Int: PlayingClip] = [:]
    @State private var now = Date()
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var reviews = ReviewStore.shared
    @ObservedObject private var tagIndex = TagIndex.shared  // refresh when Vision finds people
    @ObservedObject private var parcels = ParcelStore.shared
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    struct PlayingClip: Equatable {
        let event: RingEvent
        var player: AVPlayer?
        var failed = false
        static func == (a: PlayingClip, b: PlayingClip) -> Bool {
            a.event.id == b.event.id && a.player === b.player && a.failed == b.failed
        }
    }

    public init(devices: [RingDevice], events: [RingEvent], streamManager: MultiStreamManager,
                onFocus: @escaping (RingDevice) -> Void, onSettings: @escaping () -> Void) {
        self.devices = devices
        self.events = events
        self.streamManager = streamManager
        self.onFocus = onFocus
        self.onSettings = onSettings
    }

    private var moments: [Moment] { MomentBuilder.build(from: events) }

    private var columns: Int {
        switch devices.count {
        case 0, 1: return 1
        case 2, 3, 4: return 2
        default: return 3
        }
    }

    private var tileWidth: CGFloat {
        let inner = DS.wallWidth - DS.margin * 2
        return (inner - DS.gutter * CGFloat(columns - 1)) / CGFloat(columns)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, DS.gutter)
            wall
                .padding(.bottom, DS.margin)
            DayStrip(
                devices: devices,
                events: events.filter(MomentBuilder.isOutsideEvent),
                now: now,
                liveDeviceIds: Set(devices.map(\.id).filter { streamManager.hasVideoTrack(for: $0) }),
                onPlay: play
            )
            .padding(.bottom, DS.margin)
            if !parcels.parcels.filter(\.isExpectedToday).isEmpty {
                expectingStrip
                    .padding(.bottom, DS.gutter)
            }
            momentsList
        }
        .padding(DS.margin)
        .frame(width: DS.wallWidth, alignment: .topLeading)
        .background(Backdrop())
        .background(cameraShortcuts)
        .onReceive(clock) { now = $0 }
    }

    /// ⌘1…⌘9 open a camera.
    private var cameraShortcuts: some View {
        ZStack {
            ForEach(Array(devices.prefix(9).enumerated()), id: \.element.id) { i, d in
                Button("") { onFocus(d) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(now, format: .dateTime.hour().minute())
                .font(DS.display)
                .foregroundStyle(DS.paper)
            Text(now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(DS.body)
                .foregroundStyle(DS.ash)
            Spacer()
            ModeMenu()
            todaySummary
            Button {
                openWindow(id: "command")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.ash)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .help("Command centre (⌘K)")
            .accessibilityLabel("Command centre")
            Button {
                openWindow(id: "expect")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "shippingbox")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.ash)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("I'm expecting a parcel")
            .accessibilityLabel("I'm expecting a parcel")
            Button {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("History")
                    .font(DS.body)
                    .foregroundStyle(DS.paper.opacity(0.85))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(DS.well, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("y", modifiers: .command)
            .help("Open History (⌘Y)")
            Menu {
                Button("Settings…", action: onSettings)
                    .keyboardShortcut(",", modifiers: .command)
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                Divider()
                Button("Quit Doorstep") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.ash)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Settings and more")
        }
        .frame(height: 44)
    }

    /// One sentence about today. Amber only if a human needs attention.
    private var todaySummary: some View {
        let today = moments.filter { Calendar.current.isDateInToday($0.end) }
        // Loud only for what you haven't looked at yet.
        let rings = today.filter { $0.tier == .doorbell && !reviews.isReviewed($0) }.count
        let people = today.filter { $0.tier == .people && !reviews.isReviewed($0) }.count
        let text: String
        let loud: Bool
        if rings > 0 {
            text = rings == 1 ? "Doorbell rang" : "Doorbell rang \(rings) times"
            loud = true
        } else if people > 0 {
            text = people == 1 ? "1 new visit" : "\(people) new visits"
            loud = true
        } else if !today.isEmpty {
            text = "All caught up"
            loud = false
        } else {
            text = "Quiet today"
            loud = false
        }
        return Text(text)
            .font(DS.body)
            .foregroundStyle(loud ? DS.porchlight : DS.ash)
    }

    // MARK: Wall

    private var wall: some View {
        let rows = stride(from: 0, to: devices.count, by: columns).map {
            Array(devices[$0..<min($0 + columns, devices.count)])
        }
        return VStack(spacing: DS.gutter) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: DS.gutter) {
                    ForEach(rows[r], id: \.id) { device in
                        tile(for: device)
                    }
                    if rows[r].count < columns { Spacer(minLength: 0) }
                }
            }
        }
    }

    private func tile(for device: RingDevice) -> some View {
        WallTile(
            device: device,
            track: streamManager.getVideoTrack(for: device.id),
            state: streamManager.getState(for: device.id),
            clip: playing[device.id],
            lastEvent: events.filter { $0.deviceId == device.id && MomentBuilder.isOutsideEvent($0) }
                .max { $0.createdAt < $1.createdAt },
            now: now,
            onTap: { onFocus(device) },
            onCloseClip: { stopClip(device.id) }
        )
        .frame(width: tileWidth, height: tileWidth * 9 / 16)
    }

    // MARK: Expecting

    /// Parcels due today, with the door one click away.
    private var expectingStrip: some View {
        let due = parcels.parcels.filter(\.isExpectedToday)
        let doorbell = devices.first { $0.deviceType == .doorbell }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(due) { p in
                HStack(spacing: 10) {
                    Image(systemName: p.carrier?.symbol ?? "shippingbox.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.porchlight)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(DeliveryWatch.line(for: p)).font(DS.bodyStrong).foregroundStyle(DS.paper).lineLimit(1)
                        if let text = p.carrierStatus {
                            Text(text).font(DS.meta).foregroundStyle(DS.ash).lineLimit(1)
                        } else if let c = p.carrier {
                            Text("\(c.rawValue). Doorstep will show you the door when someone arrives.")
                                .font(DS.meta).foregroundStyle(DS.ash).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let url = p.trackingURL {
                        pill("Track") { NSWorkspace.shared.open(url) }
                    }
                    if let doorbell {
                        pill("Watch door", strong: true) {
                            DoorbellCallController.shared.show(device: doorbell, event: nil, title: "\(doorbell.name), live")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(DS.porchlight.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.porchlight.opacity(0.25)))
            }
        }
    }

    private func pill(_ title: String, strong: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(strong ? DS.bodyStrong : DS.body)
                .foregroundStyle(strong ? DS.night : DS.paper)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(strong ? DS.porchlight : DS.well, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Moments

    private var momentsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            let recent = Array(moments.prefix(3))
            if recent.isEmpty {
                Text("Nothing has happened in the last day.")
                    .font(DS.body)
                    .foregroundStyle(DS.ash)
                    .frame(height: 44, alignment: .leading)
            }
            ForEach(recent) { m in
                MomentRow(moment: m, now: now, isUnreviewed: m.tier >= .people && !reviews.isReviewed(m)) {
                    reviews.markReviewed(m)
                    play(m.headline)
                }
            }
        }
    }

    // MARK: Playback

    private func play(_ event: RingEvent) {
        if DemoMode.isOn { return }
        guard let deviceId = event.deviceId ?? devices.first(where: { $0.name == event.deviceName })?.id else { return }
        withAnimation(DS.crossfade) {
            playing[deviceId] = PlayingClip(event: event, player: nil)
        }
        Task {
            do {
                let url = try await RingClient.shared.getEventVideoURL(eventId: event.id)
                guard playing[deviceId]?.event.id == event.id else { return }
                let player = AVPlayer(url: url)
                player.isMuted = true
                player.play()
                withAnimation(DS.crossfade) { playing[deviceId]?.player = player }
            } catch {
                guard playing[deviceId]?.event.id == event.id else { return }
                playing[deviceId]?.failed = true
            }
        }
    }

    private func stopClip(_ deviceId: Int) {
        playing[deviceId]?.player?.pause()
        withAnimation(DS.crossfade) { _ = playing.removeValue(forKey: deviceId) }
    }
}

// MARK: - Tile

struct WallTile: View {
    let device: RingDevice
    let track: RTCVideoTrack?
    let state: LiveViewSession.State
    let clip: WallView.PlayingClip?
    let lastEvent: RingEvent?
    let now: Date
    let onTap: () -> Void
    let onCloseClip: () -> Void

    @State private var hovering = false
    private var streamManager: MultiStreamManager { .shared }
    /// Frames are actually arriving (a connected track can still be silent).
    @State private var hasPicture = false
    /// Connected but silent for a while: say so instead of showing a dark box.
    @State private var silent = false
    @State private var frameClock = FrameClock()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DS.slate

            if DemoMode.isOn && clip == nil {
                DemoLivePicture(deviceId: device.id)
            } else if clip == nil, BatterySaver.sleeping(device, track: track != nil) {
                BatteryStill(device: device, lastEvent: lastEvent)
            }
            if !DemoMode.isOn && track != nil && !hasPicture && !gaveUp {
                noPictureLine
                    .opacity(silent ? 1 : 0)
            }
            if gaveUp && !hasPicture && !DemoMode.isOn {
                gaveUpLine
            }

            if let track {
                // The shader does aspect-fill; the view must stay exactly tile-sized,
                // because AppKit layers ignore SwiftUI clipping.
                WebRTCVideoView(videoTrack: track, isPortrait: false, captureHandler: nil, fill: true,
                                label: device.name,
                                onFirstFrame: {
                                    withAnimation(DS.crossfade) { hasPicture = true }
                                    streamManager.markFrame(device.id)
                                },
                                frameClock: frameClock)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(hasPicture ? 1 : 0)
                    .transition(.opacity)
                    // A stream can swap in a new track object; rebuild the view so the
                    // renderer is attached to the track that's actually live.
                    .id(ObjectIdentifier(track))
                    .task(id: ObjectIdentifier(track)) {
                        hasPicture = false
                        silent = false
                        try? await Task.sleep(for: .seconds(10))
                        // A cancelled sleep returns at once; never act on a cancelled task.
                        guard !Task.isCancelled else { return }
                        if !hasPicture {
                            withAnimation(DS.crossfade) { silent = true }
                            // Unstructured: this view's task is cancelled when the track changes,
                            // and that must not cancel the reconnect it asked for.
                            let id = device.id
                            Task { await streamManager.nudge(deviceId: id) }
                            return
                        }
                        // Watchdog: a feed that was flowing and stops for 6s gets a fresh session.
                        var healthySeconds = 0
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            // 30s of steady video earns back the reconnect budget.
                            if hasPicture && !frameClock.stalled(after: 6) {
                                healthySeconds += 3
                                if healthySeconds == 30 { streamManager.markHealthy(device.id) }
                            }
                            if hasPicture && frameClock.stalled(after: 6) {
                                NSLog("🧊 \(device.name) froze; asking for a fresh stream")
                                withAnimation(DS.crossfade) { hasPicture = false }
                                let id = device.id
                                Task { await streamManager.restartStream(deviceId: id) }
                                return
                            }
                        }
                    }
            } else if !DemoMode.isOn && !gaveUp && !BatterySaver.sleeping(device, track: track != nil) {
                statusLine
            }

            if let clip {
                clipLayer(clip)
                    .transition(.opacity)
            }

            // Name typeset onto the picture, over a soft gradient. No chip.
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .firstTextBaseline) {
                Text(device.name)
                    .font(DS.bodyStrong)
                    .foregroundStyle(DS.paper)
                Spacer()
                trailingMeta
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if clip == nil { onTap() } }
        .onHover { hovering = $0 }
        .animation(DS.crossfade, value: track != nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name), \(hasPicture ? "live" : silent ? "no picture" : "not live")")
        .accessibilityHint("Opens this camera")
    }

    @ViewBuilder
    private var trailingMeta: some View {
        if let clip {
            Text(clip.event.createdAt, format: .dateTime.hour().minute())
                .font(DS.monoMeta)
                .foregroundStyle(DS.paper.opacity(0.8))
        } else if let level = device.batteryLevel, level <= 20 {
            Text("Battery \(level)%")
                .font(DS.monoMeta)
                .foregroundStyle(DS.ash)
        } else if hovering, let lastEvent {
            Text(lastSeen(lastEvent))
                .font(DS.meta)
                .foregroundStyle(DS.paper.opacity(0.75))
        }
    }

    private func lastSeen(_ e: RingEvent) -> String {
        let mins = Int(now.timeIntervalSince(e.createdAt) / 60)
        if mins < 1 { return "Activity just now" }
        if mins < 60 { return "Last activity \(mins)m ago" }
        return "Last activity \(mins / 60)h ago"
    }

    private var gaveUp: Bool { streamManager.gaveUp.contains(device.id) }

    private var gaveUpLine: some View {
        VStack(spacing: 6) {
            Text("No picture from \(device.name)")
                .font(DS.bodyStrong)
                .foregroundStyle(DS.paper.opacity(0.85))
            Text("Its privacy cover may be closed, or it's asleep.")
                .font(DS.meta)
                .foregroundStyle(DS.ash)
            Button {
                Task { await streamManager.retry(deviceId: device.id) }
            } label: {
                Text("Try again")
                    .font(DS.meta)
                    .foregroundStyle(DS.paper)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 16)
    }

    private var noPictureLine: some View {
        VStack(spacing: 4) {
            ProgressView().controlSize(.small).tint(DS.ash)
            Text("Connected, waiting for video")
                .font(DS.meta)
                .foregroundStyle(DS.ash)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 16)
    }

    private var statusLine: some View {
        let text: String
        let color = DS.ash
        switch state {
        case .failed, .disconnected: text = gaveUp ? "" : "Reconnecting"
        case .idle: text = "Waiting"
        default: text = "Connecting"
        }
        return Text(text)
            .font(DS.meta)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func clipLayer(_ clip: WallView.PlayingClip) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            if let player = clip.player {
                ClipPlayerView(player: player, showsControls: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(clip.failed ? "Clip unavailable" : "Loading clip")
                    .font(DS.meta)
                    .foregroundStyle(clip.failed ? DS.ember : DS.ash)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button(action: onCloseClip) {
                Text("Back to live")
                    .font(DS.meta)
                    .foregroundStyle(DS.paper)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel("Back to live view")
        }
    }
}

// MARK: - Moment row

struct MomentRow: View {
    let moment: Moment
    let now: Date
    var isUnreviewed = false
    let onTap: () -> Void
    @State private var hovering = false

    private var mark: Color {
        switch moment.tier {
        case .doorbell: return DS.porchlight
        case .people: return isUnreviewed ? DS.porchlight : DS.paper
        case .activity: return DS.ash
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(moment.end, format: .dateTime.hour().minute())
                    .font(DS.monoBody)
                    .foregroundStyle(DS.ash)
                    .frame(width: 48, alignment: .leading)
                Circle()
                    .fill(mark)
                    .frame(width: 6, height: 6)
                Text(moment.title)
                    .font(moment.tier == .activity ? DS.body : DS.bodyStrong)
                    .foregroundStyle(moment.tier == .activity ? DS.ash : DS.paper)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(DS.meta)
                    .foregroundStyle(DS.ash)
            }
            .frame(height: 44)
            .padding(.horizontal, 8)
            .background(hovering ? DS.well : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(moment.title), \(detail)")
        .accessibilityHint("Plays the clip")
    }

    private var detail: String {
        let n = moment.events.count
        let mins = Int(now.timeIntervalSince(moment.end) / 60)
        let ago = mins < 1 ? "just now" : mins < 60 ? "\(mins)m ago" : "\(mins / 60)h ago"
        return n > 1 ? "\(n) clips · \(ago)" : ago
    }
}
