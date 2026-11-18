import Foundation
import RingClient

/// The three tiers from the brief, each with one job.
public enum MomentTier: Int, Comparable, Sendable {
    case activity = 0   // other motion
    case people = 1     // a person was seen
    case doorbell = 2   // someone rang

    public static func < (a: MomentTier, b: MomentTier) -> Bool { a.rawValue < b.rawValue }

    static func of(_ event: RingEvent) -> MomentTier {
        if event.kind == .ding { return .doorbell }
        // Ring's own flag, or a person this Mac's Vision pass found in the clip.
        if event.personDetected == true || TagIndex.shared.sawPerson(event.id) { return .people }
        if let id = IdentityIndex.shared.identity(event.id), id.who != nil || id.parcelLeft || id.parcelTaken { return .people }
        if let heard = SoundIndex.shared.sounds(event.id), heard.contains(.knock) || heard.contains(.glass) { return .people }
        return .activity
    }
}

/// Events on one camera that happen close together, bundled into one thing to look at.
public struct Moment: Identifiable, Sendable {
    public let id: String
    public let deviceKey: String
    public let deviceName: String
    public let events: [RingEvent]   // oldest first
    public let tier: MomentTier

    public var start: Date { events.first!.createdAt }
    public var end: Date { events.last!.createdAt }
    /// The clip to play for this moment: the most significant, then the latest.
    public var headline: RingEvent {
        events.max { (MomentTier.of($0), $0.createdAt) < (MomentTier.of($1), $1.createdAt) }!
    }

    /// The best identity across this Moment's clips: you > text > taught > Claude > livery.
    public var identity: Identity? {
        let ids = events.compactMap { IdentityIndex.shared.identity($0.id) }
        func rank(_ i: Identity) -> Double {
            (i.who == nil ? 0 : 10) + (i.parcelLeft || i.parcelTaken ? 5 : 0) + i.confidence
        }
        return ids.max { rank($0) < rank($1) }
    }

    public var parcelLeft: Bool { events.contains { IdentityIndex.shared.identity($0.id)?.parcelLeft == true } }
    public var parcelTaken: Bool { events.contains { IdentityIndex.shared.identity($0.id)?.parcelTaken == true } }

    /// What this Mac heard across the clips.
    public var sounds: Set<DoorSound> {
        Set(events.flatMap { SoundIndex.shared.sounds($0.id) ?? [] })
    }

    public var title: String {
        if parcelTaken { return "Parcel taken from \(deviceName)" }
        if tier != .doorbell, sounds.contains(.knock) { return "Someone knocked at \(deviceName)" }
        if sounds.contains(.glass) { return "Glass breaking at \(deviceName)" }
        if let who = identity?.who {
            if parcelLeft { return "\(who) left a parcel" }
            return tier == .doorbell ? "\(who) rang \(deviceName)" : "\(who) at \(deviceName)"
        }
        if parcelLeft { return "Parcel left at \(deviceName)" }
        switch tier {
        case .doorbell: return "Someone rang \(deviceName)"
        case .people: return "Person at \(deviceName)"
        case .activity: return "Activity at \(deviceName)"
        }
    }
}

public enum MomentBuilder {
    /// Events within this gap on the same camera merge into one Moment.
    public static let mergeGap: TimeInterval = 180

    /// Ring logs your own live views as events. They're not things that happened outside.
    public static func isOutsideEvent(_ e: RingEvent) -> Bool {
        e.kind != .onDemand
    }

    public static func key(for e: RingEvent) -> String {
        e.deviceId.map(String.init) ?? (e.deviceName ?? "unknown")
    }

    /// Newest first.
    public static func build(from events: [RingEvent]) -> [Moment] {
        let outside = events.filter(isOutsideEvent)
        let byDevice = Dictionary(grouping: outside, by: key(for:))
        var moments: [Moment] = []
        for (deviceKey, list) in byDevice {
            let sorted = list.sorted { $0.createdAt < $1.createdAt }
            var bucket: [RingEvent] = []
            func flush() {
                guard let first = bucket.first else { return }
                moments.append(Moment(
                    id: "\(deviceKey)-\(first.id)",
                    deviceKey: deviceKey,
                    deviceName: first.deviceName ?? "Camera",
                    events: bucket,
                    tier: bucket.map(MomentTier.of).max() ?? .activity
                ))
                bucket = []
            }
            for e in sorted {
                if let last = bucket.last, e.createdAt.timeIntervalSince(last.createdAt) > mergeGap { flush() }
                bucket.append(e)
            }
            flush()
        }
        return moments.sorted { $0.end > $1.end }
    }
}
