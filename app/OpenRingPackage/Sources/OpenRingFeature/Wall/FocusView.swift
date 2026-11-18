import SwiftUI
import AVKit
import RingClient
@preconcurrency import WebRTC

/// Focus: one camera large, at the same width as the Wall so the window never jumps.
/// Talk, sound, light, siren; this camera's day; its moments.
public struct FocusView: View {
    let device: RingDevice
    let devices: [RingDevice]
    let events: [RingEvent]
    @ObservedObject var streamManager: MultiStreamManager
    let onSwitch: (RingDevice) -> Void
    let onBack: () -> Void

    @State private var clip: WallView.PlayingClip?
    @ObservedObject private var tagIndex = TagIndex.shared
    @State private var hasPicture = false
    @State private var silent = false
    @State private var frameClock = FrameClock()
    @State private var isTalking = false
    @State private var isMuted = false
    @State private var lightOn = false
    @State private var sirenArmed = false   // first tap arms, second tap sounds
    @State private var sirenOn = false
    @State private var controlError: String?
    @State private var now = Date()
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    public init(device: RingDevice, devices: [RingDevice], events: [RingEvent],
                streamManager: MultiStreamManager,
                onSwitch: @escaping (RingDevice) -> Void, onBack: @escaping () -> Void) {
        self.device = device
        self.devices = devices
        self.events = events
        self.streamManager = streamManager
        self.onSwitch = onSwitch
        self.onBack = onBack
    }

