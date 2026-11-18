import Foundation

// MARK: - Public event

/// A doorbell press or motion alert delivered by Ring's push notifications.
public struct RingPushEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case ding
        case motion
        case other
    }

    public var kind: Kind
    public var deviceId: Int
    public var deviceName: String?
    /// The ding id: the same id the history endpoint returns for this event.
    public var eventId: String?
    public var createdAt: Date
    /// true when Ring says a person was detected, false when it says otherwise, nil when it doesn't say.
    public var personDetected: Bool?
    /// The raw Ring category / action string (e.g. com.ring.pn.live-event.motion), for logging and filtering.
    public var category: String?

    public init(kind: Kind, deviceId: Int, deviceName: String? = nil, eventId: String? = nil,
                createdAt: Date, personDetected: Bool? = nil, category: String? = nil) {
        self.kind = kind
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.eventId = eventId
        self.createdAt = createdAt
        self.personDetected = personDetected
        self.category = category
    }
}

// MARK: - Parsing

/// Turns a decrypted FCM message into a RingPushEvent, following dgreif/ring
/// api.ts registerPushReceiver() onNotification and ring-types.ts:
///
/// * The decrypted message is `{ "data": { key: "<JSON string>" ... }, "from": ..., ... }`.
///   Every value in `data` is parsed as JSON if it can be, otherwise kept as is.
/// * v2 dings / motion (current): the result has `android_config.category`
///   (com.ring.pn.live-event.ding / .motion / .intercom) and `data.device.id`,
///   `data.event.ding.{id, created_at, subtype, detection_type}`.
/// * Alarm style: `data.gcmData.alarm_meta.device_zid` with `action`.
/// * Legacy (older ring-client-api, kept as a fallback): top-level `ding` with
///   `doorbot_id` and `action` com.ring.push.HANDLE_NEW_DING / HANDLE_NEW_motion.
enum RingPushParser {
    static let dingCategory = "com.ring.pn.live-event.ding"
    static let motionCategory = "com.ring.pn.live-event.motion"
    static let intercomDingCategory = "com.ring.pn.live-event.intercom"

    enum Outcome: Equatable {
        case event(RingPushEvent)
        /// Parsed, but not something we turn into an event. `reason` is safe to log.
        case ignored(reason: String)
    }

