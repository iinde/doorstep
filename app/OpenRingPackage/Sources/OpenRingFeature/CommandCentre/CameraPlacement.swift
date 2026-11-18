import Foundation
import CoreLocation
import RingClient

/// Where each camera sits on the map and which way it faces. Set by you on the Map;
/// until then cameras are spread in a small ring around the home's position from Ring.
@MainActor
public final class CameraPlacement: ObservableObject {
    public static let shared = CameraPlacement()

    public struct Spot: Codable, Equatable, Sendable {
        public var lat: Double
        public var lon: Double
        /// Compass heading the camera looks along (0 = north).
        public var heading: Double
        public var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }

    @Published public private(set) var spots: [Int: Spot] = [:]
    private let key = "cameraPlacement"

    private init() {
        if !DemoMode.isOn, let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Int: Spot].self, from: data) { spots = saved }
    }

    /// The home's position, from Ring.
    public static func home(_ devices: [RingDevice]) -> CLLocationCoordinate2D? {
        guard let d = devices.first(where: { $0.latitude != nil && $0.longitude != nil }),
              let lat = d.latitude, let lon = d.longitude, lat != 0 || lon != 0 else { return nil }
        return .init(latitude: lat, longitude: lon)
    }

    /// Placed spot, or a default one around the home so the map works straight away.
    public func spot(for device: RingDevice, among devices: [RingDevice]) -> Spot? {
        if let s = spots[device.id] { return s }
        guard let home = Self.home(devices) else { return nil }
        let cams = devices.filter { $0.deviceType == .camera || $0.deviceType == .doorbell }
        let i = Double(cams.firstIndex(where: { $0.id == device.id }) ?? 0)
        let angle = i / Double(max(cams.count, 1)) * 2 * .pi
        let r = 0.00009  // ~10 m
        return Spot(lat: home.latitude + r * cos(angle), lon: home.longitude + r * sin(angle) / cos(home.latitude * .pi / 180),
                    heading: (angle * 180 / .pi).truncatingRemainder(dividingBy: 360))
    }

    public func place(_ id: Int, at c: CLLocationCoordinate2D, heading: Double? = nil) {
        let old = spots[id]
        spots[id] = Spot(lat: c.latitude, lon: c.longitude, heading: heading ?? old?.heading ?? 0)
        save()
    }

    public func setHeading(_ id: Int, _ heading: Double, default spot: Spot) {
        var s = spots[id] ?? spot
        s.heading = heading
        spots[id] = s
        save()
    }

    public var isPlaced: Bool { !spots.isEmpty }

    private func save() {
        guard !DemoMode.isOn else { return }
        if let data = try? JSONEncoder().encode(spots) { UserDefaults.standard.set(data, forKey: key) }
    }
}
