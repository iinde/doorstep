import Foundation

// MARK: - Auth Types

public struct AuthTokenResponse: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int
    public let scope: String
    public let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

public struct Auth2FAResponse: Codable, Sendable {
    public let error: String?
    public let errorDescription: String?
    public let tsvState: String?
    public let phone: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case tsvState = "tsv_state"
        case phone
    }
}

// MARK: - Device Types

public struct RingDevice: Codable, Identifiable, Sendable {
    public let id: Int
    public let description: String
    public let deviceId: String
    public let kind: String
    public let locationId: String
    public let firmwareVersion: String?
    public let batteryLife: FlexibleString?
    public let externalConnection: Bool?
    public let settings: DeviceSettings?
    public let features: DeviceFeatures?
    public let alerts: DeviceAlerts?
    public let ledStatus: String?
    public let sirenStatus: SirenStatus?
    /// Where the camera's home is (for the map). Ring reports the address's position.
    public let latitude: Double?
    public let longitude: Double?
    /// Ring Protect: false means Ring keeps no recordings for this camera.
    public let subscribed: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case description
        case deviceId = "device_id"
        case kind
        case locationId = "location_id"
        case firmwareVersion = "firmware_version"
        case batteryLife = "battery_life"
        case externalConnection = "external_connection"
        case settings
        case features
        case alerts
        case ledStatus = "led_status"
        case sirenStatus = "siren_status"
        case latitude, longitude, subscribed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        description = try c.decode(String.self, forKey: .description)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        kind = try c.decode(String.self, forKey: .kind)
        locationId = try c.decode(String.self, forKey: .locationId)
        firmwareVersion = try? c.decodeIfPresent(String.self, forKey: .firmwareVersion)
        batteryLife = try? c.decodeIfPresent(FlexibleString.self, forKey: .batteryLife)
        externalConnection = try? c.decodeIfPresent(Bool.self, forKey: .externalConnection)
        settings = try? c.decodeIfPresent(DeviceSettings.self, forKey: .settings)
        features = try? c.decodeIfPresent(DeviceFeatures.self, forKey: .features)
        alerts = try? c.decodeIfPresent(DeviceAlerts.self, forKey: .alerts)
        ledStatus = try? c.decodeIfPresent(String.self, forKey: .ledStatus)
        sirenStatus = try? c.decodeIfPresent(SirenStatus.self, forKey: .sirenStatus)
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
        subscribed = try? c.decodeIfPresent(Bool.self, forKey: .subscribed)
    }

    /// Runs on batteries (so shouldn't stream all day). Wired cameras report no battery level
    /// or report an external power connection.
    public var isBatteryPowered: Bool { batteryLevel != nil && externalConnection != true }

    public var name: String { description }

    public var deviceType: DeviceType {
        switch kind {
        case "doorbell", "doorbell_v3", "doorbell_v4", "doorbell_v5",
             "doorbell_scallop", "doorbell_scallop_lite", "doorbell_portal",
             "doorbell_graham_cracker", "lpd_v1", "lpd_v2", "lpd_v4",
             "jbox_v1":
            return .doorbell
        case "stickup_cam", "stickup_cam_v3", "stickup_cam_v4",
             "stickup_cam_elite", "stickup_cam_lunar", "stickup_cam_mini",
             "spotlightw_v2", "hp_cam_v1", "hp_cam_v2", "floodlight_v1",
             "floodlight_v2", "floodlight_pro":
            return .camera
        case "chime", "chime_pro", "chime_pro_v2", "chime_v2":
            return .chime
        default:
            // Newer models have codenames (cocoa_floodlight, stickup_cam_mini_v2...).
            let k = kind.lowercased()
            if k.contains("chime") { return .chime }
            if k.contains("doorbell") || k.hasPrefix("lpd") || k.contains("doorview") { return .doorbell }
            if k.contains("cam") || k.contains("flood") || k.contains("spotlight") || k.hasPrefix("cocoa") { return .camera }
            return .unknown
        }
    }

    public var isOnline: Bool {
        alerts?.connection != "offline"
    }

    public var batteryLevel: Int? {
        guard let raw = batteryLife?.value, let n = Double(raw) else { return nil }
        return Int(n)
    }

    /// Whether this device has a floodlight
    public var hasFloodlight: Bool {
        // Floodlight devices have "floodlight" or "spotlight" in their kind
        kind.lowercased().contains("floodlight") ||
        kind.lowercased().contains("spotlight")
    }

    /// Whether this device has a siren
    public var hasSiren: Bool {
        // Check if siren_status is present (indicates siren capability)
        sirenStatus != nil ||
        // Many Ring doorbells and cameras have sirens
        kind.lowercased().contains("stickup") ||
        kind.lowercased().contains("floodlight") ||
        kind.lowercased().contains("spotlight")
    }

    /// Whether motion detection is currently enabled
    public var isMotionDetectionEnabled: Bool {
        settings?.motionDetectionEnabled ?? true
    }
}

