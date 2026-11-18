import AppKit
import Vision
import RingClient

/// Who (or what) a clip shows, beyond "a person".
public struct Identity: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case text      // carrier name read off a van/jacket/bag
        case livery    // colours only
        case taught    // matched against clips you labelled
        case you       // you said so
        case claude    // the optional cloud check
        case localAI   // Ollama on this Mac
    }

    public var carrier: Carrier?
    /// A delivery of some kind, even if we couldn't tell whose.
    public var isDelivery: Bool
    public var confidence: Double
    public var source: Source
    /// Doorstep zone: a box appeared / disappeared during the clip.
    public var parcelLeft = false
    public var parcelTaken = false
    /// Short description (Claude, or "you").
    public var note: String?
    /// "approaching" or "leaving", from whether the person grew or shrank through the clip.
    public var movement: String?
    /// Everyone in the clip was outside the camera's zone (pavement, road).
    public var outsideZone: Bool?

    /// What to call whoever it was, or nil when it's just "a person".
    public var who: String? {
        if let carrier, confidence >= 0.6 { return carrier.rawValue }
        if isDelivery { return "Delivery driver" }
        return nil
    }
}

/// Synchronous lookups for views and Moment titles; written by the analysis pipeline.
public final class IdentityIndex: ObservableObject, @unchecked Sendable {
    public static let shared = IdentityIndex()
    private let lock = NSLock()
    private var store: [String: Identity] = [:]
    private let file: URL
    @Published public private(set) var version = 0

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Doorstep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("identities.json")
        if !DemoMode.isOn, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Identity].self, from: data) {
            store = saved
        }
    }

    public func identity(_ eventId: String) -> Identity? {
        lock.lock(); defer { lock.unlock() }
        return store[eventId]
    }

    public func has(_ eventId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return store[eventId] != nil
    }

    func set(_ eventId: String, _ identity: Identity) {
        lock.lock()
        // What you said beats anything the machine works out later.
        if store[eventId]?.source == .you && identity.source != .you { lock.unlock(); return }
        store[eventId] = identity
        let snapshot = store
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { if !DemoMode.isOn { try? data.write(to: file, options: .atomic) } }
        DispatchQueue.main.async { self.version += 1 }
    }

    /// All events with an identity (for parcels matching and the daily brief).
    func all() -> [String: Identity] {
        lock.lock(); defer { lock.unlock() }
        return store
    }
}

/// Events the app knows about, by id, so the analysis pipeline (which only gets an id)
/// can tell which camera and kind a clip is.
public final class EventDirectory: @unchecked Sendable {
    public static let shared = EventDirectory()
    private let lock = NSLock()
    private var events: [String: RingEvent] = [:]
    private var doorbellIds: Set<Int> = []

    public func register(_ list: [RingEvent]) {
        lock.lock(); defer { lock.unlock() }
        for e in list { events[e.id] = e }
    }

    private var homeSpot: (Double, Double)?

    private var allDevices: [RingDevice] = []

    /// Cameras, for Siri and Shortcuts.
    public var devices: [RingDevice] {
        lock.lock(); defer { lock.unlock() }
        return allDevices
    }

    /// Everything registered so far (newest history the app has).
    public var allEvents: [RingEvent] {
        lock.lock(); defer { lock.unlock() }
        return Array(events.values)
    }

    public func registerDevices(_ devices: [RingDevice]) {
        lock.lock(); defer { lock.unlock() }
        allDevices = devices.filter { $0.deviceType != .chime }
        doorbellIds = Set(devices.filter { $0.deviceType == .doorbell }.map(\.id))
        if let d = devices.first(where: { ($0.latitude ?? 0) != 0 }), let lat = d.latitude, let lon = d.longitude {
            homeSpot = (lat, lon)
        }
    }

    /// The home's position from Ring, for sunrise/sunset and weather.
    public var home: (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        return homeSpot
    }

    public func event(_ id: String) -> RingEvent? {
        lock.lock(); defer { lock.unlock() }
        return events[id]
    }

    public func isDoorbell(_ deviceId: Int?) -> Bool {
        guard let deviceId else { return false }
        lock.lock(); defer { lock.unlock() }
        return doorbellIds.contains(deviceId)
    }
}

// MARK: - Analysis

/// Frames from one clip, already read.
struct ClipFrames {
    var middle: [CGImage]      // ~1s, 3s, 6s in
    var first: CGImage?        // just after it starts
    var last: CGImage?         // just before it ends
}

