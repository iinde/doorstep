import AppKit
import AVFoundation
import Vision
import RingClient

/// What this Mac's Vision pass found, readable from anywhere (Moment building runs
/// synchronously in views). Views observe it to refresh when new tags land.
public final class TagIndex: ObservableObject, @unchecked Sendable {
    public static let shared = TagIndex()
    private let lock = NSLock()
    private var people: Set<String> = []
    @Published public private(set) var version = 0

    /// Vision saw a person in this event's clip.
    public func sawPerson(_ eventId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return people.contains(eventId)
    }

    func record(_ eventId: String, tags: [String]) {
        lock.lock()
        let changed = tags.contains("Person") && people.insert(eventId).inserted
        lock.unlock()
        if changed { DispatchQueue.main.async { self.version += 1 } }
    }
}

/// Event thumbnails. Ring's snapshot_url comes back empty, so we read one frame ~1s
/// into the clip from its signed link and keep a small JPEG on disk. Four at a time.
public actor ThumbnailCache {
    public static let shared = ThumbnailCache()

    private let dir: URL
    private var memory: [String: NSImage] = [:]
    /// On-device tags per event ("Person", "Vehicle", "Animal", "Parcel"). Persisted.
    private var tagStore: [String: [String]] = [:]
    private var tagsFile: URL { dir.appendingPathComponent("tags.json") }
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 4

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = caches.appendingPathComponent("Doorstep/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !DemoMode.isOn, let data = try? Data(contentsOf: dir.appendingPathComponent("tags.json")),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            tagStore = saved
            for (id, tags) in saved { TagIndex.shared.record(id, tags: tags) }
        }
    }

    /// Tags found on this Mac for an event, if it has been looked at.
    public func tags(for eventId: String) -> [String]? { tagStore[eventId] }

    /// Tags that show up in most of a camera's clips are scenery (parked cars in view),
    /// not events. Needs 5+ tagged clips; anything in over 60% of them is scenery.
    public func scenery(among eventIds: [String]) -> Set<String> {
        let tagged = eventIds.compactMap { tagStore[$0] }
        guard tagged.count >= 5 else { return [] }
        var counts: [String: Int] = [:]
        for tags in tagged { for t in tags { counts[t, default: 0] += 1 } }
        return Set(counts.filter { Double($0.value) / Double(tagged.count) > 0.6 }.keys)
    }

    /// Tags for an event whose thumbnail predates tagging: read a few frames and check them.
    public func ensureTags(for eventId: String) async -> [String] {
        if DemoMode.isOn {
            let e = EventDirectory.shared.event(eventId)
            return e?.personDetected == true || e?.kind == .ding ? ["Person"] : []
        }
        let listen = UserDefaults.standard.object(forKey: "listenToClips") as? Bool ?? true
        if let t = tagStore[eventId], IdentityIndex.shared.has(eventId),
           !(listen && t.contains("Person") && SoundIndex.shared.sounds(eventId) == nil) { return t }
        await acquire()
        defer { release() }
        guard let link = try? await RingClient.shared.getEventVideoLink(eventId: eventId) else { return [] }
        return await tagFrames(eventId: eventId, link: link)
    }

    @discardableResult
    private func tagFrames(eventId: String, link: URL) async -> [String] {
        // Settings > Intelligence can switch this off.
        guard UserDefaults.standard.object(forKey: "onDeviceTagging") as? Bool ?? true else { return [] }
        let asset = AVURLAsset(url: link)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var frames: [CGImage] = []
        for t in [1.0, 3.0, 6.0] {
            if let (f, _) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) { frames.append(f) }
        }
        let found = Self.detect(in: frames)
        tagStore[eventId] = found
        TagIndex.shared.record(eventId, tags: found)
        if let data = try? JSONEncoder().encode(tagStore) { if !DemoMode.isOn { try? data.write(to: tagsFile, options: .atomic) } }

        let ev = EventDirectory.shared.event(eventId)
        // Number plates (opt-in): read from the same frames.
        if PlateIndex.isEnabled {
            for f in frames {
                for plate in PlateIndex.plates(in: f) {
                    if PlateIndex.shared.record(plate, camera: ev?.deviceName ?? "Camera", eventId: eventId) {
                        await PlateAnnouncer.announce(plate, camera: ev?.deviceName ?? "Camera")
                    }
                }
            }
        }
        // Hearing: knocks, dogs, glass, alarms. Needs the clip's audio, so only for people
        // and doorbell clips (one download each), and only if switched on.
        if (UserDefaults.standard.object(forKey: "listenToClips") as? Bool ?? true),
           SoundIndex.shared.sounds(eventId) == nil,
           found.contains("Person") || ev?.kind == .ding,
           let local = try? await RingClient.shared.getEventVideoURL(eventId: eventId) {
            let heard = SoundIndex.listen(to: local)
            SoundIndex.shared.set(eventId, heard)
            if !heard.isEmpty { NSLog("👂 \(ev?.deviceName ?? "?"): \(heard.map(\.rawValue))") }
        }

        // Who was it, and did a parcel arrive or go? Only worth it when someone's in shot.
        if found.contains("Person") || found.contains("Vehicle") || found.contains("Parcel") {
            var first: CGImage?, last: CGImage?
            let event = EventDirectory.shared.event(eventId)
            if EventDirectory.shared.isDoorbell(event?.deviceId) {
                first = try? await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
                if let dur = try? await asset.load(.duration), dur.seconds > 2 {
                    last = try? await generator.image(at: CMTime(seconds: dur.seconds - 0.7, preferredTimescale: 600)).image
                }
            }
            let identity = await Self.identify(frames: frames, first: first, last: last,
                                               camera: event?.deviceName ?? "Camera",
                                               allowCloud: found.contains("Person") && EventDirectory.shared.isDoorbell(event?.deviceId))
            IdentityIndex.shared.set(eventId, identity)
        } else if !IdentityIndex.shared.has(eventId) {
            IdentityIndex.shared.set(eventId, Identity(carrier: nil, isDelivery: false, confidence: 0, source: .text))
        }
        return found
    }

    /// Text first, then what you've taught it, then livery, then (if you switched it on) Claude.
    static func identify(frames: [CGImage], first: CGImage?, last: CGImage?, camera: String, allowCloud: Bool) async -> Identity {
        let people = IdentityAnalyzer.people(in: frames)
        let (left, taken) = IdentityAnalyzer.doorstepChange(first: first, last: last)
        var id = Identity(carrier: nil, isDelivery: false, confidence: 0, source: .text)
        if let c = IdentityAnalyzer.readCarrier(in: frames, people: people) {
            id = Identity(carrier: c, isDelivery: true, confidence: 0.9, source: .text)
        } else if let subject = IdentityAnalyzer.subject(frames: frames, people: people),
                  let print = IdentityAnalyzer.featurePrint(subject.0, in: subject.1),
                  let (label, conf) = await TeachStore.shared.match(print) {
            if label == TeachStore.notDelivery {
                id = Identity(carrier: nil, isDelivery: false, confidence: conf, source: .taught)
            } else {
                let c = Carrier(rawValue: label)
                id = Identity(carrier: c, isDelivery: true, confidence: conf, source: .taught)
            }
        } else if let (c, conf) = IdentityAnalyzer.livery(frames: frames, people: people,
                                                          vehicles: IdentityAnalyzer.vehicles(in: frames)) {
            id = Identity(carrier: c, isDelivery: true, confidence: conf, source: .livery)
        } else if allowCloud, let answer = await ClaudeCheck.ask(frames: frames, camera: camera) {
            id = answer
        }
        id.parcelLeft = left
        id.parcelTaken = taken
        if left { id.isDelivery = true }
        if let c = id.carrier { NSLog("🪪 \(camera): \(c.rawValue) via \(id.source.rawValue) (\(id.confidence))") }
        if left || taken { NSLog("📦 \(camera): parcel \(left ? "left" : "taken")") }
        return id
    }

    /// You said who it was. Stored for this clip, and remembered for next time.
    public func teach(eventId: String, label: String) async {
        let carrier = Carrier(rawValue: label)
        var id = IdentityIndex.shared.identity(eventId) ?? Identity(carrier: nil, isDelivery: false, confidence: 1, source: .you)
        id.carrier = carrier
        id.isDelivery = carrier != nil
        id.confidence = 1
        id.source = .you
        IdentityIndex.shared.set(eventId, id)
        guard let link = try? await RingClient.shared.getEventVideoLink(eventId: eventId) else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: link))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        var frames: [CGImage] = []
        for t in [1.0, 3.0, 6.0] {
            if let (f, _) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) { frames.append(f) }
        }
        let people = IdentityAnalyzer.people(in: frames)
        if let subject = IdentityAnalyzer.subject(frames: frames, people: people),
           let print = IdentityAnalyzer.featurePrint(subject.0, in: subject.1) {
            await TeachStore.shared.add(label: label, print: print)
        }
    }

    /// Tag the newest clips in the background so the Wall benefits without opening History.
    public func tagRecent(_ eventIds: [String]) async {
        for id in eventIds where tagStore[id] == nil || !IdentityIndex.shared.has(id) {
            _ = await ensureTags(for: id)
        }
    }

    /// Cached image only, no network.
    public func cached(_ eventId: String) -> NSImage? {
        if DemoMode.isOn { return nil }
        if let img = memory[eventId] { return img }
        let file = dir.appendingPathComponent("\(eventId).jpg")
        if let img = NSImage(contentsOf: file) {
            memory[eventId] = img
            return img
        }
        return nil
    }

    public func thumbnail(for eventId: String) async -> NSImage? {
        if DemoMode.isOn { return await MainActor.run { DemoData.picture(for: eventId) } }
        if let img = cached(eventId) { return img }
        if let task = inFlight[eventId] { return await task.value }
        let task = Task<NSImage?, Never> { await self.generate(eventId) }
        inFlight[eventId] = task
        let img = await task.value
        inFlight[eventId] = nil
        return img
    }

    private func acquire() async {
        if running < maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    private func release() {
        running -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// What's in these frames, most significant first. Uses only Apple's built-in models.
    nonisolated static func detect(in frames: [CGImage]) -> [String] {
        var person = false, animal = false, vehicle = false, parcel = false
        let vehicleWords = ["car", "vehicle", "truck", "van", "bus", "motorcycle", "bicycle", "suv"]
        let parcelWords = ["box", "package", "parcel", "cardboard", "carton"]
        for frame in frames {
            let handler = VNImageRequestHandler(cgImage: frame)
            let humans = VNDetectHumanRectanglesRequest()
            humans.upperBodyOnly = false
            let animals = VNRecognizeAnimalsRequest()
            let classify = VNClassifyImageRequest()
            try? handler.perform([humans, animals, classify])
            if let r = humans.results, r.contains(where: { $0.confidence > 0.6 }) { person = true }
            if let r = animals.results, r.contains(where: { $0.confidence > 0.6 }) { animal = true }
            for c in classify.results ?? [] where c.confidence > 0.35 {
                let id = c.identifier.lowercased()
                if vehicleWords.contains(where: { id.contains($0) }) { vehicle = true }
                if parcelWords.contains(where: { id.contains($0) }) { parcel = true }
            }
        }
        var tags: [String] = []
        if person { tags.append("Person") }
        if parcel { tags.append("Parcel") }
        if animal { tags.append("Animal") }
        if vehicle { tags.append("Vehicle") }
        return tags
    }

    private func generate(_ eventId: String) async -> NSImage? {
        await acquire()
        defer { release() }
        // Read one frame straight from Ring's signed link: AVFoundation fetches only
        // the byte ranges it needs instead of the whole clip.
        guard let link = try? await RingClient.shared.getEventVideoLink(eventId: eventId) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: link))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let (cg, _) = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else {
            return nil
        }
        // A few frames through the clip at higher resolution (people are small in a
        // fisheye view), checked on this Mac. Free and private.
        await tagFrames(eventId: eventId, link: link)

        let rep = NSBitmapImageRep(cgImage: cg)
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) {
            try? jpeg.write(to: dir.appendingPathComponent("\(eventId).jpg"))
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        memory[eventId] = image
        return image
    }
}

/// Which Moments you've looked at. Stored as a small JSON file; old entries pruned.
@MainActor
public final class ReviewStore: ObservableObject {
    public static let shared = ReviewStore()

    @Published public private(set) var reviewed: Set<String> = []
    private let file: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Doorstep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("reviewed.json")
        if !DemoMode.isOn, let data = try? Data(contentsOf: file),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            reviewed = Set(ids)
        }
    }

    public func isReviewed(_ m: Moment) -> Bool { reviewed.contains(m.id) }

    public func markReviewed(_ m: Moment) {
        guard !reviewed.contains(m.id) else { return }
        reviewed.insert(m.id)
        save()
    }

    public func markAllReviewed(_ moments: [Moment]) {
        reviewed.formUnion(moments.map(\.id))
        save()
    }

    private func save() {
        // Cap the file at 5,000 ids; plenty for 180 days of history.
        let ids = Array(reviewed.suffix(5000))
        if let data = try? JSONEncoder().encode(ids) { if !DemoMode.isOn { try? data.write(to: file, options: .atomic) } }
    }
}
