import Foundation
import UserNotifications
import RingClient

/// Live parcel status, optional. Carriers in the UK don't offer free public tracking APIs,
/// so Doorstep uses 17TRACK (covers Royal Mail, DPD, Evri, DHL, UPS and more) with the
/// user's OWN key from Settings. No key: no background checks; the Track button and
/// delivery emails still work. No Doorstep server either way.
@MainActor
public final class Tracker: ObservableObject {
    public static let shared = Tracker()
    static let keyName = "17track_key"

    @Published public private(set) var hasKey = false
    @Published public private(set) var lastError: String?
    private var lastRun = Date.distantPast

    private init() {}

    public func refreshKeyState() async {
        hasKey = ((try? await KeychainManager.shared.secret(for: Self.keyName)) ?? nil)?.isEmpty == false
    }

    public func saveKey(_ key: String) async {
        try? await KeychainManager.shared.saveSecret(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keyName)
        await refreshKeyState()
        await checkAll(force: true)
    }

    public func removeKey() async {
        try? await KeychainManager.shared.deleteSecret(for: Self.keyName)
        await refreshKeyState()
    }

    /// Every 30 minutes at most, unless forced (a parcel was just added).
    public func checkAll(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastRun) > 30 * 60 else { return }
        guard let key = (try? await KeychainManager.shared.secret(for: Self.keyName)) ?? nil, !key.isEmpty else { return }
        let active = ParcelStore.shared.parcels.filter { $0.isActive && $0.tracking != nil }
        guard !active.isEmpty else { return }
        lastRun = Date()
        let numbers = active.compactMap(\.tracking)
        do {
            // Register is idempotent on their side ("already registered" comes back as rejected).
            _ = try await call("register", key: key, body: numbers.map { ["number": $0] })
            let info = try await call("gettrackinfo", key: key, body: numbers.map { ["number": $0] })
            let accepted = ((info["data"] as? [String: Any])?["accepted"] as? [[String: Any]]) ?? []
            for item in accepted {
                guard let number = item["number"] as? String,
                      let parcel = active.first(where: { $0.tracking == number }) else { continue }
                let track = item["track_info"] as? [String: Any]
                let latest = track?["latest_status"] as? [String: Any]
                let event = track?["latest_event"] as? [String: Any]
                let status = Self.map(latest?["status"] as? String)
                let text = event?["description"] as? String
                let at = (event?["time_utc"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
                let estimate = ((track?["time_metrics"] as? [String: Any])?["estimated_delivery_date"] as? [String: Any])
                let expected = (estimate?["from"] as? String ?? estimate?["to"] as? String).flatMap(Self.parseDate)
                ParcelStore.shared.applyTracking(id: parcel.id, status: status, carrierText: text, expected: expected, at: at)
            }
            lastError = nil
            NSLog("📦 Tracking: \(accepted.count) of \(numbers.count) parcels updated")
        } catch {
            lastError = "Couldn't reach 17TRACK: \(error.localizedDescription)"
            NSLog("📦 Tracking failed: \(error.localizedDescription)")
        }
    }

    static func map(_ s: String?) -> Parcel.Status? {
        switch s {
        case "InfoReceived": return .ordered
        case "InTransit": return .dispatched
        case "OutForDelivery": return .outForDelivery
        case "DeliveryFailure", "Exception": return .attempted
        case "AvailableForPickup": return .attempted
        case "Delivered": return .delivered
        default: return nil
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withFullDate]
        return iso.date(from: String(s.prefix(10)))
    }

    private func call(_ path: String, key: String, body: Any) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.17track.net/track/v2.2/\(path)")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "17token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// While a parcel is due, keep an eye on the door for you.
@MainActor
public enum DeliveryWatch {
    /// Parcels due today and not here yet.
    public static var expecting: [Parcel] { ParcelStore.shared.parcels.filter(\.isExpectedToday) }
    public static var isActive: Bool { !expecting.isEmpty && UserDefaults.standard.object(forKey: "deliveryWatchEnabled") as? Bool ?? true }

    /// One reminder per parcel per day, with a "Watch door" action.
    public static func remindIfDue(doorbellId: Int?) async {
        let today = Date().formatted(.iso8601.year().month().day())
        for p in expecting where p.remindedOn != today {
            ParcelStore.shared.markReminded(p.id)
            let content = UNMutableNotificationContent()
            content.title = p.status == .outForDelivery ? "\(p.title) is out for delivery" : "\(p.title) is due today"
            content.body = isActive ? "Doorstep will show you the door when someone arrives." : "Keep an eye on the door."
            if let doorbellId { content.userInfo = ["watchDevice": doorbellId] }
            content.categoryIdentifier = NotificationManager.watchCategory
            if UserDefaults.standard.object(forKey: "notificationSound") as? Bool ?? true { content.sound = .default }
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "parcel-\(p.id)-\(today)", content: content, trigger: nil))
            NSLog("📦 Reminder: \(content.title)")
        }
    }

    /// Short line for the Wall: "DPD parcel from ASOS, out for delivery".
    public static func line(for p: Parcel) -> String {
        var s = p.title
        if p.status == .outForDelivery { s += " · out for delivery" }
        else if let e = p.expected, Calendar.current.isDateInToday(e) { s += " · due today" }
        return s
    }
}
