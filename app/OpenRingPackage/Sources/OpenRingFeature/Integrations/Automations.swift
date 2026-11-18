import Foundation
import AVFoundation
import RingClient

/// Things that happen at the door, for automations and announcements.
public enum DoorTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case doorbell = "Doorbell rings"
    case person = "A person is seen"
    case approaching = "Someone walks up to the door"
    case delivery = "A delivery arrives"
    case parcelLeft = "A parcel is left"
    case parcelTaken = "A parcel is taken"
    public var id: String { rawValue }
}

/// "When this happens, run that Shortcut." Shortcuts reach HomeKit (porch lights), Music,
/// Messages and anything else on the Mac, so Doorstep needs no integrations of its own.
public struct Automation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var trigger: DoorTrigger
    public var shortcut: String
    public var onlyAfterDark = false
    public var camera: String?        // nil = any camera
    public var enabled = true
}

@MainActor
public final class Automations: ObservableObject {
    public static let shared = Automations()
    @Published public var rules: [Automation] = [] { didSet { save() } }
    @Published public private(set) var shortcutNames: [String] = []
    @Published public private(set) var lastRun: String?
    private var cooldown: [String: Date] = [:]
    private let speech = AVSpeechSynthesizer()

    private init() {
        if !DemoMode.isOn, let data = UserDefaults.standard.data(forKey: "automations"),
           let saved = try? JSONDecoder().decode([Automation].self, from: data) { rules = saved }
    }

    private func save() {
        guard !DemoMode.isOn else { return }
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "automations") }
    }

    /// The user's shortcuts, from the `shortcuts` command that ships with macOS.
    public func loadShortcuts() async {
        let out = await Self.run(["list"])
        shortcutNames = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
    }

    /// Something happened. Runs matching automations (once a minute at most per rule)
    /// and, if switched on, says it out loud.
    public func fire(_ trigger: DoorTrigger, camera: String, detail: String, location: (Double, Double)? = nil) {
        if UserDefaults.standard.bool(forKey: "speakAnnouncements") && !DemoMode.isOn {
            let words: String
            switch trigger {
            case .doorbell: words = "Someone's at the door"
            case .approaching: words = "Someone's coming to the \(camera.lowercased())"
            case .delivery: words = detail.isEmpty ? "Delivery at the door" : detail
            case .parcelLeft: words = "A parcel was left at the \(camera.lowercased())"
            case .parcelTaken: words = "A parcel was taken from the \(camera.lowercased())"
            case .person: words = ""
            }
            if !words.isEmpty {
                let u = AVSpeechUtterance(string: words)
                u.voice = AVSpeechSynthesisVoice(language: "en-GB")
                speech.speak(u)
            }
        }
        let spot = location ?? EventDirectory.shared.home
        let dark = spot.map { !SolarClock.isDaylight(lat: $0.0, lon: $0.1) } ?? SolarClock.isEvening
        for rule in rules where rule.enabled && rule.trigger == trigger
            && (rule.camera == nil || rule.camera == camera) && (!rule.onlyAfterDark || dark) {
            if let t = cooldown[rule.id.uuidString], Date().timeIntervalSince(t) < 60 { continue }
            cooldown[rule.id.uuidString] = Date()
            let name = rule.shortcut
            let input = "\(trigger.rawValue) at \(camera). \(detail)"
            lastRun = "Ran \"\(name)\" (\(trigger.rawValue.lowercased()), \(Date().formatted(date: .omitted, time: .shortened)))"
            NSLog("⚙️ Automation: \(trigger.rawValue) at \(camera) -> \(name)")
            // Demo mode shows what would run, and never runs anything.
            if !DemoMode.isOn { Task.detached { _ = await Self.run(["run", name], input: input) } }
        }
    }

    public func test(_ rule: Automation) {
        cooldown[rule.id.uuidString] = nil
        lastRun = "Testing \"\(rule.shortcut)\""
        let name = rule.shortcut
        if !DemoMode.isOn { Task.detached { _ = await Self.run(["run", name], input: "Test from Doorstep") } }
    }

    nonisolated static func run(_ args: [String], input: String? = nil) async -> String {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            var a = args
            let tmp: URL? = input.map { text in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("doorstep-\(UUID().uuidString).txt")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                return url
            }
            if let tmp { a += ["--input-path", tmp.path] }
            p.arguments = a
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            p.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let tmp { try? FileManager.default.removeItem(at: tmp) }
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { cont.resume(returning: "") }
        }
    }
}

/// Sunrise and sunset from latitude and longitude (NOAA's simplified formula), so
/// "after dark" means after dark where the cameras are.
public enum SolarClock {
    public static var isEvening: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 17 || h < 7
    }

    public static func isDaylight(lat: Double, lon: Double, at date: Date = Date()) -> Bool {
        guard let (rise, set) = sunTimes(lat: lat, lon: lon, on: date) else { return !isEvening }
        return date >= rise && date <= set
    }

    public static func sunTimes(lat: Double, lon: Double, on date: Date) -> (Date, Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let rad = Double.pi / 180
        let gamma = 2 * .pi / 365 * (day - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                               - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma) - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma) - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let cosHA = cos(90.833 * rad) / (cos(lat * rad) * cos(decl)) - tan(lat * rad) * tan(decl)
        guard cosHA >= -1, cosHA <= 1 else { return nil }
        let ha = acos(cosHA) / rad
        let startOfDay = cal.startOfDay(for: date)
        let riseMin = 720 - 4 * (lon + ha) - eqTime
        let setMin = 720 - 4 * (lon - ha) - eqTime
        return (startOfDay.addingTimeInterval(riseMin * 60), startOfDay.addingTimeInterval(setMin * 60))
    }
}
