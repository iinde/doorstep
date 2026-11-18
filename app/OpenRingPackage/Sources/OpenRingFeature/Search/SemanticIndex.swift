import AppKit
import Foundation
import ImageIO

/// Picture search: "red van", "man in a hat", "fox". Each visit's thumbnail is turned into a
/// MobileCLIP embedding on this Mac and kept in a small binary file; a typed phrase is embedded
/// the same way and visits are ranked by cosine similarity. Needs `SemanticModel` installed;
/// without it, indexing and search quietly do nothing.
///
/// In demo mode nothing is read from or written to disk: vectors live in memory and pictures
/// come from the demo artwork.
public actor SemanticIndex {
    public static let shared = SemanticIndex()

    /// Lowest cosine score worth showing. MobileCLIP text-to-picture scores are small: a clear
    /// match is usually 0.25 to 0.35, unrelated pictures 0.05 to 0.18.
    // Tuned on real Ring thumbnails: things in the picture ~0.18-0.24, things that are not ~0.12-0.16.
    public static let minimumScore: Float = 0.17
    /// Also drop anything this far behind the best match, so a strong hit isn't buried in maybes.
    public static let spread: Float = 0.08
    /// Pictures embedded per step before yielding.
    static let batchSize = 4

    public typealias ImageSource = @Sendable (String) async -> CGImage?

    private let modelFiles: SemanticModelFiles
    private let indexURL: URL?
    private let images: ImageSource
    private var encoder: SemanticEncoder?
    private var vectors: [String: [Float]] = [:]
    private var loaded = false
    private var inProgress: Set<String> = []
    private var unsaved = 0
    private var textCache: [String: [Float]] = [:]

    /// - Parameters:
    ///   - indexURL: where vectors are kept; nil keeps them in memory only (demo mode, tests).
    ///   - images: the picture for an event id, or nil if there isn't one yet.
    public init(modelFiles: SemanticModelFiles = .standard,
                indexURL: URL? = SemanticIndex.standardIndexURL,
                images: @escaping ImageSource = SemanticIndex.storedThumbnail) {
        self.modelFiles = modelFiles
        self.indexURL = DemoMode.isOn ? nil : indexURL
        self.images = images
    }

    /// Application Support/Doorstep/semantic-index.bin
    public static var standardIndexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Doorstep/semantic-index.bin")
    }

    /// How many visits have a picture embedding.
    public var count: Int {
        loadIfNeeded()
        return vectors.count
    }

    public func isIndexed(_ eventId: String) -> Bool {
        loadIfNeeded()
        return vectors[eventId] != nil
    }

    /// Embeds the thumbnails of any of these events not done yet, a few at a time, at background
    /// priority. Events with no thumbnail on disk yet are skipped and picked up on a later call.
    public func index(eventIds: [String]) async {
        loadIfNeeded()
        var seen: Set<String> = []
        let todo = eventIds.filter { vectors[$0] == nil && !inProgress.contains($0) && seen.insert($0).inserted }
        guard !todo.isEmpty, let encoder = loadEncoder() else { return }
        inProgress.formUnion(todo)
        defer { inProgress.subtract(todo) }

        var start = 0
        while start < todo.count, !Task.isCancelled {
            let batch = todo[start..<min(start + Self.batchSize, todo.count)]
            start += Self.batchSize
            for id in batch {
                guard let picture = await images(id) else { continue }
                let v = await Task.detached(priority: .background) { try? encoder.embed(image: picture) }.value
                // The model may have been removed or swapped while we waited.
                guard let v, self.encoder === encoder, v.count == encoder.dimensions else { continue }
                vectors[id] = v
                unsaved += 1
            }
            if unsaved >= 64 { save() }
            await Task.yield()
        }
        save()
    }

    /// Visits whose picture best matches the phrase, best first, above `minimumScore`.
    public func search(_ text: String, among eventIds: [String], limit: Int = 50) async -> [(eventId: String, score: Float)] {
        let phrase = CLIPTokenizer.clean(text).trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty, limit > 0 else { return [] }
        loadIfNeeded()
        guard let query = await textVector(phrase) else { return [] }
        var scored: [(eventId: String, score: Float)] = []
        for id in Set(eventIds) {
            guard let v = vectors[id], v.count == query.count else { continue }
            let s = VectorMath.dot(query, v)
            if s >= Self.minimumScore { scored.append((id, s)) }
        }
        guard let best = scored.map(\.score).max() else { return [] }
        return Array(scored.filter { $0.score >= best - Self.spread }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.eventId < $1.eventId }
            .prefix(limit))
    }

    /// Every score, best first, with no cut-off (for tuning).
    func searchRaw(_ text: String, among eventIds: [String], limit: Int) async -> [(eventId: String, score: Float)] {
        let phrase = CLIPTokenizer.clean(text).trimmingCharacters(in: .whitespaces)
        loadIfNeeded()
        guard let query = await textVector(phrase) else { return [] }
        return Set(eventIds).compactMap { id in vectors[id].map { (id, VectorMath.dot(query, $0)) } }
            .sorted { $0.1 > $1.1 }.prefix(limit).map { (eventId: $0.0, score: $0.1) }
    }

    /// Drop events (deleted visits). Saved straight away.
    public func forget(_ eventIds: [String]) {
        loadIfNeeded()
        for id in eventIds { vectors[id] = nil }
        unsaved += 1
        save()
    }

    /// Clears every vector and deletes the index file.
    public func removeAll() {
        vectors = [:]
        loaded = true
        unsaved = 0
        if let indexURL { try? FileManager.default.removeItem(at: indexURL) }
    }

    /// Lets go of the loaded model (it was removed or replaced).
    public func unloadModel() {
        encoder = nil
        textCache = [:]
    }

    // MARK: - Internals

    /// The phrase on its own and as "a photo of ...", averaged: CLIP models match pictures
    /// better with the caption-style form, and the average keeps short words like "fox" sharp.
    private func textVector(_ phrase: String) async -> [Float]? {
        if let v = textCache[phrase] { return v }
        guard let encoder = loadEncoder() else { return nil }
        let prompts = phrase.hasPrefix("a photo of") ? [phrase] : [phrase, "a photo of \(Self.article(phrase))\(phrase)"]
        let v: [Float]? = await Task.detached(priority: .userInitiated) {
            var sum: [Float]?
            for p in prompts {
                guard let e = try? encoder.embed(text: p) else { return nil }
                sum = sum.map { zip($0, e).map { $0 + $1 } } ?? e
            }
            return sum.map(VectorMath.normalised)
        }.value
        guard let v, self.encoder === encoder else { return nil }
        if textCache.count > 64 { textCache.removeAll() }
        textCache[phrase] = v
        return v
    }

    /// "a " before a bare noun phrase ("red van" -> "a red van"); nothing for plurals or "the ...".
    static func article(_ phrase: String) -> String {
        let first = phrase.split(separator: " ").first.map(String.init) ?? ""
        let skip: Set<String> = ["a", "an", "the", "some", "two", "three", "people", "someone", "somebody"]
        if skip.contains(first) || (phrase.hasSuffix("s") && !phrase.hasSuffix("ss")) { return "" }
        return "aeiou".contains(first.first ?? "x") ? "an " : "a "
    }

    private func loadEncoder() -> SemanticEncoder? {
        if let encoder { return encoder }
        guard modelFiles.isInstalled else { return nil }
        do {
            encoder = try SemanticEncoder(files: modelFiles)
        } catch {
            NSLog("🔎 picture search model failed to load: \(error.localizedDescription)")
        }
        return encoder
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let indexURL, let data = try? Data(contentsOf: indexURL) else { return }
        do {
            let c = try SemanticIndexFile.decode(data)
            if c.model == SemanticModelFiles.modelName { vectors = c.vectors }
        } catch {
            NSLog("🔎 picture index unreadable, starting again: \(error)")
        }
    }

    private func save() {
        guard unsaved > 0 else { return }
        unsaved = 0
        guard let indexURL else { return }
        let dims = vectors.first?.value.count ?? encoder?.dimensions ?? 512
        let data = SemanticIndexFile.encode(.init(model: SemanticModelFiles.modelName, dimensions: dims, vectors: vectors))
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    /// The thumbnail Doorstep already saved for this event (Caches/Doorstep/thumbs/<id>.jpg).
    /// Never fetches anything. In demo mode, the demo artwork instead.
    public static let storedThumbnail: ImageSource = { eventId in
        if DemoMode.isOn {
            return await MainActor.run {
                DemoData.picture(for: eventId).cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        }
        guard !eventId.isEmpty, !eventId.contains("/"), !eventId.contains("..") else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let file = caches.appendingPathComponent("Doorstep/thumbs/\(eventId).jpg")
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 768,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
