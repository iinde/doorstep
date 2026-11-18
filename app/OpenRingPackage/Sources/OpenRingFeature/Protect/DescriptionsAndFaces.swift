import Foundation
import AppKit
import Vision
import AVFoundation
import RingClient

// MARK: - Video descriptions

/// One plain sentence about what happened in a clip, from everything this Mac worked out:
/// who, which way they were going, what was heard, parcels, faces you've named.
public enum VideoDescription {
    public static func text(for event: RingEvent, tags: [String] = []) -> String {
        let id = IdentityIndex.shared.identity(event.id)
        let sounds = SoundIndex.shared.sounds(event.id) ?? []
        let face = FaceIndex.shared.names(for: event.id).first
        let place = placeName(event.deviceName)
        let rang = event.kind == .ding

        // Who.
        var subject: String
        if let face { subject = face }
        else if let c = id?.carrier, (id?.confidence ?? 0) >= 0.6 { subject = c.isGrocery ? "A \(c.rawValue) delivery driver" : "A \(c.rawValue) courier" }
        else if id?.isDelivery == true { subject = "A delivery driver" }
        else if MomentTier.of(event) >= .people || rang { subject = "Someone" }
        else if tags.contains("Vehicle") { return "A vehicle moved \(place)." }
        else if tags.contains("Animal") || sounds.contains(.dog) { return "An animal was seen \(place)." }
        else { return "Movement \(place). Nobody was seen." }

        // What they did.
        var acts: [String] = []
        let cam = (event.deviceName ?? "camera").lowercased()
        let doorish = cam.contains("door")
        switch id?.movement {
        case "approaching": acts.append(doorish ? "walked up to the \(cam)" : "came into the \(cam)")
        case "leaving": acts.append(doorish ? "walked away from the \(cam)" : "left the \(cam)")
        default: acts.append("was \(place)")
        }
        if rang { acts.append("rang the doorbell") }
        if sounds.contains(.knock) && !rang { acts.append("knocked") }
        if id?.parcelLeft == true { acts.append("left a parcel") }
        if id?.parcelTaken == true { acts.append("took a parcel from the step") }
        var sentence = subject + " " + join(acts) + "."
        // What else was heard.
        let heard = sounds.filter { $0 != .knock && $0 != .vehicle }.map { $0.rawValue.lowercased() }
        if !heard.isEmpty { sentence += " " + join(heard).prefix(1).uppercased() + join(heard).dropFirst() + " could be heard." }
        if let said = TranscriptIndex.shared.text(event.id), said.count < 140 { sentence += " They said: \u{201C}\(said)\u{201D}" }
        if let note = id?.note, id?.source == .claude || id?.source == .localAI { sentence += " " + note.trimmingCharacters(in: .whitespaces) + (note.hasSuffix(".") ? "" : ".") }
        return sentence
    }

    static func placeName(_ camera: String?) -> String {
        guard let c = camera?.lowercased() else { return "outside" }
        if c.contains("door") { return "at the \(c)" }
        if c.contains("garden") || c.contains("drive") || c.contains("gate") || c.contains("garage") { return "in the \(c)" }
        return "at \(camera!)"
    }

    static func join(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }
}

// MARK: - Familiar faces (beta, off by default)

/// Faces you've named ("Mum", "Josh"), recognised in later clips on this Mac. Only people you
/// name are ever matched; faces you haven't named are not kept.
public final class FaceIndex: ObservableObject, @unchecked Sendable {
    public static let shared = FaceIndex()

    public struct Person: Codable, Identifiable, Sendable {
        public var id = UUID()
        public var name: String
        var prints: [Data]
        var notPrints: [Data] = []
        public var thumbnail: Data?
    }