enum IdentityAnalyzer {
    /// Read carrier names off everything in shot.
    static func readCarrier(in frames: [CGImage], people: [[CGRect]]) -> Carrier? {
        var votes: [Carrier: Int] = [:]
        for (i, frame) in frames.enumerated() {
            var regions: [CGRect] = [CGRect(x: 0, y: 0, width: 1, height: 1)]
            // Also read inside each person, padded: jackets and bags carry the name
            // at a size the whole-frame pass misses on a fisheye.
            if i < people.count {
                for box in people[i] { regions.append(box.insetBy(dx: -box.width * 0.25, dy: -box.height * 0.1).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))) }
            }
            for roi in regions where roi.width > 0.02 && roi.height > 0.02 {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = false
                req.regionOfInterest = roi
                req.minimumTextHeight = 0.01
                try? VNImageRequestHandler(cgImage: frame).perform([req])
                for obs in req.results ?? [] {
                    for cand in obs.topCandidates(2) where cand.confidence >= 0.4 {
                        if let c = carrier(inText: cand.string) { votes[c, default: 0] += 1 }
                    }
                }
            }
        }
        return votes.max { $0.value < $1.value }?.key
    }

    /// Exact whole-word match against each carrier's painted words.
    static func carrier(inText raw: String) -> Carrier? {
        let cleaned = raw.uppercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        let text = " " + String(cleaned).split(separator: " ").joined(separator: " ") + " "
        for c in Carrier.allCases {
            for word in c.paintedWords where text.contains(" \(word) ") { return c }
        }
        return nil
    }

    /// Daylight frames only: infrared night frames are grey and say nothing about livery.
    static func isColour(_ image: CGImage) -> Bool {
        guard let stats = colourStats(image, in: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return false }
        return stats.meanSaturation > 0.08
    }

    struct ColourStats { var meanSaturation: Double; var yellow: Double; var red: Double }

    /// Share of strongly yellow and strongly red pixels inside a normalised (Vision) rect.
    static func colourStats(_ image: CGImage, in rect: CGRect) -> ColourStats? {
        let w = 64, h = 64
        let px = CGRect(x: rect.minX * CGFloat(image.width),
                        y: (1 - rect.maxY) * CGFloat(image.height),
                        width: rect.width * CGFloat(image.width),
                        height: rect.height * CGFloat(image.height)).integral
        guard let crop = image.cropping(to: px) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sat = 0.0, yellow = 0, red = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let c = NSColor(srgbRed: CGFloat(buf[i]) / 255, green: CGFloat(buf[i + 1]) / 255,
                            blue: CGFloat(buf[i + 2]) / 255, alpha: 1)
            var hue: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            c.getHue(&hue, saturation: &s, brightness: &b, alpha: nil)
            sat += Double(s)
            guard s > 0.5, b > 0.35 else { continue }
            let deg = hue * 360
            if deg >= 42 && deg <= 62 { yellow += 1 }
            if deg <= 12 || deg >= 348 { red += 1 }
        }
        let n = Double(w * h)
        return ColourStats(meanSaturation: sat / n, yellow: Double(yellow) / n, red: Double(red) / n)
    }

    /// DHL's yellow-with-red is distinctive; a mostly red van in the UK is nearly always
    /// Royal Mail. Weak evidence, so confidence stays near the line.
    static func livery(frames: [CGImage], people: [[CGRect]], vehicles: [[CGRect]]) -> (Carrier, Double)? {
        for (i, frame) in frames.enumerated() where isColour(frame) {
            for box in (i < vehicles.count ? vehicles[i] : []) where box.width * box.height > 0.04 {
                guard let s = colourStats(frame, in: box) else { continue }
                if s.yellow > 0.30 && s.red > 0.04 { return (.dhl, 0.62) }
                if s.red > 0.40 { return (.royalMail, 0.6) }
            }
            for box in (i < people.count ? people[i] : []) {
                // Upper body only: the top 55% of the person box.
                let torso = CGRect(x: box.minX, y: box.minY + box.height * 0.45, width: box.width, height: box.height * 0.55)
                guard let s = colourStats(frame, in: torso) else { continue }
                if s.yellow > 0.35 && s.red > 0.05 { return (.dhl, 0.6) }
            }
        }
        return nil
    }

    /// Person boxes per frame (Vision's normalised coordinates).
    static func people(in frames: [CGImage]) -> [[CGRect]] {
        frames.map { frame in
            let req = VNDetectHumanRectanglesRequest()
            req.upperBodyOnly = false
            try? VNImageRequestHandler(cgImage: frame).perform([req])
            return (req.results ?? []).filter { $0.confidence > 0.6 }.map(\.boundingBox)
        }
    }

    /// Vehicle boxes: Vision has no vehicle detector, so use salient objects in frames
    /// the classifier says contain a vehicle.
    static func vehicles(in frames: [CGImage]) -> [[CGRect]] {
        frames.map { frame in
            let classify = VNClassifyImageRequest()
            let salient = VNGenerateObjectnessBasedSaliencyImageRequest()
            try? VNImageRequestHandler(cgImage: frame).perform([classify, salient])
            let words = ["car", "vehicle", "truck", "van", "bus"]
            let hasVehicle = (classify.results ?? []).contains { c in
                c.confidence > 0.3 && words.contains { c.identifier.lowercased().contains($0) }
            }
            guard hasVehicle else { return [] }
            return (salient.results?.first?.salientObjects ?? []).map(\.boundingBox)
        }
    }

    // MARK: Doorstep zone

    /// Bottom third of the frame: where parcels get left at a doorbell.
    static let doorstep = CGRect(x: 0.1, y: 0, width: 0.8, height: 0.38)

    static func boxScore(_ image: CGImage) -> Double {
        let px = CGRect(x: doorstep.minX * CGFloat(image.width), y: (1 - doorstep.maxY) * CGFloat(image.height),
                        width: doorstep.width * CGFloat(image.width), height: doorstep.height * CGFloat(image.height)).integral
        guard let crop = image.cropping(to: px) else { return 0 }
        let req = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: crop).perform([req])
        let words = ["box", "package", "parcel", "cardboard", "carton", "envelope", "bag"]
        return Double((req.results ?? []).filter { c in words.contains { c.identifier.lowercased().contains($0) } }
            .map(\.confidence).max() ?? 0)
    }

    /// (left, taken) from the first and last frames of a doorbell clip.
    static func doorstepChange(first: CGImage?, last: CGImage?) -> (Bool, Bool) {
        guard let first, let last else { return (false, false) }
        let before = boxScore(first), after = boxScore(last)
        return (after > 0.3 && before < 0.12, before > 0.3 && after < 0.12)
    }

    // MARK: Taught examples

    static func featurePrint(_ image: CGImage, in rect: CGRect?) -> VNFeaturePrintObservation? {
        var img = image
        if let rect {
            let px = CGRect(x: rect.minX * CGFloat(image.width), y: (1 - rect.maxY) * CGFloat(image.height),
                            width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)).integral
            if let c = image.cropping(to: px) { img = c }
        }
        let req = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: img).perform([req])
        return req.results?.first
    }

    /// The largest person in the clip, padded, or the whole frame.
    static func subject(frames: [CGImage], people: [[CGRect]]) -> (CGImage, CGRect?)? {
        var best: (CGImage, CGRect, CGFloat)?
        for (i, f) in frames.enumerated() where i < people.count {
            for b in people[i] where b.width * b.height > (best?.2 ?? 0) {
                best = (f, b.insetBy(dx: -b.width * 0.15, dy: -b.height * 0.05).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)), b.width * b.height)
            }
        }
        if let best { return (best.0, best.1) }
        return frames.first.map { ($0, nil) }
    }
}

