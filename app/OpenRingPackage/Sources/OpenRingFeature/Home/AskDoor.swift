import Foundation

/// Plain-English questions about the door, answered from what Doorstep already knows, on this
/// Mac: "Did DPD come today?", "When did the postie come?", "How many times did someone ring
/// this week?", "Has anyone been in the garden?". The matching moments show underneath.
public struct AskDoor {
    public enum Kind { case yesNo, when, howMany, who }
    public let kind: Kind
    /// What's left to search for once the question words are gone.
    public let searchText: String
    /// "anyone", "someone": people only, not leaves blowing about.
    public let peopleOnly: Bool

    private static let openers = ["did ", "has ", "have ", "was ", "were ", "is ", "are ", "any ", "when ", "what time ",
                                  "how many ", "how often ", "who "]
    private static let filler: Set<String> = [
        "did", "has", "have", "was", "were", "is", "are", "any", "anyone", "anybody", "someone", "somebody", "when", "what",
        "time", "how", "many", "often", "times", "who", "been", "come", "came", "coming", "here", "there", "the", "a", "an",
        "to", "at", "in", "my", "our", "yet", "ever", "get", "got", "arrive", "arrived", "visit", "visited", "turn", "turned",
        "up", "round", "around", "by", "it", "they", "anything", "something", "happen", "happened"]

    public init?(_ question: String) {
        let t = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.hasSuffix("?") || Self.openers.contains(where: t.hasPrefix) else { return nil }
        if t.hasPrefix("how many") || t.hasPrefix("how often") { kind = .howMany }
        else if t.hasPrefix("when") || t.hasPrefix("what time") { kind = .when }
        else if t.hasPrefix("who") { kind = .who }
        else { kind = .yesNo }
        let words = t.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        peopleOnly = words.contains { ["anyone", "anybody", "someone", "somebody", "who"].contains($0) }
        searchText = words.filter { !Self.filler.contains($0) }.joined(separator: " ")
    }

    /// The moments that answer it, newest first.
    public func matches(in moments: [Moment]) -> [Moment] {
        let search = MomentSearch(searchText)
        return moments
            .filter { !peopleOnly || $0.tier >= .people }
            .filter { search.isEmpty || search.matches($0) }
            .sorted { $0.end > $1.end }
    }

    /// One sentence.
    public func answer(_ hits: [Moment], days: Int, now: Date = Date()) -> String {
        guard let latest = hits.first else {
            switch kind {
            case .howMany: return "None in the last \(days) days."
            case .who: return "Nobody that Doorstep saw."
            default: return "No, not that Doorstep saw in the last \(days) days."
            }
        }
        let when = Self.when(latest.end, now: now)
        switch kind {
        case .yesNo:
            return "Yes. \(latest.title), \(when)." + (hits.count > 1 ? " \(hits.count) times in all." : "")
        case .when:
            if hits.count == 1 { return "\(Self.capitalised(when)): \(latest.title)." }
            let earlier = hits.dropFirst().prefix(2).map { Self.when($0.end, now: now) }
            return "Most recently \(when). Before that, \(earlier.joined(separator: " and "))."
        case .howMany:
            return hits.count == 1 ? "Once, \(when)." : "\(hits.count) times. Most recently \(when)."
        case .who:
            var names: [String] = []
            for m in hits where !names.contains(m.title) { names.append(m.title); if names.count == 3 { break } }
            return names.joined(separator: "; ") + "."
        }
    }

    static func when(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "yesterday at \(time)" }
        return "on \(date.formatted(.dateTime.weekday(.wide).day().month(.wide))) at \(time)"
    }

    static func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
