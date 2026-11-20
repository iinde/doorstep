import SwiftUI
import AppKit
import RingClient

/// Back at your Mac after a while away: a short card of what happened at the door while
/// the screen was locked or asleep. Only when something did.
@MainActor
public final class WhileYouWereOut {
    public static let shared = WhileYouWereOut()
    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: "whileOut") as? Bool ?? true }
    static var minimumAway: TimeInterval { Double(UserDefaults.standard.object(forKey: "whileOutMinutes") as? Int ?? 45) * 60 }
    private var awaySince: Date?
    private var panel: NSPanel?
    /// Opens the main window on History (set by the app).
    public var openHistory: (() -> Void)?

    public func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.wentAway() }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.cameBack() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.wentAway() }
        }
        if DemoMode.isOn, UserDefaults.standard.bool(forKey: "DoorstepWhileOut") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let day = Calendar.current.startOfDay(for: Date())
                self.show(since: day.addingTimeInterval(9 * 3600), until: day.addingTimeInterval(17.5 * 3600))
            }
        }
    }

    private func wentAway() { if awaySince == nil { awaySince = Date() } }

    private func cameBack() {
        guard let since = awaySince else { return }
        awaySince = nil
        guard Self.isEnabled, Date().timeIntervalSince(since) >= Self.minimumAway else { return }
        // Give the next refresh a moment to bring in the latest visits.
        Task {
            try? await Task.sleep(for: .seconds(6))
            show(since: since, until: Date())
        }
    }

    static func moments(since: Date, until: Date) -> [Moment] {
        MomentBuilder.build(from: EventDirectory.shared.allEvents.filter { MomentBuilder.isOutsideEvent($0) })
            .filter { $0.end >= since && $0.start <= until && ($0.tier >= .people || $0.parcelLeft || $0.parcelTaken) }
            .sorted { $0.end > $1.end }
    }

    /// "3 visits, 1 ring and a parcel left."
    static func summary(_ m: [Moment]) -> String {
        let rings = m.filter { $0.tier == .doorbell }.count
        let deliveries = m.filter { $0.identity?.isDelivery == true }.count
        let parcels = m.filter(\.parcelLeft).count
        var bits: [String] = [m.count == 1 ? "1 visit" : "\(m.count) visits"]
        if rings > 0 { bits.append(rings == 1 ? "1 ring" : "\(rings) rings") }
        if deliveries > 0 { bits.append(deliveries == 1 ? "1 delivery" : "\(deliveries) deliveries") }
        if parcels > 0 { bits.append(parcels == 1 ? "a parcel left" : "\(parcels) parcels left") }
        if m.contains(where: \.parcelTaken) { bits.append("a parcel taken") }
        let last = bits.removeLast()
        return (bits.isEmpty ? last : bits.joined(separator: ", ") + " and " + last) + "."
    }

    func show(since: Date, until: Date) {
        let m = Self.moments(since: since, until: until)
        guard !m.isEmpty else { return }
        close()
        let view = WhileOutCard(moments: Array(m.prefix(6)), summary: Self.summary(m), since: since,
                                onOpen: { [weak self] in self?.close(); self?.openHistory?() },
                                onClose: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        let size = NSSize(width: 420, height: m.count > 3 ? 340 : 240)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12))
        }
        p.orderFrontRegardless()
        panel = p
    }

    func close() { panel?.orderOut(nil); panel = nil }
}

struct WhileOutCard: View {
    let moments: [Moment]
    let summary: String
    let since: Date
    let onOpen: () -> Void
    let onClose: () -> Void
    @State private var thumbs: [String: NSImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("While you were out").font(DS.title).foregroundStyle(DS.paper)
                    Text("Since \(since.formatted(date: .omitted, time: .shortened)): \(summary)")
                        .font(DS.meta).foregroundStyle(DS.ash).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.ash)
                        .frame(width: 24, height: 24).background(DS.well, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(moments) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        ZStack {
                            DS.slate
                            if let img = thumbs[m.headline.id] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                        }
                        .frame(height: 68).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(m.title).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.paper).lineLimit(1)
                        Text(m.end, format: .dateTime.hour().minute()).font(DS.monoTick).foregroundStyle(DS.ash)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Open History", action: onOpen).buttonStyle(.borderedProminent).tint(DS.porchlight)
            }
        }
        .padding(16)
        .frame(width: 420, height: moments.count > 3 ? 340 : 240)
        .background(Backdrop())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.well))
        .task {
            for m in moments {
                if let img = await ThumbnailCache.shared.thumbnail(for: m.headline.id) { thumbs[m.headline.id] = img }
            }
        }
    }
}