    private let lock = NSLock()
    private var people: [Person] = []
    private var matches: [String: [String]] = [:]   // event id -> names
    private let file: URL
    @Published public private(set) var version = 0

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "familiarFaces") }
    /// Feature-print distance under which two faces count as the same person. Conservative:
    /// a missed match is better than telling you your neighbour is your mum.
    static let threshold: Float = 0.42

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = support.appendingPathComponent("Doorstep/faces.json")
        if !DemoMode.isOn, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Person].self, from: data) { people = saved }
    }

    public var all: [Person] { lock.lock(); defer { lock.unlock() }; return people }

    public func names(for eventId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return matches[eventId] ?? []
    }

    public func setDemo(_ eventId: String, _ name: String) {
        lock.lock(); matches[eventId] = [name]; lock.unlock()
    }

    private func save() {
        lock.lock(); let snapshot = people; lock.unlock()
        if !DemoMode.isOn, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        DispatchQueue.main.async { self.version += 1 }
    }

    /// "This is Mum": adds the face to that person (creating them if new).
    public func name(_ face: DetectedFace, as name: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: face.print, requiringSecureCoding: true) else { return }
        lock.lock()
        if let i = people.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            people[i].prints = Array((people[i].prints + [data]).suffix(30))
        } else {
            people.append(Person(name: name, prints: [data], thumbnail: face.jpeg))
        }
        lock.unlock()
        save()
    }

    /// "That's not Mum": stops this face matching them again.
    public func notThem(_ face: DetectedFace, name: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: face.print, requiringSecureCoding: true) else { return }
        lock.lock()
        if let i = people.firstIndex(where: { $0.name == name }) { people[i].notPrints.append(data) }
        lock.unlock()
        save()
    }

    public func forget(_ person: Person) {
        lock.lock(); people.removeAll { $0.id == person.id }; lock.unlock()
        save()
    }

    public func forgetAll() {
        lock.lock(); people = []; matches = [:]; lock.unlock()
        try? FileManager.default.removeItem(at: file)
        save()
    }

    /// Who, of the people you've named, is in these frames.
    func recognise(eventId: String, frames: [CGImage]) {
        guard Self.isEnabled, !all.isEmpty else { return }
        let faces = frames.flatMap { FaceIndex.faces(in: $0) }
        var found: Set<String> = []
        let known = all
        for face in faces {
            var best: (String, Float)?
            for p in known {
                let d = p.prints.compactMap(Self.decode).map { Self.distance(face.print, $0) }.min() ?? .infinity
                let not = p.notPrints.compactMap(Self.decode).map { Self.distance(face.print, $0) }.min() ?? .infinity
                if d < Self.threshold, d < not, d < (best?.1 ?? .infinity) { best = (p.name, d) }
            }
            if let best { found.insert(best.0) }
        }
        guard !found.isEmpty else { return }
        lock.lock(); matches[eventId] = Array(found).sorted(); lock.unlock()
        DispatchQueue.main.async { self.version += 1 }
        NSLog("🙂 Familiar: \(found.sorted())")
    }

    static func decode(_ d: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: d)
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var d: Float = .infinity
        try? a.computeDistance(&d, to: b)
        return d
    }

    /// Faces large enough to recognise, with a feature print and a small picture.
    public static func faces(in image: CGImage) -> [DetectedFace] {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).filter { $0.confidence > 0.7 }.compactMap { obs in
            let b = obs.boundingBox
            let pad = b.insetBy(dx: -b.width * 0.3, dy: -b.height * 0.3).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let px = CGRect(x: pad.minX * CGFloat(image.width), y: (1 - pad.maxY) * CGFloat(image.height),
                            width: pad.width * CGFloat(image.width), height: pad.height * CGFloat(image.height)).integral
            guard px.width >= 48, px.height >= 48, let crop = image.cropping(to: px) else { return nil }
            let fp = VNGenerateImageFeaturePrintRequest()
            try? VNImageRequestHandler(cgImage: crop).perform([fp])
            guard let print = fp.results?.first else { return nil }
            let jpeg = NSBitmapImageRep(cgImage: crop).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            return DetectedFace(print: print, image: crop, jpeg: jpeg)
        }
    }
}

public struct DetectedFace: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let print: VNFeaturePrintObservation
    public let image: CGImage
    public let jpeg: Data?
}
