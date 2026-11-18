import Foundation
import RingClient

/// A parcel you're expecting (or that came). Everything stays on this Mac.
public struct Parcel: Codable, Identifiable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Comparable {
        case ordered, dispatched, outForDelivery, attempted, delivered, collected

        var rank: Int {
            switch self {
            case .ordered: return 0
            case .dispatched: return 1
            case .outForDelivery: return 2
            case .attempted: return 3
            case .delivered: return 4
            case .collected: return 4
            }
        }
        public static func < (a: Status, b: Status) -> Bool { a.rank < b.rank }

        public var label: String {
            switch self {
            case .ordered: return "Ordered"
            case .dispatched: return "On its way"
            case .outForDelivery: return "Out for delivery"
            case .attempted: return "Missed delivery"
            case .delivered: return "Delivered"
            case .collected: return "Collected"
            }
        }
    }

    public var id: String
    public var tracking: String?
    public var carrier: Carrier?
    public var from: String?          // the shop
    public var status: Status
    public var updated: Date
    public var deliveredAt: Date?
    /// The Moment that shows it arriving.
    public var eventId: String?
    public var dismissed = false
    // Added in 0.3: all optional so older parcels.json files still load.
    /// The day the shop or carrier says it will come.
    public var expected: Date?
    /// What happened to it, oldest first.
    public var steps: [Step]?
    /// The carrier's own wording, from live tracking.
    public var carrierStatus: String?
    public var lastChecked: Date?
    /// Day (yyyy-mm-dd) we last sent the "coming today" reminder.
    public var remindedOn: String?

    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public var id: String { "\(date.timeIntervalSince1970)-\(text)" }
        public var date: Date
        public var text: String
        public var eventId: String?
    }

    public var title: String {
        if let from { return "Your \(from) parcel" }
        if let carrier { return "\(carrier.rawValue) parcel" }
        return "Parcel"
    }

    public var isActive: Bool { !dismissed && status < .delivered && updated > Date().addingTimeInterval(-14 * 86400) }
    /// Out for delivery today, or due today and not here yet.
    public var isExpectedToday: Bool {
        guard !dismissed, status < .delivered else { return false }
        if status == .outForDelivery && Calendar.current.isDateInToday(updated) { return true }
        if let expected, Calendar.current.isDateInToday(expected) { return true }
        return false
    }

    /// The carrier's own tracking page, or a universal tracker when unknown.
    public var trackingURL: URL? {
        guard let t = tracking?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        let s: String
        switch carrier {
        case .royalMail: s = "https://www.royalmail.com/track-your-item#/tracking-results/\(t)"
        case .parcelforce: s = "https://www.parcelforce.com/track-trace?trackNumber=\(t)"
        case .dpd: s = "https://track.dpd.co.uk/parcels/\(t)"
        case .dhl: s = "https://www.dhl.com/gb-en/home/tracking/tracking-parcel.html?submit=1&tracking-id=\(t)"
        case .evri: s = "https://www.evri.com/track/parcel/\(t)"
        case .ups: s = "https://www.ups.com/track?tracknum=\(t)"
        case .fedex: s = "https://www.fedex.com/fedextrack/?trknbr=\(t)"
        case .yodel: s = "https://www.yodel.co.uk/tracking/\(t)"
        case .amazon: s = "https://www.amazon.co.uk/gp/your-account/order-history"
        default: s = "https://t.17track.net/en#nums=\(t)"
        }
        return URL(string: s)
    }
}