public enum DeviceType: String, Codable, Sendable {
    case doorbell
    case camera
    case chime
    case unknown
}

public struct DeviceSettings: Codable, Sendable {
    public let motionDetectionEnabled: Bool?
    public let powerMode: String?
    public let chimeSettings: ChimeSettings?

    enum CodingKeys: String, CodingKey {
        case motionDetectionEnabled = "motion_detection_enabled"
        case powerMode = "power_mode"
        case chimeSettings = "chime_settings"
    }
}

public struct ChimeSettings: Codable, Sendable {
    public let enable: Bool?
    public let type: ChimeType?

    enum CodingKeys: String, CodingKey {
        case enable
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enable = try container.decodeIfPresent(Bool.self, forKey: .enable)

        // type can be Int or String
        if let intType = try? container.decode(Int.self, forKey: .type) {
            type = ChimeType(rawValue: intType)
        } else if let stringType = try? container.decode(String.self, forKey: .type) {
            type = ChimeType(stringValue: stringType)
        } else {
            type = nil
        }
    }
}

public enum ChimeType: Int, Codable, Sendable {
    case mechanical = 0
    case digital = 1
    case none = 2

    init?(stringValue: String) {
        switch stringValue.lowercased() {
        case "mechanical": self = .mechanical
        case "digital": self = .digital
        case "none": self = .none
        default: return nil
        }
    }
}

public struct DeviceFeatures: Codable, Sendable {
    public let motionsEnabled: Bool?
    public let showRecordings: Bool?

    enum CodingKeys: String, CodingKey {
        case motionsEnabled = "motions_enabled"
        case showRecordings = "show_recordings"
    }
}

public struct DeviceAlerts: Codable, Sendable {
    public let connection: String?
    public let battery: String?
}

public struct SirenStatus: Codable, Sendable {
    public let secondsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case secondsRemaining = "seconds_remaining"
    }
}

// MARK: - Event Types

