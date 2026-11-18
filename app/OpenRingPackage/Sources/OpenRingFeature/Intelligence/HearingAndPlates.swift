import Foundation
import AVFoundation
import SoundAnalysis
import Vision
import RingClient

// MARK: - Hearing

/// Sounds in a clip, from Apple's built-in sound classifier (300+ sounds, on this Mac).
/// The useful ones at a door: knocking (someone who didn't ring), dogs, breaking glass,
/// alarms, shouting.
public enum DoorSound: String, Codable, CaseIterable, Sendable {
    case knock = "Knocking"
    case dog = "Dog barking"
    case glass = "Glass breaking"
    case alarm = "Alarm"
    case shout = "Shouting"
    case vehicle = "Engine"

    /// Apple classifier labels that count as this sound.
    var labels: [String] {
        // Exact identifiers from SNClassifySoundRequest(.version1).knownClassifications.
        switch self {
        case .knock: return ["knock"]
        case .dog: return ["dog", "dog_bark", "dog_bow_wow", "dog_growl", "dog_howl"]
        case .glass: return ["glass_breaking"]
        case .alarm: return ["smoke_detector", "alarm_clock", "civil_defense_siren"]
        case .shout: return ["shout", "yell", "screaming"]
        case .vehicle: return ["engine", "engine_idling", "engine_starting", "car_passing_by", "truck", "motorcycle"]
        }
    }
}

public final class SoundIndex: ObservableObject, @unchecked Sendable {
    public static let shared = SoundIndex()
    private let lock = NSLock()
    private var store: [String: [DoorSound]] = [:]
    private let file: URL
    @Published public private(set) var version = 0

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = support.appendingPathComponent("Doorstep/sounds.json")
        if !DemoMode.isOn, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: [DoorSound]].self, from: data) {
            store = saved
        }
    }

    public func sounds(_ eventId: String) -> [DoorSound]? {
        lock.lock(); defer { lock.unlock() }
        return store[eventId]
    }

    func set(_ eventId: String, _ sounds: [DoorSound]) {
        lock.lock()
        store[eventId] = sounds
        let snapshot = store
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { if !DemoMode.isOn { try? data.write(to: file, options: .atomic) } }
        DispatchQueue.main.async { self.version += 1 }
    }

    /// Listen to a downloaded clip (local file).
    static func listen(to url: URL) -> [DoorSound] {
        guard let analyzer = try? SNAudioFileAnalyzer(url: url),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [] }
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48000)
        let observer = SoundObserver()
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return [] }
        analyzer.analyze()
        return DoorSound.allCases.filter { s in s.labels.contains { observer.heard[$0] ?? 0 >= 0.6 } }
    }
}

private final class SoundObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    var heard: [String: Double] = [:]
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        for c in r.classifications where c.confidence > 0.4 {
            heard[c.identifier] = max(heard[c.identifier] ?? 0, c.confidence)
        }
    }
}

// MARK: - Number plates

/// UK number plates read from clips and live video. Off by default: plates of passers-by
/// are personal data, so this is for your own driveway, kept only on this Mac.
public final class PlateIndex: ObservableObject, @unchecked Sendable {
    public static let shared = PlateIndex()

    public struct Sighting: Codable, Sendable, Hashable {
        public var plate: String
        public var camera: String
        public var date: Date
        public var eventId: String?
    }

    private let lock = NSLock()
    private var sightings: [Sighting] = []
    private var names: [String: String] = [:]   // plate -> "My car"
    private let file: URL
    private let namesFile: URL
    @Published public private(set) var version = 0

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "readPlates") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = support.appendingPathComponent("Doorstep/plates.json")
        namesFile = support.appendingPathComponent("Doorstep/plate-names.json")
        if !DemoMode.isOn, let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([Sighting].self, from: d) { sightings = s }
        if !DemoMode.isOn, let d = try? Data(contentsOf: namesFile), let n = try? JSONDecoder().decode([String: String].self, from: d) { names = n }
    }

    public var all: [Sighting] { lock.lock(); defer { lock.unlock() }; return sightings }
    public func name(_ plate: String) -> String? { lock.lock(); defer { lock.unlock() }; return names[plate] }

    public func setName(_ name: String?, for plate: String) {
        lock.lock()
        names[plate] = (name?.isEmpty ?? true) ? nil : name
        let n = names
        lock.unlock()
        if let d = try? JSONEncoder().encode(n) { if !DemoMode.isOn { try? d.write(to: namesFile, options: .atomic) } }
        DispatchQueue.main.async { self.version += 1 }
    }

    /// Records a sighting unless the same plate was seen on that camera in the last 10 minutes.
    /// Returns true when it's new (so the app can say "your car got home").
    @discardableResult
    func record(_ plate: String, camera: String, eventId: String?) -> Bool {
        lock.lock()
        let recent = sightings.contains { $0.plate == plate && $0.camera == camera && Date().timeIntervalSince($0.date) < 600 }
        if !recent {
            sightings.append(Sighting(plate: plate, camera: camera, date: Date(), eventId: eventId))
            sightings.removeAll { Date().timeIntervalSince($0.date) > 90 * 86400 }
        }
        let snapshot = sightings
        lock.unlock()
        guard !recent else { return false }
        if let d = try? JSONEncoder().encode(snapshot) { if !DemoMode.isOn { try? d.write(to: file, options: .atomic) } }
        DispatchQueue.main.async { self.version += 1 }
        return true
    }

    public func forgetAll() {
        lock.lock(); sightings = []; lock.unlock()
        try? FileManager.default.removeItem(at: file)
        DispatchQueue.main.async { self.version += 1 }
    }

    /// Current UK format (AB12 CDE) plus the prefix/suffix styles still on the road.
    static let patterns = [#"^[A-Z]{2}[0-9]{2}[A-Z]{3}$"#, #"^[A-Z][0-9]{1,3}[A-Z]{3}$"#, #"^[A-Z]{3}[0-9]{1,3}[A-Z]$"#]

    static func plates(in image: CGImage) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.minimumTextHeight = 0.012
        try? VNImageRequestHandler(cgImage: image).perform([req])
        var out: Set<String> = []
        for obs in req.results ?? [] {
            for cand in obs.topCandidates(3) where cand.confidence > 0.5 {
                let s = cand.string.uppercased().filter { $0.isLetter || $0.isNumber }
                // Common OCR swaps in the number part of a current-format plate.
                var fixed = Array(s)
                if fixed.count == 7 {
                    for i in 2...3 { if fixed[i] == "O" { fixed[i] = "0" }; if fixed[i] == "I" { fixed[i] = "1" } }
                }
                let plate = String(fixed)
                if patterns.contains(where: { plate.range(of: $0, options: .regularExpression) != nil }) { out.insert(plate) }
            }
        }
        return Array(out)
    }

    /// "AB12CDE" -> "AB12 CDE"
    public static func pretty(_ p: String) -> String {
        p.count == 7 && p.range(of: patterns[0], options: .regularExpression) != nil
            ? String(p.prefix(4)) + " " + String(p.suffix(3)) : p
    }
}
