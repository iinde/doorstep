import Foundation

/// Plain-English search over everything Doorstep knows about each moment, on this Mac.
/// "DPD last week", "person at the garden yesterday evening", "knock", "AB12 CDE",
/// "parcel left", "dog", "doorbell this morning", "Royal Mail tuesday".
public struct MomentSearch {
    public let text: String
    private var words: [String] = []

    public init(_ text: String) {
        self.text = text
        words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { words.isEmpty }

    private func has(_ w: String) -> Bool { words.contains(w) }
    private func phrase(_ p: String) -> Bool { text.lowercased().contains(p) }

    /// The days the query is about, or nil for any day.
    private var dayRange: ClosedRange<Date>? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        if has("today") || phrase("this morning") || phrase("this afternoon") || phrase("this evening") || has("tonight") {
            return today...Date()
        }
        if has("yesterday") { return day(-1)...day(0).addingTimeInterval(-1) }
        if phrase("last week") || phrase("past week") || phrase("this week") { return day(-7)...Date() }
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let i = names.firstIndex(where: { has($0) || has(String($0.prefix(3))) }) {
            // The most recent such day (today counts).
            for back in 0..<7 {
                let d = day(-back)
                if cal.component(.weekday, from: d) == i + 1 { return d...d.addingTimeInterval(86399) }
            }
        }
        return nil
    }

    private var hourRange: ClosedRange<Int>? {
        if has("morning") { return 5...11 }
        if has("afternoon") { return 12...16 }
        if has("evening") || has("tonight") { return 17...22 }
        if has("night") || has("overnight") { return 0...5 }
        return nil
    }

    public func matches(_ m: Moment) -> Bool {
        if let r = dayRange, !(r.contains(m.end) || r.contains(m.start)) { return false }
        if let h = hourRange {
            let hour = Calendar.current.component(.hour, from: m.end)
            if h == 0...5 ? !(hour >= 23 || hour <= 5) : !h.contains(hour) { return false }
        }
        // Everything else must be about this moment.
        var haystack = [m.title.lowercased(), m.deviceName.lowercased()]
        if let id = m.identity {
            if let c = id.carrier { haystack.append(c.rawValue.lowercased()) }
            if id.isDelivery { haystack += ["delivery", "courier", "driver", "parcel"] }
            if let note = id.note { haystack.append(note.lowercased()) }
        }
        if m.parcelLeft { haystack += ["parcel left", "package", "parcel"] }
        if m.parcelTaken { haystack += ["parcel taken", "stolen", "theft", "parcel"] }
        switch m.tier {
        case .doorbell: haystack += ["doorbell", "ring", "rang", "ding", "person", "people", "someone"]
        case .people: haystack += ["person", "people", "someone", "visitor", "visit"]
        case .activity: haystack += ["motion", "movement", "activity"]
        }
        for s in m.sounds { haystack.append(s.rawValue.lowercased()) }
        if m.sounds.contains(.knock) { haystack += ["knock", "knocked"] }
        if m.sounds.contains(.dog) { haystack += ["dog", "bark"] }
        for e in m.events {
            haystack += (TagIndex.shared.sawPerson(e.id) ? ["person"] : [])
        }
        let plates = PlateIndex.shared.all.filter { s in m.events.contains { $0.id == s.eventId } }
        for p in plates {
            haystack.append(p.plate.lowercased())
            if let n = PlateIndex.shared.name(p.plate) { haystack.append(n.lowercased()) }
        }
        let all = haystack.joined(separator: " ")

        let ignore: Set<String> = ["at", "the", "a", "an", "in", "on", "by", "of", "when", "did", "who", "came", "come", "show",
                                   "me", "any", "last", "this", "week", "past", "today", "yesterday", "morning", "afternoon",
                                   "evening", "night", "tonight", "overnight", "sunday", "monday", "tuesday", "wednesday",
                                   "thursday", "friday", "saturday", "sun", "mon", "tue", "wed", "thu", "fri", "sat", "my",
                                   "was", "were", "there", "front", "back"]
        // Plates typed with a space ("AB12 CDE") match as one token.
        let compact = text.uppercased().filter { $0.isLetter || $0.isNumber }
        if compact.count >= 5, plates.contains(where: { $0.plate == compact }) { return true }
        let wanted = words.filter { !ignore.contains($0) }
        let synonyms: [String: [String]] = ["postie": ["royal mail"], "postman": ["royal mail"], "post": ["royal mail"],
                                            "amazon": ["amazon"], "van": ["vehicle", "delivery"], "car": ["vehicle"],
                                            "package": ["parcel"], "knocking": ["knock"], "barking": ["dog"]]
        for w in wanted {
            let options = [w] + (synonyms[w] ?? [])
            if !options.contains(where: { all.contains($0) }) {
                // "front" and "door" etc. are covered by the camera name.
                if w == "door", all.contains("door") || m.tier == .doorbell { continue }
                return false
            }
        }
        return true
    }
}
