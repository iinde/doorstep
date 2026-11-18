import Foundation
import RingClient

// MARK: - What you get alerted about

/// The kinds of thing an alert can be about. You choose which ones notify you.
public enum AlertKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case doorbell = "Doorbell rings"
    case people = "People"
    case parcels = "Parcels left or taken"
    case vehicles = "Vehicles"
    case animals = "Animals"
    case motion = "Any other movement"
    case familiar = "Familiar faces"
    case unusual = "Unusual activity"
    public var id: String { rawValue }

    var defaultOn: Bool {
        switch self {
        case .doorbell, .people, .parcels, .familiar, .unusual: return true
        case .vehicles, .animals, .motion: return false
        }
    }

    var key: String { "alert." + String(describing: self) }

    public var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

public enum AlertPolicy {
    /// One alert per visit: later clips of the same visit update the first alert instead of
    /// stacking new ones.
    public static var singleEventAlerts: Bool {
        UserDefaults.standard.object(forKey: "singleEventAlerts") as? Bool ?? true
    }

    /// What an event is about, most important first.
    static func kinds(for event: RingEvent, identity: Identity?, tags: [String], familiar: String?, unusual: Bool) -> [AlertKind] {
        var out: [AlertKind] = []
        if event.kind == .ding { out.append(.doorbell) }
        if familiar != nil { out.append(.familiar) }
        if identity?.parcelLeft == true || identity?.parcelTaken == true { out.append(.parcels) }
        if unusual { out.append(.unusual) }
        if MomentTier.of(event) >= .people { out.append(.people) }
        if tags.contains("Vehicle") { out.append(.vehicles) }
        if tags.contains("Animal") || SoundIndex.shared.sounds(event.id)?.contains(.dog) == true { out.append(.animals) }
        if out.isEmpty { out.append(.motion) }
        return out
    }

    /// Should this event alert you, given your choices and the current mode?
    @MainActor
    static func shouldAlert(_ kinds: [AlertKind], camera: Int?) -> Bool {
        if !Modes.shared.allowsAlerts(camera: camera) {
            // Doorbell rings always come through unless the mode silences everything.
            return kinds.contains(.doorbell) && Modes.shared.current != .off
        }
        return kinds.contains { $0.isOn }
    }

    /// Unusual: a person at an hour that's rare for this camera (under 3% of what it has seen).
    static func isUnusual(_ event: RingEvent) -> Bool {
        guard MomentTier.of(event) >= .people, let id = event.deviceId else { return false }
        let history = EventDirectory.shared.allEvents.filter { $0.deviceId == id && MomentBuilder.isOutsideEvent($0) }
        guard history.count >= 60 else { return false }
        let hour = Calendar.current.component(.hour, from: event.createdAt)
        let sameHour = history.filter { Calendar.current.component(.hour, from: $0.createdAt) == hour }.count
        return Double(sameHour) / Double(history.count) < 0.03
    }
}

// MARK: - Modes

/// Home, Away and Night, like an alarm panel: each says which cameras alert and record.
/// Off by default; when off, Doorstep behaves as if every camera is on in every way.
@MainActor
public final class Modes: ObservableObject {
    public static let shared = Modes()

    public enum Mode: String, CaseIterable, Identifiable, Codable, Sendable {
        case home = "Home", away = "Away", night = "Night", off = "Quiet"
        public var id: String { rawValue }
        public var symbol: String {
            switch self {
            case .home: return "house"
            case .away: return "figure.walk.departure"
            case .night: return "moon"
            case .off: return "bell.slash"
            }
        }
        public var explanation: String {
            switch self {
            case .home: return "You're in. Alerts from the doorbell and front cameras."
            case .away: return "Nobody's in. Every camera alerts and records."
            case .night: return "Asleep. Only people near the house, and anything unusual."
            case .off: return "No alerts at all. Recording carries on."
            }
        }
    }

    public struct Rules: Codable, Equatable, Sendable {
        public var alerts: Set<Int>
        public var records: Set<Int>
    }

