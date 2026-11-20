import Foundation
import SwiftUI
import UserNotifications

// MARK: - Bank holidays (GOV.UK, free, no key)

/// UK bank holidays from GOV.UK's public list, fetched once a week and kept on this Mac.
public enum BankHolidays {
    public enum Region: String, CaseIterable, Identifiable {
        case englandWales = "england-and-wales", scotland = "scotland", northernIreland = "northern-ireland"
        public var id: String { rawValue }
        var label: String { self == .englandWales ? "England and Wales" : self == .scotland ? "Scotland" : "Northern Ireland" }
    }
    static var region: Region { Region(rawValue: UserDefaults.standard.string(forKey: "bankHolidayRegion") ?? "") ?? .englandWales }
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Doorstep/bank-holidays.json")
    }
    nonisolated(unsafe) private static var cache: [String: String] = [:]   // "2026-12-25": "Christmas Day"

    /// Name of the bank holiday on this day, if it is one.
    public static func name(on day: Date) -> String? {
        if cache.isEmpty { load() }
        return cache[day.formatted(.iso8601.year().month().day())]
    }

    public static func refreshIfStale() async {
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 7 * 86400 || cache.isEmpty, !DemoMode.isOn,
              let (data, response) = try? await URLSession.shared.data(from: URL(string: "https://www.gov.uk/bank-holidays.json")!),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { load(); return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        load()
    }

    static func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        cache = parse(data, region: region)
    }

    static func parse(_ data: Data, region: Region) -> [String: String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = json[region.rawValue] as? [String: Any],
              let events = r["events"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for e in events { if let d = e["date"] as? String, let t = e["title"] as? String { out[d] = t } }
        return out
    }
}

// MARK: - Bin day

/// Your bin collections, as you set them: which bin, which weekday, weekly or every other week.
/// Doorstep reminds you the evening before. (Councils don't share one free feed, so it's typed in.)
public struct BinCollection: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = "Rubbish"
    public var weekday = 2              // 1 Sunday ... 7 Saturday
    public var fortnightly = false
    /// For fortnightly bins: any date it was collected.
    public var anchor = Date()

    func isCollected(on day: Date) -> Bool {
        let cal = Calendar.current
        guard cal.component(.weekday, from: day) == weekday else { return false }
        guard fortnightly else { return true }
        let weeks = cal.dateComponents([.weekOfYear], from: cal.startOfDay(for: anchor), to: cal.startOfDay(for: day)).weekOfYear ?? 0
        return weeks % 2 == 0
    }
}

@MainActor
public final class BinDays: ObservableObject {
    public static let shared = BinDays()
    @Published public var bins: [BinCollection] { didSet { save() } }
    private init() {
        if !DemoMode.isOn, let d = UserDefaults.standard.data(forKey: "binCollections"),
           let b = try? JSONDecoder().decode([BinCollection].self, from: d) { bins = b } else { bins = [] }
    }
    private func save() {
        guard !DemoMode.isOn, let d = try? JSONEncoder().encode(bins) else { return }
        UserDefaults.standard.set(d, forKey: "binCollections")
    }

    /// Bins going out tomorrow.
    public func tomorrow(from now: Date = Date()) -> [BinCollection] {
        let t = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        return bins.filter { $0.isCollected(on: t) }
    }

    func remindIfDue(now: Date = Date()) async {
        let d = UserDefaults.standard
        let hour = d.object(forKey: "binReminderHour") as? Int ?? 19
        let key = now.formatted(.iso8601.year().month().day())
        let due = tomorrow(from: now)
        guard !due.isEmpty, Calendar.current.component(.hour, from: now) >= hour, d.string(forKey: "binReminded") != key else { return }
        d.set(key, forKey: "binReminded")
        let c = UNMutableNotificationContent()
        c.title = "Bins out tonight"
        var body = due.map(\.name).joined(separator: " and ") + " tomorrow morning."
        let t = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        if let holiday = BankHolidays.name(on: t) ?? BankHolidays.name(on: now) {
            body += " It's around \(holiday), so check your council's dates."
        }
        c.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bins-\(key)", content: c, trigger: nil))
    }
}

// MARK: - The postie's routine

