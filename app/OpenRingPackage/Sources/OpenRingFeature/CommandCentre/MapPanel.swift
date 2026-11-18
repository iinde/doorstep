import SwiftUI
import MapKit
import RingClient

/// Bird's-eye view: satellite map of home with each camera where it really is, what it
/// can see, what's happening now, and the trail of anyone moving between cameras.
struct MapPanel: View {
    let devices: [RingDevice]
    let events: [RingEvent]
    @ObservedObject private var placement = CameraPlacement.shared
    @ObservedObject private var intel = LiveIntel.shared
    @State private var position: MapCameraPosition = .automatic
    @State private var placing: Int?
    @State private var selected: Int?
    @State private var now = Date()
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var cameras: [RingDevice] { devices.filter { $0.deviceType == .camera || $0.deviceType == .doorbell } }

    /// Moments in the last hour, in order; consecutive ones on different cameras within
    /// 3 minutes form a trail (someone walking round the house).
    private var trails: [[(RingDevice, Moment)]] {
        let recent = MomentBuilder.build(from: events).filter { $0.end > now.addingTimeInterval(-3600) && $0.tier >= .people }
            .sorted { $0.start < $1.start }
        var out: [[(RingDevice, Moment)]] = []
        var cur: [(RingDevice, Moment)] = []
        for m in recent {
            guard let d = cameras.first(where: { String($0.id) == m.deviceKey }) else { continue }
            if let last = cur.last, m.start.timeIntervalSince(last.1.end) < 180, last.0.id != d.id {
                cur.append((d, m))
            } else {
                if cur.count > 1 { out.append(cur) }
                cur = [(d, m)]
            }
        }
        if cur.count > 1 { out.append(cur) }
        return out
    }

    var body: some View {
        HStack(spacing: 0) {
            map
            sidebar.frame(width: 280)
        }
        .onReceive(tick) { now = $0 }
        .onAppear {
            if let home = CameraPlacement.home(devices) {
                position = .camera(MapCamera(centerCoordinate: home, distance: 120, heading: 0, pitch: 0))
            }
        }
    }