@MainActor
public final class ParcelStore: ObservableObject {
    public static let shared = ParcelStore()
    @Published public private(set) var parcels: [Parcel] = []
    private let file: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Doorstep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("parcels.json")
        if !DemoMode.isOn, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Parcel].self, from: data) { parcels = saved }
    }

    public var active: [Parcel] { parcels.filter(\.isActive).sorted { $0.status > $1.status } }
    public var expectedToday: [Parcel] { parcels.filter(\.isExpectedToday) }
    public var recent: [Parcel] {
        parcels.filter { !$0.dismissed && $0.updated > Date().addingTimeInterval(-30 * 86400) }
            .sorted { $0.updated > $1.updated }
    }

    /// Merge what an email or a paste told us. Same tracking number = same parcel; status only moves forward.
    @discardableResult
    public func ingest(_ found: [Parcel]) -> Int {
        var changed = 0
        for p in found {
            if let i = parcels.firstIndex(where: { same($0, p) }) {
                var cur = parcels[i]
                if p.status >= cur.status && p.updated >= cur.updated {
                    if p.status != cur.status {
                        cur.steps = (cur.steps ?? []) + [Parcel.Step(date: p.updated, text: p.status.label)]
                    }
                    cur.status = p.status
                    cur.updated = p.updated
                    if p.status >= .delivered { cur.deliveredAt = p.deliveredAt ?? p.updated }
                }
                cur.carrier = cur.carrier ?? p.carrier
                cur.from = cur.from ?? p.from
                cur.tracking = cur.tracking ?? p.tracking
                if cur != parcels[i] { parcels[i] = cur; changed += 1 }
            } else {
                var new = p
                new.steps = [Parcel.Step(date: p.updated, text: p.status == .ordered ? "Ordered" : "Added: \(p.status.label.lowercased())")]
                parcels.append(new)
                changed += 1
            }
        }
        if changed > 0 { save() }
        return changed
    }

    private func same(_ a: Parcel, _ b: Parcel) -> Bool {
        if let ta = a.tracking, let tb = b.tracking { return ta == tb }
        // No numbers: same shop and carrier within 10 days.
        return a.tracking == nil && b.tracking == nil && a.from != nil && a.from == b.from && a.carrier == b.carrier
            && abs(a.updated.timeIntervalSince(b.updated)) < 10 * 86400 && a.status < .delivered
    }

    /// "I'm expecting a parcel": what you typed in.
    @discardableResult
    public func expect(tracking: String?, carrier: Carrier?, shop: String?, expected: Date?) -> Parcel {
        let number = tracking?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: " ", with: "")
        let num = (number?.isEmpty ?? true) ? nil : number
        let detected = carrier ?? num.flatMap { n in Carrier.distinctiveShapes.first { n.range(of: $0.1, options: .regularExpression) != nil }?.0 }
        let shopName = (shop?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        if let num, let i = parcels.firstIndex(where: { $0.tracking == num }) {
            parcels[i].dismissed = false
            parcels[i].carrier = parcels[i].carrier ?? detected
            parcels[i].from = parcels[i].from ?? shopName
            parcels[i].expected = expected ?? parcels[i].expected
            save()
            return parcels[i]
        }
        var p = Parcel(id: num ?? UUID().uuidString, tracking: num, carrier: detected, from: shopName,
                       status: .dispatched, updated: Date())
        p.expected = expected
        var first = "You added it"
        if let expected { first += ", due \(expected.formatted(.dateTime.weekday(.wide).day().month()))" }
        p.steps = [Parcel.Step(date: Date(), text: first)]
        parcels.append(p)
        save()
        return p
    }

    /// Live tracking said something new.
    func applyTracking(id: String, status: Parcel.Status?, carrierText: String?, expected: Date?, at: Date) {
        guard let i = parcels.firstIndex(where: { $0.id == id }) else { return }
        var p = parcels[i]
        p.lastChecked = Date()
        if let expected { p.expected = expected }
        if let carrierText, carrierText != p.carrierStatus {
            p.carrierStatus = carrierText
        }
        if let status, status > p.status {
            p.status = status
            p.updated = at
            if status >= .delivered { p.deliveredAt = p.deliveredAt ?? at }
            p.steps = (p.steps ?? []) + [Parcel.Step(date: at, text: carrierText.map { "\(status.label): \($0)" } ?? status.label)]
        }
        parcels[i] = p
        save()
    }

    func markReminded(_ id: String) {
        guard let i = parcels.firstIndex(where: { $0.id == id }) else { return }
        parcels[i].remindedOn = Date().formatted(.iso8601.year().month().day())
        save()
    }

    public func dismiss(_ p: Parcel) {
        guard let i = parcels.firstIndex(where: { $0.id == p.id }) else { return }
        parcels[i].dismissed = true
        save()
    }

    public func markDelivered(_ p: Parcel) {
        guard let i = parcels.firstIndex(where: { $0.id == p.id }) else { return }
        parcels[i].status = .delivered
        parcels[i].deliveredAt = Date()
        parcels[i].updated = Date()
        parcels[i].steps = (parcels[i].steps ?? []) + [Parcel.Step(date: Date(), text: "You marked it delivered")]
        save()
    }

    /// Tie "delivered" parcels to the Moment at the door around then. Prefers the same carrier,
    /// then a parcel-left moment, then anyone at the doorbell.
    public func link(moments: [Moment], doorbellKeys: Set<String>) {
        var changed = false
        for i in parcels.indices where parcels[i].eventId == nil && parcels[i].status >= .delivered {
            guard let at = parcels[i].deliveredAt else { continue }
            let near = moments.filter { m in
                doorbellKeys.contains(m.deviceKey) && m.tier >= .people
                    && m.end > at.addingTimeInterval(-25 * 60) && m.start < at.addingTimeInterval(5 * 60)
            }
            let carrier = parcels[i].carrier
            let best = near.first { carrier != nil && $0.identity?.carrier == carrier }
                ?? near.first { $0.parcelLeft }
                ?? near.min { abs($0.end.timeIntervalSince(at)) < abs($1.end.timeIntervalSince(at)) }
            if let best {
                parcels[i].eventId = best.headline.id
                parcels[i].steps = (parcels[i].steps ?? []) + [Parcel.Step(date: best.end, text: best.title, eventId: best.headline.id)]
                changed = true
            }
        }
        // And the other way: a doorbell Moment where a parcel was left, with nothing linked,
        // marks the one parcel out for delivery today as delivered.
        for m in moments where m.parcelLeft && Calendar.current.isDateInToday(m.end)
            && !parcels.contains(where: { $0.eventId == m.headline.id }) {
            let out = parcels.indices.filter { parcels[$0].isExpectedToday }
            let match = out.first { parcels[$0].carrier != nil && parcels[$0].carrier == m.identity?.carrier }
                ?? (out.count == 1 ? out.first : nil)
            if let j = match {
                parcels[j].status = .delivered
                parcels[j].deliveredAt = m.end
                parcels[j].eventId = m.headline.id
                parcels[j].steps = (parcels[j].steps ?? []) + [Parcel.Step(date: m.end, text: m.title, eventId: m.headline.id)]
                changed = true
            }
        }
        if changed { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(parcels) { if !DemoMode.isOn { try? data.write(to: file, options: .atomic) } }
    }
}

