import SwiftUI
import RingClient
@preconcurrency import WebRTC

/// The command centre: a full window (or full screen) with every camera, the map, the radar
/// and the numbers. Spec: docs/COMMAND-CENTRE.md.
public struct CommandCentreView: View {
    let devices: [RingDevice]
    let events: [RingEvent]

    public enum Panel: String, CaseIterable, Identifiable {
        case live = "Live", map = "Map", radar = "Radar", insights = "Insights"
        public var id: String { rawValue }
        var symbol: String {
            switch self {
            case .live: return "square.grid.2x2"
            case .map: return "map"
            case .radar: return "dot.radiowaves.left.and.right"
            case .insights: return "chart.bar.xaxis"
            }
        }
    }

    @State private var panel: Panel = .live
    @State private var now = Date()
    @ObservedObject private var streams = MultiStreamManager.shared
    @ObservedObject private var recorder = RecorderController.shared
    @ObservedObject private var parcels = ParcelStore.shared
    @ObservedObject private var intel = LiveIntel.shared
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(devices: [RingDevice], events: [RingEvent]) {
        self.devices = devices.filter { $0.deviceType != .chime }
        self.events = events
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.well)
            Group {
                switch panel {
                case .live: LiveGrid(devices: devices, events: events)
                case .map: MapPanel(devices: devices, events: events)
                case .radar: RadarPanel(devices: devices, events: events)
                case .insights: InsightsPanel(devices: devices, seed: events)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.night)
        .preferredColorScheme(.dark)
        .onReceive(clock) { now = $0 }
        .task { await streams.addViewer(devices: BatterySaver.streamable(devices, awake: [])) }
        .onDisappear {
            LiveAnalysis.shared.unwatchAll()
            Task { await MultiStreamManager.shared.removeViewer() }
        }
        .background(panelShortcuts)
    }

    private var header: some View {
        HStack(spacing: 18) {
            DoorstepMark(size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(now, format: .dateTime.hour().minute().second())
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DS.paper)
                Text(now, format: .dateTime.weekday(.wide).day().month(.wide)).font(DS.meta).foregroundStyle(DS.ash)
            }
            Spacer()
            Picker("", selection: $panel) {
                ForEach(Panel.allCases) { p in Label(p.rawValue, systemImage: p.symbol).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)
            Spacer()
            HStack(spacing: 14) {
                status("dot.radiowaves.up.forward", "\(liveCount) live", liveCount > 0 ? DS.paper : DS.ash)
                if !recorder.recording.isEmpty {
                    status("record.circle", "Recording \(recorder.recording.count)", DS.ember)
                }
                let people = intel.cameras.values.filter { !$0.people.isEmpty }.count
                if people > 0 { status("figure.walk", "\(people) with people now", DS.porchlight) }
                let due = parcels.parcels.filter(\.isExpectedToday).count
                if due > 0 { status("shippingbox.fill", "\(due) due today", DS.porchlight) }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var liveCount: Int { DemoMode.isOn ? devices.count : devices.filter { streams.hasVideoTrack(for: $0.id) }.count }

    private func status(_ symbol: String, _ text: String, _ colour: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(DS.meta)
        }
        .foregroundStyle(colour)
    }

    /// ⌘1…⌘4 switch panels.
    private var panelShortcuts: some View {
        ZStack {
            ForEach(Array(Panel.allCases.enumerated()), id: \.element) { i, p in
                Button("") { withAnimation(DS.settle) { panel = p } }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Live: every camera, big

struct LiveGrid: View {
    let devices: [RingDevice]
    let events: [RingEvent]
    @ObservedObject private var streams = MultiStreamManager.shared
    @ObservedObject private var intel = LiveIntel.shared

    var body: some View {
        GeometryReader { geo in
            let cols = devices.count <= 1 ? 1 : devices.count <= 4 ? 2 : 3
            let rows = Int(ceil(Double(devices.count) / Double(cols)))
            let gap: CGFloat = 12
            let w = (geo.size.width - 48 - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let h = min(w * 9 / 16, (geo.size.height - 48 - gap * CGFloat(rows - 1)) / CGFloat(max(rows, 1)))
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(devices[(r * cols)..<min(r * cols + cols, devices.count)], id: \.id) { d in
                            tile(d).frame(width: h * 16 / 9, height: h)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    private func tile(_ d: RingDevice) -> some View {
        let now = intel.cameras[d.id]
        return ZStack(alignment: .bottomLeading) {
            DS.slate
            if DemoMode.isOn {
                DemoLivePicture(deviceId: d.id)
            } else if let track = streams.getVideoTrack(for: d.id) {
                WebRTCVideoView(videoTrack: track, isPortrait: false, captureHandler: nil, fill: true, label: "\(d.name) (centre)")
                    .id(ObjectIdentifier(track))
                    .onAppear { LiveAnalysis.shared.watch(d.id, track: track) }
            } else if BatterySaver.sleeping(d, track: false) {
                BatteryStill(device: d, lastEvent: events.filter { $0.deviceId == d.id }.max { $0.createdAt < $1.createdAt })
                    .onTapGesture { Task { await streams.startAllStreams(for: [d]) } }
            } else {
                Text(streams.gaveUp.contains(d.id) ? "No picture from \(d.name)" : "Connecting to \(d.name)")
                    .font(DS.body).foregroundStyle(DS.ash)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // People boxes from this Mac's live analysis.
            GeometryReader { g in
                ForEach(Array((now?.people ?? []).enumerated()), id: \.offset) { _, box in
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(now?.approaching == true ? DS.porchlight : DS.paper.opacity(0.8), lineWidth: 2)
                        .frame(width: box.width * g.size.width, height: box.height * g.size.height)
                        .position(x: box.midX * g.size.width, y: (1 - box.midY) * g.size.height)
                }
            }
            HStack(spacing: 8) {
                Text(d.name).font(DS.bodyStrong)
                if let now, !now.people.isEmpty {
                    Text(now.approaching ? "Approaching" : "Person").font(DS.meta)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(now.approaching ? DS.porchlight : DS.well, in: Capsule())
                        .foregroundStyle(now.approaching ? DS.night : DS.paper)
                }
                if RecorderController.shared.recording[d.id] != nil {
                    Image(systemName: "record.circle").foregroundStyle(DS.ember).font(.system(size: 11))
                }
            }
            .foregroundStyle(DS.paper)
            .padding(10)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            Button("Float this camera") { FloatingCamera.shared.show(d) }
        }
    }
}