    private var track: RTCVideoTrack? { streamManager.getVideoTrack(for: device.id) }
    private var myEvents: [RingEvent] {
        events.filter { ($0.deviceId == device.id || ($0.deviceId == nil && $0.deviceName == device.name))
            && MomentBuilder.isOutsideEvent($0) }
    }
    private var videoWidth: CGFloat { DS.wallWidth - DS.margin * 2 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.bottom, DS.gutter)
            video
                .frame(width: videoWidth, height: videoWidth * 9 / 16)
                .padding(.bottom, 12)
            controls
                .padding(.bottom, DS.margin)
            DayStrip(
                devices: [device],
                events: myEvents,
                now: now,
                liveDeviceIds: hasPicture ? [device.id] : [],
                onPlay: play
            )
            .padding(.bottom, DS.margin)
            moments
        }
        .padding(DS.margin)
        .frame(width: DS.wallWidth, alignment: .topLeading)
        .background(Backdrop())
        .onReceive(clock) { now = $0 }
        .onExitCommand(perform: onBack)
        .onChange(of: device.id) { old, _ in resetForNewCamera(leaving: old) }
        .onDisappear {
            let id = device.id
            Task { await streamManager.endTalkMode(for: id) }
        }
        .background(keyboardShortcuts)
    }

    // MARK: Top bar: back, and the cameras as words

    private var topBar: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("All cameras").font(DS.body)
                }
                .foregroundStyle(DS.ash)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to all cameras")

            Button { FloatingCamera.shared.show(device) } label: {
                Label("Float", systemImage: "pip.enter").font(DS.meta).foregroundStyle(DS.ash)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .help("Keep this camera on top while you work")

            Spacer()

            HStack(spacing: 18) {
                ForEach(devices, id: \.id) { d in
                    Button { onSwitch(d) } label: {
                        Text(d.name)
                            .font(d.id == device.id ? DS.bodyStrong : DS.body)
                            .foregroundStyle(d.id == device.id ? DS.paper : DS.ash)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(d.id == device.id ? .isSelected : [])
                }
            }
        }
        .frame(height: 44)
    }

    // MARK: Video

    private var video: some View {
        ZStack(alignment: .topLeading) {
            DS.slate

            if DemoMode.isOn {
                DemoLivePicture(deviceId: device.id)
            } else if let track {
                if !hasPicture {
                    Text(silent ? "No picture coming through" : "Connecting")
                        .font(DS.meta)
                        .foregroundStyle(DS.ash)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                WebRTCVideoView(videoTrack: track, isPortrait: false, captureHandler: nil, fill: true,
                                label: "\(device.name) (focus)",
                                onFirstFrame: {
                                    withAnimation(DS.crossfade) { hasPicture = true }
                                    streamManager.markFrame(device.id)
                                },
                                frameClock: frameClock)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(hasPicture ? 1 : 0)
                    .id(ObjectIdentifier(track))
                    .task(id: ObjectIdentifier(track)) {
                        hasPicture = false
                        silent = false
                        try? await Task.sleep(for: .seconds(10))
                        guard !Task.isCancelled else { return }
                        if !hasPicture { withAnimation(DS.crossfade) { silent = true } }
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
            } else {
                Text("Connecting")
                    .font(DS.meta)
                    .foregroundStyle(DS.ash)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let clip {
                ZStack {
                    Color.black
                    if let player = clip.player {
                        ClipPlayerView(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(clip.failed ? "Clip unavailable" : "Loading clip")
                            .font(DS.meta)
                            .foregroundStyle(clip.failed ? DS.ember : DS.ash)
                    }
                }
                .transition(.opacity)
            }

            // Where you are in time, set in type at the top-left.
            HStack(spacing: 6) {
                if let clip {
                    Text(clip.event.createdAt, format: .dateTime.hour().minute())
                        .font(DS.monoMeta).foregroundStyle(DS.paper)
                    Text("recorded").font(DS.meta).foregroundStyle(DS.paper.opacity(0.7))
                } else if hasPicture {
                    Text(now, format: .dateTime.hour().minute())
                        .font(DS.monoMeta).foregroundStyle(DS.paper)
                    Text("live").font(DS.meta).foregroundStyle(DS.paper.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 64)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false),
                alignment: .top
            )

            if clip != nil {
                Button { stopClip() } label: {
                    Text("Back to live")
                        .font(DS.meta).foregroundStyle(DS.paper)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .accessibilityLabel("Back to live view")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
    }

    // MARK: Controls: one primary action (talk), the rest quiet

    private var controls: some View {
        HStack(spacing: 10) {
            talkButton
            Spacer()
            if let controlError {
                Text(controlError).font(DS.meta).foregroundStyle(DS.ember)
            }
            iconToggle(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       label: isMuted ? "Unmute" : "Mute", on: !isMuted) {
                isMuted.toggle()
                streamManager.setMuted(isMuted)
            }
            if device.hasFloodlight {
                iconToggle(lightOn ? "lightbulb.fill" : "lightbulb", label: lightOn ? "Light off" : "Light on",
                           on: lightOn, tint: lightOn ? DS.porchlight : DS.paper) { toggleLight() }
            }
            if device.hasSiren {
                sirenButton
            }
        }
        .frame(height: 40)
    }

    private var talkButton: some View {
        HStack(spacing: 8) {
            Image(systemName: isTalking ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .semibold))
            Text(streamManager.connectingMic.contains(device.id) ? "Connecting mic…"
                 : isTalking ? "Talking" : "Hold to talk")
                .font(DS.bodyStrong)
        }
        .foregroundStyle(isTalking ? DS.night : DS.paper)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(isTalking ? DS.porchlight : DS.well, in: Capsule())
        .animation(DS.settle, value: isTalking)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isTalking { startTalking() } }
                .onEnded { _ in stopTalking() }
        )
        .accessibilityElement()
        .accessibilityLabel("Hold to talk")
        .accessibilityAddTraits(.isButton)
        .help("Hold to talk, or hold Space")
    }

    private var sirenButton: some View {
        Button {
            if sirenOn { setSiren(false) }
            else if sirenArmed { setSiren(true) }
            else {
                withAnimation(DS.settle) { sirenArmed = true }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(DS.settle) { sirenArmed = false }
                }
            }
        } label: {
            Text(sirenOn ? "Stop siren" : sirenArmed ? "Tap again to sound" : "Siren")
                .font(DS.bodyStrong)
                .foregroundStyle(sirenOn || sirenArmed ? DS.night : DS.ember)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(sirenOn || sirenArmed ? DS.ember : DS.well, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sirenOn ? "Stop siren" : "Siren, tap twice to sound")
    }

    private func iconToggle(_ symbol: String, label: String, on: Bool, tint: Color = DS.paper,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(on ? tint : DS.ash)
                .frame(width: 36, height: 36)
                .background(DS.well, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: Moments for this camera

    private var moments: some View {
        let list = Array(MomentBuilder.build(from: myEvents).prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                Text("Nothing at \(device.name) in the last day.")
                    .font(DS.body).foregroundStyle(DS.ash)
                    .frame(height: 44, alignment: .leading)
            }
            ForEach(list) { m in
                MomentRow(moment: m, now: now) { play(m.headline) }
            }
        }
    }

    // MARK: Keyboard: Esc back, arrows switch, Space talks

    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func step(_ delta: Int) {
        guard let i = devices.firstIndex(where: { $0.id == device.id }) else { return }
        let j = (i + delta + devices.count) % devices.count
        onSwitch(devices[j])
    }

    // MARK: Actions

    private func resetForNewCamera(leaving old: Int) {
        stopClip()
        if isTalking { stopTalking() }
        // Leaving that camera: back to listen-only so the microphone is released.
        Task { await streamManager.endTalkMode(for: old) }
        lightOn = false
        sirenOn = false
        sirenArmed = false
        controlError = nil
    }

    private func startTalking() {
        isTalking = true
        let id = device.id
        Task { await streamManager.startTalking(for: id) }
    }

    private func stopTalking() {
        guard isTalking else { return }
        isTalking = false
        let id = device.id
        Task { await streamManager.stopTalking(for: id) }
    }

    private func toggleLight() {
        let target = !lightOn
        withAnimation(DS.settle) { lightOn = target }
        let id = device.id
        Task {
            do { try await RingClient.shared.setFloodlight(deviceId: id, enabled: target) }
            catch {
                withAnimation(DS.settle) { lightOn = !target }
                flash("Light didn't respond")
            }
        }
    }

    private func setSiren(_ on: Bool) {
        withAnimation(DS.settle) { sirenOn = on; sirenArmed = false }
        let id = device.id
        Task {
            do { try await RingClient.shared.setSiren(deviceId: id, enabled: on) }
            catch {
                withAnimation(DS.settle) { sirenOn = !on }
                flash("Siren didn't respond")
            }
        }
    }

    private func flash(_ message: String) {
        withAnimation(DS.settle) { controlError = message }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(DS.settle) { if controlError == message { controlError = nil } }
        }
    }

    private func play(_ event: RingEvent) {
        withAnimation(DS.crossfade) { clip = WallView.PlayingClip(event: event, player: nil) }
        Task {
            do {
                let url = try await RingClient.shared.getEventVideoURL(eventId: event.id)
                guard clip?.event.id == event.id else { return }
                let player = AVPlayer(url: url)
                player.play()
                withAnimation(DS.crossfade) { clip?.player = player }
            } catch {
                guard clip?.event.id == event.id else { return }
                clip?.failed = true
            }
        }
    }

    private func stopClip() {
        clip?.player?.pause()
        withAnimation(DS.crossfade) { clip = nil }
    }
}