    @ViewBuilder private var map: some View {
        if CameraPlacement.home(devices) == nil {
            Text("Ring didn't share your home's location, so the map can't centre on it.")
                .font(DS.body).foregroundStyle(DS.ash).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MapReader { proxy in
                Map(position: $position, interactionModes: [.pan, .zoom, .rotate]) {
                    ForEach(trails.indices, id: \.self) { i in
                        let coords = trails[i].compactMap { placement.spot(for: $0.0, among: devices)?.coordinate }
                        MapPolyline(coordinates: coords)
                            .stroke(DS.porchlight.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 5]))
                    }
                    ForEach(cameras, id: \.id) { d in
                        if let spot = placement.spot(for: d, among: devices) {
                            Annotation(d.name, coordinate: spot.coordinate, anchor: .center) {
                                CameraPin(device: d, heading: spot.heading, state: intel.cameras[d.id],
                                          recent: recentActivity(d), isSelected: selected == d.id)
                                    .onTapGesture { selected = d.id }
                            }
                        }
                    }
                }
                .mapStyle(.imagery(elevation: .realistic))
                .mapControls { MapCompass(); MapScaleView() }
                .onTapGesture { point in
                    guard let id = placing, let c = proxy.convert(point, from: .local) else { return }
                    placement.place(id, at: c)
                    placing = nil
                }
                .overlay(alignment: .top) {
                    if let id = placing, let d = cameras.first(where: { $0.id == id }) {
                        Text("Click where \(d.name) is").font(DS.bodyStrong).foregroundStyle(DS.night)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(DS.porchlight, in: Capsule()).padding(14)
                    }
                }
            }
        }
    }

    private func recentActivity(_ d: RingDevice) -> Double {
        // 1 = something in the last minute, fading to 0 over 15 minutes.
        guard let last = events.filter({ $0.deviceId == d.id && MomentBuilder.isOutsideEvent($0) })
            .map(\.createdAt).max() else { return 0 }
        return max(0, 1 - now.timeIntervalSince(last) / 900)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cameras").font(DS.title).foregroundStyle(DS.paper)
                Text(placement.isPlaced ? "Click a camera, then set where it points."
                     : "Place each camera where it really is, so trails and the radar line up.")
                    .font(DS.meta).foregroundStyle(DS.ash).fixedSize(horizontal: false, vertical: true)
                ForEach(cameras, id: \.id) { d in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(d.name).font(DS.bodyStrong).foregroundStyle(DS.paper)
                            Spacer()
                            Button(placing == d.id ? "Cancel" : "Place") { placing = placing == d.id ? nil : d.id }
                                .controlSize(.small)
                        }
                        if let spot = placement.spot(for: d, among: devices) {
                            HStack(spacing: 8) {
                                Image(systemName: "location.north.fill").rotationEffect(.degrees(spot.heading))
                                    .foregroundStyle(DS.porchlight)
                                Slider(value: Binding(get: { spot.heading },
                                                      set: { placement.setHeading(d.id, $0, default: spot) }),
                                       in: 0...359)
                                Text("\(Int(spot.heading))°").font(DS.monoMeta).foregroundStyle(DS.ash).frame(width: 34)
                            }
                        }
                    }
                    .padding(12)
                    .background(selected == d.id ? DS.porchlight.opacity(0.12) : DS.well,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if !trails.isEmpty {
                    Text("Trails in the last hour").font(DS.title).foregroundStyle(DS.paper).padding(.top, 8)
                    ForEach(trails.indices, id: \.self) { i in
                        Text(trails[i].map { $0.0.name }.joined(separator: " → "))
                            .font(DS.body).foregroundStyle(DS.porchlight)
                        Text(trails[i].first!.1.start, format: .dateTime.hour().minute()).font(DS.monoMeta).foregroundStyle(DS.ash)
                    }
                }
            }
            .padding(18)
        }
        .background(DS.night)
    }
}

/// A camera on the map: its field of view as a soft cone, glowing when something's there.
struct CameraPin: View {
    let device: RingDevice
    let heading: Double
    let state: LiveIntel.CameraNow?
    let recent: Double
    let isSelected: Bool
    @State private var pulse = false

    private var hot: Bool { !(state?.people.isEmpty ?? true) }

    var body: some View {
        ZStack {
            // Field of view (about 140°), pointing along `heading`.
            Cone(spread: 140)
                .fill(RadialGradient(colors: [(hot ? DS.porchlight : DS.paper).opacity(hot ? 0.7 : 0.42 + recent * 0.25), .clear],
                                     center: .center, startRadius: 0, endRadius: 70))
                .frame(width: 160, height: 160)
                .rotationEffect(.degrees(heading))
                .overlay(Cone(spread: 140).stroke(DS.paper.opacity(0.35), lineWidth: 1)
                    .frame(width: 160, height: 160).rotationEffect(.degrees(heading)))
            if hot || recent > 0.6 {
                Circle().stroke(DS.porchlight, lineWidth: 2)
                    .frame(width: pulse ? 46 : 18, height: pulse ? 46 : 18)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
            }
            Circle().fill(DS.night).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(isSelected ? DS.porchlight : DS.paper, lineWidth: 2))
            Image(systemName: device.deviceType == .doorbell ? "bell.fill" : "video.fill")
                .font(.system(size: 8)).foregroundStyle(DS.paper)
        }
    }
}

/// A wedge pointing up (north) with the given spread in degrees.
struct Cone: Shape {
    let spread: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        p.move(to: c)
        p.addArc(center: c, radius: r.width / 2, startAngle: .degrees(-90 - spread / 2),
                 endAngle: .degrees(-90 + spread / 2), clockwise: false)
        p.closeSubpath()
        return p
    }
}