/// Clips you labelled ("that was Royal Mail"), kept as Vision feature prints so new clips
/// can be compared against them. Lives in Application Support; no images are kept.
public actor TeachStore {
    public static let shared = TeachStore()

    struct Example: Codable { var label: String; var print: Data }
    private var examples: [Example] = []
    private var decoded: [(String, VNFeaturePrintObservation)] = []
    private let file: URL

    /// "Not a delivery" is a label too, so the comparison has something to say no with.
    public static let notDelivery = "Not a delivery"

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = support.appendingPathComponent("Doorstep/taught.json")
        if !DemoMode.isOn, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Example].self, from: data) {
            examples = saved
            decoded = saved.compactMap { ex in
                guard let p = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: ex.print)
                else { return nil }
                return (ex.label, p)
            }
        }
    }

    public var count: Int { examples.count }

    func add(label: String, print: VNFeaturePrintObservation) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true) else { return }
        examples.append(Example(label: label, print: data))
        decoded.append((label, print))
        // Keep it small: the newest 40 per label.
        var kept: [Example] = []
        for label in Set(examples.map(\.label)) { kept += examples.filter { $0.label == label }.suffix(40) }
        examples = kept
        if let out = try? JSONEncoder().encode(examples) { if !DemoMode.isOn { try? out.write(to: file, options: .atomic) } }
    }

    public func clear() {
        examples = []; decoded = []
        try? FileManager.default.removeItem(at: file)
    }

    /// Nearest taught label, if it's clearly nearer than any other label (ratio test).
    func match(_ print: VNFeaturePrintObservation) -> (String, Double)? {
        var nearest: [String: Float] = [:]
        for (label, ex) in decoded {
            var d: Float = 0
            guard (try? print.computeDistance(&d, to: ex)) != nil else { continue }
            nearest[label] = min(nearest[label] ?? .infinity, d)
        }
        let ranked = nearest.sorted { $0.value < $1.value }
        guard ranked.count >= 2 else { return nil }
        let (label, d1) = ranked[0], d2 = ranked[1].value
        guard d1 < d2 * 0.8 else { return nil }
        return (label, Double(min(0.9, 0.6 + (1 - Double(d1 / d2)))))
    }
}
