import CoreGraphics
import Foundation
import Testing
@testable import OpenRingFeature

// Reference ids come from OpenAI's simple_tokenizer (the one open_clip and MobileCLIP use),
// run over bpe_simple_vocab_16e6.txt.gz. "a photo of a cat" is the well-known
// [49406, 320, 1125, 539, 320, 2368, 49407].

@Suite struct CLIPTokenizerTests {
    let tok = CLIPTokenizer(merges: clipMergesPrefix)

    @Test func knownPhrases() {
        #expect(tok.tokenIds("a photo of a cat") == [320, 1125, 539, 320, 2368])
        #expect(tok.tokenIds("red van") == [736, 2451])
        #expect(tok.tokenIds("Man in a HAT") == [786, 530, 320, 3801])
        #expect(tok.tokenIds("fox") == [3240])
    }

    @Test func whitespaceAndCaseDontMatter() {
        #expect(tok.tokenIds("  RED\n\tvan ") == tok.tokenIds("red van"))
    }

    @Test func vocabularyFromMerges() {
        // 256 byte symbols, the same with </w>, one per merge, two specials.
        #expect(tok.vocabularySize == 512 + 3300 + 2)
        #expect(tok.startToken == 512 + 3300)
        #expect(tok.endToken == 512 + 3300 + 1)
    }

    @Test func padsAndTruncates() {
        let ids = tok.encode("red van")
        #expect(ids.count == 77)
        #expect(Array(ids.prefix(4)) == [tok.startToken, 736, 2451, tok.endToken])
        #expect(ids.dropFirst(4).allSatisfy { $0 == 0 })

        let long = tok.encode(String(repeating: "cat ", count: 200))
        #expect(long.count == 77)
        #expect(long.first == tok.startToken)
        #expect(long.last == tok.endToken)
        #expect(long.dropFirst().dropLast().allSatisfy { $0 == 2368 })
    }

    @Test func preTokenizerSplitsLikeCLIP() {
        #expect(CLIPTokenizer.preTokenize("driver's parcel, 2 boxes!") == ["driver", "'s", "parcel", ",", "2", "boxes", "!"])
        #expect(CLIPTokenizer.preTokenize("ab12") == ["ab", "1", "2"])
    }

    /// The full merges list, if it's on this Mac (installed model, or DOORSTEP_CLIP_DIR).
    static var fullMerges: URL? {
        var roots = [SemanticModelFiles.standard]
        if let d = ProcessInfo.processInfo.environment["DOORSTEP_CLIP_DIR"] {
            roots.insert(SemanticModelFiles(root: URL(fileURLWithPath: d)), at: 0)
        }
        return roots.map(\.merges).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test(.enabled(if: fullMerges != nil, "needs the downloaded merges list"))
    func fullVocabulary() throws {
        let full = try CLIPTokenizer(mergesURL: Self.fullMerges!)
        #expect(full.vocabularySize == 49408)
        #expect(Array(full.encode("a photo of a cat").prefix(7)) == [49406, 320, 1125, 539, 320, 2368, 49407])
        #expect(full.tokenIds("person with a pushchair") == [2533, 593, 320, 16028, 4269])
        #expect(full.tokenIds("DPD driver's parcel, 2 boxes!") == [67, 4675, 4383, 568, 30367, 267, 273, 8350, 256])
        #expect(full.tokenIds("café") == [15304])
    }
}

@Suite struct VectorMathTests {
    @Test func normalisesToUnitLength() {
        let v = VectorMath.normalised([3, 4])
        #expect(abs(v[0] - 0.6) < 1e-6 && abs(v[1] - 0.8) < 1e-6)
        #expect(VectorMath.normalised([0, 0]) == [0, 0])
    }

    @Test func cosine() {
        #expect(abs(VectorMath.cosine([1, 0], [5, 0]) - 1) < 1e-6)
        #expect(abs(VectorMath.cosine([1, 0], [0, 2])) < 1e-6)
        #expect(abs(VectorMath.cosine([1, 1], [-1, -1]) + 1) < 1e-6)
        #expect(abs(VectorMath.cosine([1, 2, 3], [2, 4, 6]) - 1) < 1e-6)
        #expect(VectorMath.cosine([0, 0], [1, 1]) == 0)
        // For unit vectors the dot product is the cosine.
        let a = VectorMath.normalised([1, 2, 3]), b = VectorMath.normalised([3, -1, 2])
        #expect(abs(VectorMath.dot(a, b) - VectorMath.cosine([1, 2, 3], [3, -1, 2])) < 1e-6)
    }
}

@Suite struct SemanticIndexFileTests {
    func sample(_ n: Int, dims: Int = 512) -> SemanticIndexFile.Contents {
        var vectors: [String: [Float]] = [:]
        for i in 0..<n {
            vectors["event-\(i)"] = VectorMath.normalised((0..<dims).map { Float(sin(Double($0 * (i + 1)))) })
        }
        vectors["7312345678901234567"] = [Float](repeating: -0.25, count: dims)
        return .init(model: "mobileclip_s0", dimensions: dims, vectors: vectors)
    }

    @Test func roundTrip() throws {
        let c = sample(20)
        let data = SemanticIndexFile.encode(c)
        #expect(try SemanticIndexFile.decode(data) == c)
        // Header + per entry (2 + id + 512 * 4): compact, about 2 KB a visit.
        #expect(data.count < 21 * (2 + 20 + 2048) + 64)
    }