public struct RingEvent: Decodable, Identifiable, Sendable {
    public let id: String
    public let createdAt: Date
    public let kind: EventKind
    public let favorite: Bool
    public let deviceName: String?
    /// Ring's own kind string, unmapped (e.g. "on_demand_link").
    public let rawKind: String
    /// The camera this event belongs to (doorbot.id). Nil if Ring omits it.
    public let deviceId: Int?
    /// Clip length in seconds, when Ring reports it.
    public let duration: Double?
    /// Ring's own person flag (cv_properties.person_detected). Nil = unknown.
    public let personDetected: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case kind
        case favorite
        case doorbot
        case duration
        case cvProperties = "cv_properties"
    }

    enum DoorbotKeys: String, CodingKey {
        case id
        case description
    }

    enum CVKeys: String, CodingKey {
        case personDetected = "person_detected"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // id can be Int64 or String
        if let intId = try? container.decode(Int64.self, forKey: .id) {
            id = String(intId)
        } else if let stringId = try? container.decode(String.self, forKey: .id) {
            id = stringId
        } else {
            id = UUID().uuidString
        }

        // Handle date parsing - ISO8601 string
        if let dateString = try? container.decode(String.self, forKey: .createdAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            createdAt = formatter.date(from: dateString) ?? Date()
        } else if let timestamp = try? container.decode(Double.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: timestamp / 1000)
        } else {
            createdAt = Date()
        }

        kind = try container.decode(EventKind.self, forKey: .kind)
        rawKind = (try? container.decode(String.self, forKey: .kind)) ?? kind.rawValue
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false

        // deviceName is nested under doorbot.description
        if let doorbotContainer = try? container.nestedContainer(keyedBy: DoorbotKeys.self, forKey: .doorbot) {
            deviceName = try? doorbotContainer.decodeIfPresent(String.self, forKey: .description)
            deviceId = (try? doorbotContainer.decodeIfPresent(Int.self, forKey: .id))
                ?? (try? doorbotContainer.decodeIfPresent(String.self, forKey: .id)).flatMap { Int($0) }
        } else {
            deviceName = nil
            deviceId = nil
        }

        duration = try? container.decodeIfPresent(Double.self, forKey: .duration)
        if let cv = try? container.nestedContainer(keyedBy: CVKeys.self, forKey: .cvProperties) {
            personDetected = try? cv.decodeIfPresent(Bool.self, forKey: .personDetected)
        } else {
            personDetected = nil
        }
    }
}

public enum EventKind: String, Codable, Sendable {
    case ding
    case motion
    case onDemand = "on_demand"
    case other

    /// Ring adds new kinds (e.g. "on_demand_link") without warning. An unknown kind
    /// used to fail the whole history request, so map variants and fall back to .other.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let known = EventKind(rawValue: raw), known != .other { self = known }
        else if raw.hasPrefix("on_demand") { self = .onDemand }
        else if raw.hasPrefix("ding") { self = .ding }
        else if raw.hasPrefix("motion") { self = .motion }
        else { self = .other }
    }

    public var displayName: String {
        switch self {
        case .ding: return "Ring press"
        case .motion: return "Motion detected"
        case .onDemand: return "Live view"
        case .other: return "Event"
        }
    }
}

public struct EventsResponse: Decodable, Sendable {
    public let events: [RingEvent]
}

// MARK: - Session Types

public struct SessionResponse: Codable, Sendable {
    public let profile: UserProfile
}

public struct UserProfile: Codable, Sendable {
    public let id: Int
    public let email: String
    public let firstName: String?
    public let lastName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

// MARK: - Location Types

public struct RingLocation: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case id = "location_id"
        case name
    }
}

// MARK: - Empty Response (for PUT commands)

public struct EmptyResponse: Decodable, Sendable {
    // Handles empty responses or responses with any JSON
    public init(from decoder: Decoder) throws {
        // Accept any response, including empty
    }

    public init() {}
}

// MARK: - Devices Response

public struct DevicesResponse: Codable, Sendable {
    public let doorbots: [RingDevice]?
    public let authorizedDoorbots: [RingDevice]?
    public let stickupCams: [RingDevice]?
    public let chimes: [RingDevice]?

    enum CodingKeys: String, CodingKey {
        case doorbots
        case authorizedDoorbots = "authorized_doorbots"
        case stickupCams = "stickup_cams"
        case chimes
    }

    public var allDevices: [RingDevice] {
        var devices: [RingDevice] = []
        if let doorbots { devices.append(contentsOf: doorbots) }
        if let authorizedDoorbots { devices.append(contentsOf: authorizedDoorbots) }
        if let stickupCams { devices.append(contentsOf: stickupCams) }
        if let chimes { devices.append(contentsOf: chimes) }
        return devices
    }
}

/// Ring sends some fields (e.g. `battery_life`) as a string on one device and a number on another.
public struct FlexibleString: Codable, Sendable, Equatable {
    public let value: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else if let b = try? c.decode(Bool.self) { value = String(b) }
        else { throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string or number")) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}
