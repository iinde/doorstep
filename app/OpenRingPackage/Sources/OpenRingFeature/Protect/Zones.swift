import SwiftUI
import AppKit
import RingClient

/// Where on each camera's picture you care about (the path, the drive), so people on the
/// pavement or passing cars don't set anything off. Points are 0...1, origin top-left.
@MainActor
public final class ZoneStore: ObservableObject {
    public static let shared = ZoneStore()
    @Published public private(set) var zones: [Int: [CGPoint]] = [:]
    private let key = "zones"

    private init() {
        if !DemoMode.isOn, let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Int: [[Double]]].self, from: data) {
            zones = saved.mapValues { $0.map { CGPoint(x: $0[0], y: $0[1]) } }
        }
        Self.snapshot = zones
    }

    /// A thread-safe copy for the video analysis queues.
    nonisolated(unsafe) static var snapshot: [Int: [CGPoint]] = [:]

    public func set(_ points: [CGPoint], for id: Int) {
        zones[id] = points.count >= 3 ? points : nil
        Self.snapshot = zones
        guard !DemoMode.isOn else { return }
        let raw = zones.mapValues { $0.map { [Double($0.x), Double($0.y)] } }
        if let data = try? JSONEncoder().encode(raw) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Is this Vision box (origin bottom-left) in the zone? Uses the feet: the middle of the
    /// bottom edge. No zone means everywhere counts.
    nonisolated public static func contains(_ box: CGRect, camera: Int) -> Bool {
        guard let poly = snapshot[camera], poly.count >= 3 else { return true }
        let feet = CGPoint(x: box.midX, y: 1 - box.minY)   // to top-left origin
        return inside(feet, poly)
    }

    nonisolated static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

/// Draw a zone by clicking round the area that matters.
public struct ZoneEditor: View {
    let device: RingDevice
    let onDone: () -> Void
    @State private var points: [CGPoint] = []
    @State private var picture: NSImage?

    public init(device: RingDevice, onDone: @escaping () -> Void) {
        self.device = device
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where should \(device.name) watch?").font(DS.title)
            Text("Click round the area you care about, like your path or drive. People and movement outside it won't alert you or start a recording. Leave it empty to watch everything.")
                .font(DS.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GeometryReader { g in
                ZStack {
                    Color.black
                    if let picture {
                        Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: g.size.width, height: g.size.height).clipped()
                    } else {
                        ProgressView()
                    }
                    Path { p in
                        guard let first = points.first else { return }
                        p.move(to: CGPoint(x: first.x * g.size.width, y: first.y * g.size.height))
                        for q in points.dropFirst() { p.addLine(to: CGPoint(x: q.x * g.size.width, y: q.y * g.size.height)) }
                        if points.count >= 3 { p.closeSubpath() }
                    }
                    .fill(DS.porchlight.opacity(0.25))
                    .overlay(Path { p in
                        guard let first = points.first else { return }
                        p.move(to: CGPoint(x: first.x * g.size.width, y: first.y * g.size.height))
                        for q in points.dropFirst() { p.addLine(to: CGPoint(x: q.x * g.size.width, y: q.y * g.size.height)) }
                        if points.count >= 3 { p.closeSubpath() }
                    }.stroke(DS.porchlight, lineWidth: 2))
                    ForEach(Array(points.enumerated()), id: \.offset) { _, q in
                        Circle().fill(DS.porchlight).frame(width: 10, height: 10)
                            .position(x: q.x * g.size.width, y: q.y * g.size.height)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in
                    points.append(CGPoint(x: loc.x / g.size.width, y: loc.y / g.size.height))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Undo") { _ = points.popLast() }.disabled(points.isEmpty)
                Button("Clear") { points = [] }.disabled(points.isEmpty)
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Save") {
                    ZoneStore.shared.set(points, for: device.id)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(points.count > 0 && points.count < 3)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task {
            points = ZoneStore.shared.zones[device.id] ?? []
            if DemoMode.isOn {
                picture = DemoData.live(device.id)
            } else if let data = try? await RingClient.shared.getSnapshot(deviceId: device.id) {
                picture = NSImage(data: data)
            } else if let e = EventDirectory.shared.allEvents.filter({ $0.deviceId == device.id }).max(by: { $0.createdAt < $1.createdAt }) {
                picture = await ThumbnailCache.shared.thumbnail(for: e.id)
            }
        }
    }
}
