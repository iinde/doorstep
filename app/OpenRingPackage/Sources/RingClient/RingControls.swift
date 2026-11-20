import Foundation

/// Chimes, Ring's own location modes, and camera health. Endpoints as used by the
/// dgreif/ring library (ring-client-api: ring-chime.ts, location.ts, ring-camera.ts).
public struct CameraHealth: Sendable, Equatable {
    public var batteryPercent: Int?
    public var rssi: Int?                 // Wi-Fi signal, dBm (closer to 0 is better)
    public var rssiCategory: String?      // "good", "fair", "poor"
    public var firmware: String?
    public var firmwareStatus: String?
    public var onACPower: Bool?
    public var packetLossCategory: String?

    /// 0 to 4 bars, from RSSI.
    public var signalBars: Int? {
        guard let r = rssi else { return nil }
        switch r {
        case (-55)...: return 4
        case (-65)...: return 3
        case (-75)...: return 2
        case (-85)...: return 1
        default: return 0
        }
    }
}

public enum RingLocationMode: String, Sendable, CaseIterable {
    case home, away, disarmed
}

extension RingClient {
    static let appAPI = "https://prd-api-us.prd.rings.solutions/api/v1/"

    /// A Ring API call that returns JSON (or nothing). Same auth as the rest of the client.
    func rawRequest(_ url: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let token = try await getValidAccessToken()
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("android:com.ringapp", forHTTPHeaderField: "User-Agent")
        req.setValue(try await keychain.getHardwareId(), forHTTPHeaderField: "hardware_id")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RingAPIError.networkError
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Health

    public func fetchHealth(deviceId: Int) async throws -> CameraHealth {
        let json = try await rawRequest(API.clientsAPI + "doorbots/\(deviceId)/health")
        let h = json["device_health"] as? [String: Any] ?? [:]
        func int(_ k: String) -> Int? { (h[k] as? Int) ?? (h[k] as? Double).map(Int.init) ?? (h[k] as? String).flatMap { Int($0) } }
        return CameraHealth(batteryPercent: int("battery_percentage"), rssi: int("rssi") ?? int("latest_signal_strength"),
                            rssiCategory: h["rssi_category"] as? String ?? h["latest_signal_category"] as? String,
                            firmware: h["firmware_version"] as? String, firmwareStatus: h["firmware_version_status"] as? String,
                            onACPower: (h["ac_power"] as? Int).map { $0 == 1 },
                            packetLossCategory: h["packet_loss_category"] as? String)
    }

    // MARK: Chimes

    /// kind: "ding" or "motion"
    public func playChime(_ chimeId: Int, kind: String = "ding") async throws {
        _ = try await rawRequest(API.clientsAPI + "chimes/\(chimeId)/play_sound", method: "POST", body: ["kind": kind])
    }

    /// Silence a chime for some minutes (max 1440). 0 clears the snooze.
    public func snoozeChime(_ chimeId: Int, minutes: Int) async throws {
        _ = try await rawRequest(API.clientsAPI + "chimes/\(chimeId)/do_not_disturb", method: "POST",
                                 body: minutes > 0 ? ["time": min(minutes, 1440)] : nil)
    }

    // MARK: Ring's own location modes (Home / Away / Disarmed)

    public func locationMode(_ locationId: String) async throws -> String? {
        try await rawRequest(Self.appAPI + "mode/location/\(locationId)")["mode"] as? String
    }

    public func setLocationMode(_ locationId: String, _ mode: RingLocationMode) async throws {
        _ = try await rawRequest(Self.appAPI + "mode/location/\(locationId)", method: "POST", body: ["mode": mode.rawValue])
    }
}

extension RingClient {
    /// How many of each kind of Ring device the account has ("stickup_cams": 3, "base_stations": 1…).
    /// Alarm base stations and Smart Lighting bridges show up here even though Doorstep can't drive them yet.
    public func deviceGroupCounts() async -> [String: Int] {
        guard let json = try? await rawRequest(API.clientsAPI + "ring_devices") else { return [:] }
        var out: [String: Int] = [:]
        for (k, v) in json { if let a = v as? [Any] { out[k] = a.count } }
        return out
    }
}