    @Published public var enabled: Bool { didSet { if !DemoMode.isOn { UserDefaults.standard.set(enabled, forKey: "modesEnabled") } } }
    @Published public var current: Mode { didSet { save(); NSLog("🏠 Mode: \(current.rawValue)") } }
    @Published public var rules: [Mode: Rules] { didSet { save() } }
    /// Switch to Night and back to Home automatically.
    @Published public var nightSchedule: Bool { didSet { if !DemoMode.isOn { UserDefaults.standard.set(nightSchedule, forKey: "modesNightSchedule") } } }
    @Published public var nightFrom: Int { didSet { UserDefaults.standard.set(nightFrom, forKey: "modesNightFrom") } }
    @Published public var nightTo: Int { didSet { UserDefaults.standard.set(nightTo, forKey: "modesNightTo") } }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "modesEnabled")
        current = Mode(rawValue: d.string(forKey: "modesCurrent") ?? "") ?? .home
        nightSchedule = d.bool(forKey: "modesNightSchedule")
        nightFrom = d.object(forKey: "modesNightFrom") as? Int ?? 23
        nightTo = d.object(forKey: "modesNightTo") as? Int ?? 7
        if !DemoMode.isOn, let data = d.data(forKey: "modesRules"),
           let saved = try? JSONDecoder().decode([Mode: Rules].self, from: data) {
            rules = saved
        } else {
            rules = [:]
        }
    }

    private func save() {
        guard !DemoMode.isOn else { return }
        UserDefaults.standard.set(current.rawValue, forKey: "modesCurrent")
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "modesRules") }
    }

    /// Sensible starting rules for these cameras: Home alerts on doorbells, Away and Night on all.
    public func ensureDefaults(for devices: [RingDevice]) {
        let cams = devices.filter { $0.deviceType == .doorbell || $0.deviceType == .camera }
        let all = Set(cams.map(\.id))
        let bells = Set(cams.filter { $0.deviceType == .doorbell }.map(\.id))
        let wired = Set(cams.filter { !$0.isBatteryPowered }.map(\.id))
        let defaults: [Mode: Rules] = [
            .home: Rules(alerts: bells, records: wired),
            .away: Rules(alerts: all, records: wired),
            .night: Rules(alerts: all, records: wired),
            .off: Rules(alerts: [], records: wired),
        ]
        var r = rules
        for (m, rule) in defaults where r[m] == nil { r[m] = rule }
        // New cameras join Away and Night.
        for id in all where !(r.values.contains { $0.alerts.contains(id) || $0.records.contains(id) }) {
            r[.away]?.alerts.insert(id); r[.night]?.alerts.insert(id)
        }
        if r != rules { rules = r }
    }

    public func allowsAlerts(camera: Int?) -> Bool {
        guard enabled else { return true }
        guard let camera else { return current != .off }
        return rules[current]?.alerts.contains(camera) ?? true
    }

    /// nil when modes are off (the recorder's own camera choice applies).
    public func recordingCameras() -> Set<Int>? {
        guard enabled else { return nil }
        return rules[current]?.records
    }

    public func toggle(_ id: Int, alerts: Bool? = nil, records: Bool? = nil, in mode: Mode) {
        var r = rules[mode] ?? Rules(alerts: [], records: [])
        if let alerts { if alerts { r.alerts.insert(id) } else { r.alerts.remove(id) } }
        if let records { if records { r.records.insert(id) } else { r.records.remove(id) } }
        rules[mode] = r
    }

    /// Night schedule: called every refresh.
    public func tick(now: Date = Date()) {
        guard enabled, nightSchedule, current == .home || current == .night else { return }
        let h = Calendar.current.component(.hour, from: now)
        let night = nightFrom > nightTo ? (h >= nightFrom || h < nightTo) : (h >= nightFrom && h < nightTo)
        let want: Mode = night ? .night : .home
        if want != current { current = want }
    }
}