    /// Entry point for the decrypted plaintext of a DataMessageStanza.
    static func parse(decryptedMessage data: Data, receivedAt: Date = Date()) -> Outcome {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .ignored(reason: "message is not a JSON object")
        }
        guard let fields = message["data"] as? [String: Any] else {
            return .ignored(reason: "message has no data")
        }
        return parse(notification: flatten(fields), receivedAt: receivedAt)
    }

    /// `for (const p in message.data) messageData[p] = JSON.parse(message.data[p]) ?? message.data[p]`
    static func flatten(_ fields: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in fields {
            if let s = v as? String, let parsed = parseJSONString(s) {
                out[k] = parsed
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func parseJSONString(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    static func parse(notification n: [String: Any], receivedAt: Date) -> Outcome {
        if let androidConfig = n["android_config"] as? [String: Any] {
            return parseV2(n, androidConfig: androidConfig, receivedAt: receivedAt)
        }
        if let data = n["data"] as? [String: Any] {
            var gcm = data["gcmData"]
            if let s = gcm as? String { gcm = parseJSONString(s) }
            if let gcmData = gcm as? [String: Any], let meta = gcmData["alarm_meta"] as? [String: Any] {
                guard let deviceId = int(meta["device_zid"]) else {
                    return .ignored(reason: "alarm notification without numeric device id")
                }
                return .event(RingPushEvent(kind: .other, deviceId: deviceId, createdAt: receivedAt,
                                            category: gcmData["action"] as? String))
            }
        }
        if let ding = n["ding"] as? [String: Any] {
            return parseLegacy(n, ding: ding, receivedAt: receivedAt)
        }
        return .ignored(reason: "unknown notification format")
    }

    private static func parseV2(_ n: [String: Any], androidConfig: [String: Any], receivedAt: Date) -> Outcome {
        let category = androidConfig["category"] as? String
        let data = n["data"] as? [String: Any] ?? [:]
        let device = data["device"] as? [String: Any] ?? [:]
        guard let deviceId = int(device["id"]) else {
            return .ignored(reason: "v2 notification without data.device.id")
        }
        let event = data["event"] as? [String: Any] ?? [:]
        let ding = event["ding"] as? [String: Any] ?? [:]
        let eventito = event["eventito"] as? [String: Any] ?? [:]
        let subtype = ding["subtype"] as? String

        let kind: RingPushEvent.Kind
        switch category {
        case dingCategory, intercomDingCategory: kind = .ding
        case motionCategory: kind = .motion
        default:
            switch subtype {
            case "ding": kind = .ding
            case "motion", "human", "other_motion", "vehicle", "package_delivery": kind = .motion
            default: kind = .other
            }
        }

        let analytics = n["analytics"] as? [String: Any] ?? [:]
        let createdAt = date(ding["created_at"])
            ?? epoch(eventito["timestamp"])
            ?? epoch(analytics["triggered_at"])
            ?? receivedAt

        return .event(RingPushEvent(
            kind: kind,
            deviceId: deviceId,
            deviceName: device["name"] as? String,
            eventId: idString(ding["id"]),
            createdAt: createdAt,
            personDetected: personDetected(kind: kind, signals: [ding["detection_type"], subtype, eventito["type"]]),
            category: category
        ))
    }

    private static func parseLegacy(_ n: [String: Any], ding: [String: Any], receivedAt: Date) -> Outcome {
        guard let deviceId = int(ding["doorbot_id"]) else {
            return .ignored(reason: "legacy ding without doorbot_id")
        }
        let action = n["action"] as? String
        let kind: RingPushEvent.Kind
        switch action {
        case "com.ring.push.HANDLE_NEW_DING": kind = .ding
        case "com.ring.push.HANDLE_NEW_motion": kind = .motion
        default: kind = (ding["kind"] as? String) == "ding" ? .ding : (ding["kind"] as? String) == "motion" ? .motion : .other
        }
        return .event(RingPushEvent(
            kind: kind,
            deviceId: deviceId,
            deviceName: ding["doorbot_description"] as? String ?? ding["device_name"] as? String,
            eventId: idString(ding["id"]),
            createdAt: date(ding["created_at"]) ?? receivedAt,
            personDetected: personDetected(kind: kind, signals: [ding["detection_type"]]),
            category: action
        ))
    }

    private static func personDetected(kind: RingPushEvent.Kind, signals: [Any?]) -> Bool? {
        let values = signals.compactMap { $0 as? String }.map { $0.lowercased() }
        if values.contains("human") || values.contains("person") { return true }
        // Only claim "no person" when Ring classified a motion event as something else.
        if kind == .motion && !values.isEmpty { return false }
        return nil
    }

    // MARK: - Value helpers (JSONSerialization keeps 64-bit ints exact)

    static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber where !isFloating(n): return n.intValue
        case let n as NSNumber: return n.doubleValue.rounded() == n.doubleValue ? Int(exactly: n.doubleValue) : nil
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func idString(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber where !isFloating(n): return n.stringValue
        case let n as NSDecimalNumber: return n.stringValue
        default: return nil
        }
    }

    private static func isFloating(_ n: NSNumber) -> Bool {
        if n is NSDecimalNumber { return false }
        let t = String(cString: n.objCType)
        return t == "d" || t == "f"
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return epoch(v) }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    /// Ring timestamps are epoch milliseconds; tolerate seconds too.
    private static func epoch(_ v: Any?) -> Date? {
        guard let n = v as? NSNumber else { return nil }
        let x = n.doubleValue
        guard x > 0 else { return nil }
        return Date(timeIntervalSince1970: x > 1e12 ? x / 1000 : x)
    }
}