/// Reads delivery emails (or anything pasted) into parcel facts. No network.
public enum ParcelParser {
    /// One email, or a pasted chunk of text.
    public static func parse(subject: String = "", from sender: String = "", body: String, date: Date = Date()) -> [Parcel] {
        let text = subject + "\n" + body
        let lower = text.lowercased()
        let senderLower = sender.lowercased()

        let carrierFromSender = Carrier.allCases.first { c in c.mailDomains.contains { senderLower.contains($0) } }
        let carrierInText = carrierFromSender ?? Carrier.allCases.first { c in
            !c.isGrocery && c.paintedWords.contains { lower.contains($0.lowercased()) }
        }

        let status = status(in: lower)
        guard status != nil || numbers(in: text, carrier: carrierInText).count > 0 else { return [] }

        // The shop: the sender's display name when it isn't the carrier itself.
        var shop: String?
        let display = sender.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
        if let display, !display.isEmpty, carrierFromSender == nil, !display.contains("@") { shop = display }
        if shop == nil, let m = lower.range(of: #"your (?:order|parcel|delivery) from ([a-z0-9&' .-]{2,30}?)(?:[ ,.!]| is| has| will|$)"#, options: .regularExpression) {
            let phrase = String(text[m])
            if let r = phrase.range(of: "from ", options: .caseInsensitive) {
                shop = phrase[r.upperBound...].components(separatedBy: CharacterSet(charactersIn: ",.!\n")).first?
                    .replacingOccurrences(of: " is", with: "").replacingOccurrences(of: " has", with: "")
                    .replacingOccurrences(of: " will", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        if shop == nil, carrierFromSender == .amazon || (carrierFromSender == nil && senderLower.contains("amazon")) { shop = "Amazon" }

        let found = numbers(in: text, carrier: carrierInText)
        let st = status ?? .dispatched
        if found.isEmpty {
            guard carrierInText != nil || shop != nil else { return [] }
            return [Parcel(id: UUID().uuidString, tracking: nil, carrier: carrierInText, from: shop, status: st,
                           updated: date, deliveredAt: st >= .delivered ? date : nil)]
        }
        return found.map { (num, carrier) in
            Parcel(id: num, tracking: num, carrier: carrier ?? carrierInText, from: shop, status: st,
                   updated: date, deliveredAt: st >= .delivered ? date : nil)
        }
    }

    static func status(in lower: String) -> Parcel.Status? {
        let checks: [(Parcel.Status, [String])] = [
            (.collected, ["has been collected", "you collected", "picked up from"]),
            (.delivered, ["has been delivered", "was delivered", "is delivered", "delivered today", "your parcel was left",
                          "we delivered", "delivered to", "delivered!", "has arrived", "left in your safe place", "handed to"]),
            (.attempted, ["sorry we missed you", "we missed you", "delivery attempt", "attempted delivery", "couldn't deliver", "could not deliver"]),
            (.outForDelivery, ["out for delivery", "arriving today", "on its way to you today", "with your driver",
                               "driver is on", "will be delivered today", "due today", "your delivery window", "is nearby"]),
            (.dispatched, ["dispatched", "has shipped", "on its way", "shipped", "in transit", "tracking number"]),
            (.ordered, ["order confirmation", "thanks for your order", "thank you for your order", "order received"]),
        ]
        for (s, words) in checks where words.contains(where: { lower.contains($0) }) { return s }
        return nil
    }

    /// Tracking numbers in the text, with the carrier when the shape alone says so.
    static func numbers(in text: String, carrier: Carrier?) -> [(String, Carrier?)] {
        let upper = text.uppercased()
        var out: [(String, Carrier?)] = []
        func scan(_ pattern: String, _ c: Carrier?) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            for m in re.matches(in: upper, range: NSRange(upper.startIndex..., in: upper)) {
                guard let r = Range(m.range, in: upper) else { continue }
                let num = String(upper[r])
                // Real numbers are mostly digits; this rejects words that fit a letter pattern.
                guard num.filter(\.isNumber).count >= 7, !out.contains(where: { $0.0 == num }) else { continue }
                // Skip phone numbers and order numbers written next to their label.
                let before = upper[upper.index(r.lowerBound, offsetBy: -min(24, upper.distance(from: upper.startIndex, to: r.lowerBound)))..<r.lowerBound]
                if before.contains("ORDER") || before.contains("TEL") || before.contains("PHONE") || before.contains("CALL") { continue }
                out.append((num, c))
            }
        }
        for (c, p) in Carrier.distinctiveShapes { scan(p, c) }
        if let carrier { for p in carrier.trackingPatterns { scan(p, carrier) } }
        return Array(out.prefix(3))
    }
}
