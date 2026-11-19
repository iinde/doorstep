import SwiftUI
import AppKit
import RingClient

/// Doorstep's one window: everything that used to be separate windows (Command Centre,
/// History) is a section here, switched from the rail on the left.
public struct MainWindow: View {
    let devices: [RingDevice]
    let events: [RingEvent]

    public enum Section: String, CaseIterable, Identifiable {
        case live = "Live", history = "History", map = "Map", radar = "Radar", insights = "Insights"
        public var id: String { rawValue }
        var symbol: String {
            switch self {
            case .live: return "square.grid.2x2"
            case .history: return "clock.arrow.circlepath"
            case .map: return "map"
            case .radar: return "dot.radiowaves.left.and.right"
            case .insights: return "chart.bar.xaxis"
            }
        }
        var strapline: String {
            switch self {
            case .live: return "Every camera, right now"
            case .history: return "What happened, day by day"
            case .map: return "Where things are happening"
            case .radar: return "Who's moving around your home"
            case .insights: return "Patterns over the last few weeks"
            }
        }
        /// History plays recordings, so it doesn't keep the cameras awake.
        var needsCameras: Bool { self != .history }
    }

    /// Which section opens next (the menu bar buttons set this before showing the window).
    @AppStorage("mainSection") private var stored = Section.live.rawValue
    private var section: Section { Section(rawValue: stored) ?? .live }

    @State private var now = Date()
    @State private var watching = false
    @AppStorage("welcomed07") private var welcomed = false
    private var showWelcome: Bool {
        DemoMode.isOn ? (UserDefaults.standard.bool(forKey: "DoorstepWelcome") && !welcomed) : !welcomed
    }
    @ObservedObject private var streams = MultiStreamManager.shared
    @ObservedObject private var recorder = RecorderController.shared
    @ObservedObject private var parcels = ParcelStore.shared
    @ObservedObject private var intel = LiveIntel.shared
    @Environment(\.openWindow) private var openWindow
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(devices: [RingDevice], events: [RingEvent]) {
        self.devices = devices.filter { $0.deviceType != .chime }
        self.events = events
    }

    public var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            VStack(spacing: 0) {
                if section != .history {
                    header
                    Divider()
                }
                Group {
                    switch section {
                    case .live: LiveGrid(devices: devices, events: events).environment(\.colorScheme, .dark)   // text sits on video
                    case .history: HistoryView(devices: devices, seedEvents: events)
                    case .map: MapPanel(devices: devices, events: events)
                    case .radar: RadarPanel(devices: devices, events: events)
                    case .insights: InsightsPanel(devices: devices, seed: events)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.night)
        .frame(minWidth: 1040, minHeight: 640)
        .overlay {
            if showWelcome {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    WelcomeCard { withAnimation(DS.settle) { welcomed = true } }
                }
                .transition(.opacity)
            }
        }
        .onReceive(clock) { now = $0 }
        .task(id: section) { await syncCameras() }
        .onDisappear {
            guard watching else { return }
            watching = false
            LiveAnalysis.shared.unwatchAll()
            Task { await MultiStreamManager.shared.removeViewer() }
        }
        .background(shortcuts)
        // Always a toolbar, so the rail doesn't jump when History brings its own.
        .toolbar { ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) } }
    }

    private func syncCameras() async {
        if section.needsCameras, !watching {
            watching = true
            await streams.addViewer(devices: BatterySaver.streamable(devices, awake: []))
        } else if !section.needsCameras, watching {
            watching = false
            LiveAnalysis.shared.unwatchAll()
            await streams.removeViewer()
        }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 6) {
            DoorstepMark(size: 26)
                .padding(.top, 14)
                .padding(.bottom, 10)
            ForEach(Section.allCases) { s in
                Button { withAnimation(DS.settle) { stored = s.rawValue } } label: {
                    VStack(spacing: 4) {
                        Image(systemName: s.symbol).font(.system(size: 17, weight: .medium))
                        Text(s.rawValue).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(section == s ? DS.porchlight : DS.ash)
                    .frame(width: 64, height: 52)
                    .background(section == s ? DS.well : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(s.strapline)
                .accessibilityLabel(s.rawValue)
                .accessibilityAddTraits(section == s ? .isSelected : [])
            }
            Spacer()
            railButton("shippingbox", "I'm expecting a parcel") {
                openWindow(id: "expect")
            }
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 15))
                    .foregroundStyle(DS.ash)
                    .frame(width: 64, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            .padding(.bottom, 10)
        }
        .frame(width: 80)
        .background(DS.slate.opacity(0.5))
    }

    private func railButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15))
                .foregroundStyle(DS.ash)
                .frame(width: 64, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(section.rawValue).font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.paper)
                Text(section.strapline).font(DS.meta).foregroundStyle(DS.ash)
            }
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
            ModeMenu()
            VStack(alignment: .trailing, spacing: 0) {
                Text(now, format: .dateTime.hour().minute())
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DS.paper)
                Text(now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated)).font(DS.meta).foregroundStyle(DS.ash)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var liveCount: Int { DemoMode.isOn ? devices.count : devices.filter { streams.hasVideoTrack(for: $0.id) }.count }

    private func status(_ symbol: String, _ text: String, _ colour: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(DS.meta)
        }
        .foregroundStyle(colour)
    }

    /// ⌘1…⌘5 switch sections.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(Section.allCases.enumerated()), id: \.element) { i, s in
                Button("") { withAnimation(DS.settle) { stored = s.rawValue } }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// Light, dark, or whatever the Mac is set to.
public enum AppearanceSetting {
    @MainActor public static func apply() {
        switch UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