/// Learns when Royal Mail usually comes, and tells you on a delivery day when they haven't.
@MainActor
public final class PostieRoutine {
    public static let shared = PostieRoutine()
    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: "postieRoutine") as? Bool ?? true }
    /// "yyyy-mm-dd" → minute of the day the postie first came.
    private var seen: [String: Int]

    private init() { seen = DemoMode.isOn ? [:] : (UserDefaults.standard.dictionary(forKey: "postieSeen") as? [String: Int] ?? [:]) }

    func record(_ moments: [Moment]) {
        let cal = Calendar.current
        var changed = false
        for m in moments where m.identity?.carrier == .royalMail {
            let key = m.start.formatted(.iso8601.year().month().day())
            let minute = cal.component(.hour, from: m.start) * 60 + cal.component(.minute, from: m.start)
            if seen[key] == nil || minute < seen[key]! { seen[key] = minute; changed = true }
        }
        guard changed, !DemoMode.isOn else { return }
        let cutoff = cal.date(byAdding: .day, value: -60, to: Date())!.formatted(.iso8601.year().month().day())
        seen = seen.filter { $0.key >= cutoff }
        UserDefaults.standard.set(seen, forKey: "postieSeen")
    }

    /// The usual latest arrival: three quarters of days come by then. Needs a week's worth.
    public var usuallyBy: Int? { Self.usuallyBy(Array(seen.values)) }

    nonisolated static func usuallyBy(_ minutes: [Int]) -> Int? {
        guard minutes.count >= 6 else { return nil }
        let s = minutes.sorted()
        return s[(s.count * 3) / 4]
    }

    func checkLate(now: Date = Date()) async {
        guard Self.isEnabled, let by = usuallyBy else { return }
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)
        guard weekday != 1, BankHolidays.name(on: now) == nil else { return }    // no post on Sundays or bank holidays
        let key = now.formatted(.iso8601.year().month().day())
        let minute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let d = UserDefaults.standard
        guard seen[key] == nil, minute >= by + 45, minute < 17 * 60, d.string(forKey: "postieLateSent") != key else { return }
        d.set(key, forKey: "postieLateSent")
        let c = UNMutableNotificationContent()
        c.title = "No post yet today"
        c.body = String(format: "Royal Mail usually comes by %02d:%02d. Nothing seen at the door yet.", by / 60, by % 60)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "postie-\(key)", content: c, trigger: nil))
    }
}

// MARK: - One call from the refresh loop

public enum Routine {
    @MainActor public static func tick(moments: [Moment]) {
        guard !DemoMode.isOn else { return }
        PostieRoutine.shared.record(moments)
        Task {
            await BankHolidays.refreshIfStale()
            await BinDays.shared.remindIfDue()
            await PostieRoutine.shared.checkLate()
        }
    }
}

// MARK: - Settings

struct RoutineSection: View {
    @ObservedObject private var bins = BinDays.shared
    @AppStorage("postieRoutine") private var postie = true
    @AppStorage("bankHolidayRegion") private var region = BankHolidays.Region.englandWales.rawValue
    @AppStorage("binReminderHour") private var hour = 19
    private let days = Calendar.current.weekdaySymbols

    var body: some View {
        Section {
            Toggle("Tell me if the post is late", isOn: $postie)
            if let by = PostieRoutine.shared.usuallyBy {
                Text(String(format: "Your postie usually comes by %02d:%02d.", by / 60, by % 60)).font(.caption).foregroundStyle(.secondary)
            } else if postie {
                Text("Doorstep needs about a week of Royal Mail visits to learn their time.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Bank holidays for", selection: $region) {
                ForEach(BankHolidays.Region.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .onChange(of: region) { _, _ in BankHolidays.load() }
        } header: {
            Text("Post")
        } footer: {
            Text("Doorstep learns when Royal Mail usually arrives and lets you know on a delivery day when they haven't. Sundays and bank holidays are skipped. Bank holidays come from GOV.UK.")
        }
        Section {
            ForEach($bins.bins) { $bin in
                HStack {
                    TextField("Bin", text: $bin.name).frame(width: 130)
                    Picker("", selection: $bin.weekday) {
                        ForEach(1...7, id: \.self) { Text(days[$0 - 1]).tag($0) }
                    }
                    .labelsHidden().frame(width: 120)
                    Toggle("every other week", isOn: $bin.fortnightly).controlSize(.small)
                    if bin.fortnightly {
                        DatePicker("", selection: $bin.anchor, displayedComponents: .date).labelsHidden()
                            .help("Any day this bin was collected")
                    }
                    Spacer()
                    Button(role: .destructive) { bins.bins.removeAll { $0.id == bin.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("Delete bin")
                }
            }
            HStack {
                Button("Add a bin") { bins.bins.append(BinCollection()) }
                Spacer()
                Picker("Remind me at", selection: $hour) {
                    ForEach([17, 18, 19, 20, 21], id: \.self) { Text("\($0):00").tag($0) }
                }
                .frame(width: 170)
            }
        } header: {
            Text("Bin day")
        } footer: {
            Text("A reminder the evening before each collection. For a fortnightly bin, pick any date it was collected and Doorstep works out the rest.")
        }
    }
}