    @Test func emptyRoundTrip() throws {
        let c = SemanticIndexFile.Contents(model: "m", dimensions: 4, vectors: [:])
        #expect(try SemanticIndexFile.decode(SemanticIndexFile.encode(c)) == c)
    }

    @Test func dropsWrongLengthVectors() throws {
        var c = sample(2, dims: 8)
        c.vectors["short"] = [1, 2]
        let back = try SemanticIndexFile.decode(SemanticIndexFile.encode(c))
        #expect(back.vectors["short"] == nil)
        #expect(back.vectors.count == 3)
    }

    @Test func rejectsBadData() {
        let data = SemanticIndexFile.encode(sample(3))
        #expect(throws: SemanticIndexFile.ReadError.truncated) { try SemanticIndexFile.decode(data.prefix(data.count - 1)) }
        #expect(throws: SemanticIndexFile.ReadError.notAnIndex) { try SemanticIndexFile.decode(Data("nope, not this".utf8)) }
        var wrongVersion = data
        wrongVersion[4] = 99
        #expect(throws: SemanticIndexFile.ReadError.unsupportedVersion) { try SemanticIndexFile.decode(wrongVersion) }
    }

    @Test func installerOnlyAcceptsPlainPathsInsideThePackage() {
        let p = "mobileclip_s0_image.mlpackage"
        #expect(SemanticModelInstaller.isSafe("\(p)/Manifest.json", under: p))
        #expect(SemanticModelInstaller.isSafe("\(p)/Data/com.apple.CoreML/weights/weight.bin", under: p))
        #expect(!SemanticModelInstaller.isSafe("\(p)/../evil", under: p))
        #expect(!SemanticModelInstaller.isSafe("\(p)//x", under: p))
        #expect(!SemanticModelInstaller.isSafe("other/Manifest.json", under: p))
        #expect(!SemanticModelInstaller.isSafe("/\(p)/x", under: p))
    }

    @Test func redirectsOnlyToHuggingFace() {
        #expect(Downloader.isHuggingFace(URL(string: "https://huggingface.co/x")))
        #expect(Downloader.isHuggingFace(URL(string: "https://us.aws.cdn.hf.co/xet-bridge-us/abc")))
        #expect(!Downloader.isHuggingFace(URL(string: "http://huggingface.co/x")))
        #expect(!Downloader.isHuggingFace(URL(string: "https://huggingface.co.evil.com/x")))
        #expect(!Downloader.isHuggingFace(URL(string: "https://nothf.co/x")))
    }

    @Test func articles() {
        #expect(SemanticIndex.article("red van") == "a ")
        #expect(SemanticIndex.article("old man") == "an ")
        #expect(SemanticIndex.article("foxes") == "")
        #expect(SemanticIndex.article("the postman") == "")
        #expect(SemanticIndex.article("glass") == "a ")
    }
}

/// Downloads the real S0 model (about 108 MB from huggingface.co) into DOORSTEP_CLIP_E2E,
/// or reuses it if already there, then checks colours and the index end to end.
/// `DOORSTEP_CLIP_E2E=/tmp/clip swift test --filter SemanticEndToEnd`
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DOORSTEP_CLIP_E2E"] != nil))
struct SemanticEndToEnd {
    let files = SemanticModelFiles(root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOORSTEP_CLIP_E2E"] ?? "/nonexistent"))

    static func square(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: Int = 320) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    func installIfNeeded() async throws {
        guard !files.isInstalled else { return }
        let start = Date()
        try await SemanticModelInstaller(files: files).install(progress: { _, _ in })
        print("🔎 installed in \(Int(Date().timeIntervalSince(start)))s, \(files.installedBytes) bytes on disk")
    }

    @Test func redBeatsBlue() async throws {
        try await installIfNeeded()
        let enc = try SemanticEncoder(files: files)
        #expect(enc.dimensions == 512)
        let red = try enc.embed(image: Self.square(0.9, 0.05, 0.05))
        let blue = try enc.embed(image: Self.square(0.05, 0.1, 0.9))
        let tRed = try enc.embed(text: "a red image")
        let tBlue = try enc.embed(text: "a blue image")
        let s = [VectorMath.dot(tRed, red), VectorMath.dot(tRed, blue), VectorMath.dot(tBlue, red), VectorMath.dot(tBlue, blue)]
        print("🔎 'a red image': red \(s[0]) blue \(s[1]);  'a blue image': red \(s[2]) blue \(s[3])")
        #expect(s[0] > s[1])
        #expect(s[3] > s[2])
    }

    @Test func indexAndSearch() async throws {
        try await installIfNeeded()
        let pictures: [String: CGImage] = ["red": Self.square(0.9, 0.05, 0.05), "blue": Self.square(0.05, 0.1, 0.9),
                                           "green": Self.square(0.1, 0.8, 0.1)]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.bin")
        let index = SemanticIndex(modelFiles: files, indexURL: url, images: { pictures[$0] })
        await index.index(eventIds: ["red", "blue", "green", "missing"])
        #expect(await index.count == 3)
        let hits = await index.search("red", among: ["red", "blue", "green"], limit: 3)
        print("🔎 search 'red': \(hits)")
        #expect(hits.first?.eventId == "red")

        // A fresh index reads the same vectors back from disk.
        let again = SemanticIndex(modelFiles: files, indexURL: url, images: { _ in nil })
        #expect(await again.count == 3)
        #expect(await again.search("blue", among: ["red", "blue", "green"], limit: 3).first?.eventId == "blue")
    }
}
