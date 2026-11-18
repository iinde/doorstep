import CoreML
import CryptoKit
import Foundation
import SwiftUI
import Vision

/// Where the MobileCLIP S0 files live once installed.
/// `<root>/mobileclip_s0/{mobileclip_s0_image.mlmodelc, mobileclip_s0_text.mlmodelc, clip-merges.txt}`
public struct SemanticModelFiles: Sendable {
    public static let modelName = "mobileclip_s0"
    public let root: URL

    public init(root: URL) { self.root = root }

    /// Application Support/Doorstep/models
    public static var standard: SemanticModelFiles {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return SemanticModelFiles(root: support.appendingPathComponent("Doorstep/models", isDirectory: true))
    }

    public var folder: URL { root.appendingPathComponent(Self.modelName, isDirectory: true) }
    public var imageModel: URL { folder.appendingPathComponent("mobileclip_s0_image.mlmodelc", isDirectory: true) }
    public var textModel: URL { folder.appendingPathComponent("mobileclip_s0_text.mlmodelc", isDirectory: true) }
    public var merges: URL { folder.appendingPathComponent("clip-merges.txt") }

    public var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: imageModel.path) && fm.fileExists(atPath: textModel.path)
            && fm.fileExists(atPath: merges.path)
    }

    /// Bytes on disk for the installed model, or 0.
    public var installedBytes: Int64 {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}

/// Downloads Apple's MobileCLIP S0 Core ML packages and the CLIP merges list from Hugging Face,
/// checks them (size, and SHA-256 for the large files), compiles them and installs them.
/// Talks only to huggingface.co (and the hf.co CDN it redirects to).
public struct SemanticModelInstaller: Sendable {
    public static let repo = "apple/coreml-mobileclip"
    public static let packages = ["mobileclip_s0_image.mlpackage", "mobileclip_s0_text.mlpackage"]
    /// OpenAI's merges, uncompressed (first 48,894 merges of bpe_simple_vocab_16e6.txt.gz).
    static let mergesURL = URL(string: "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/merges.txt")!
    static let mergesSize: Int64 = 524_657
    static let mergesSHA256 = "f526393189112391ce6f9795d4695f704121ce452c3aad1f5335cc41337eba85"
    /// What the download comes to (both S0 packages plus merges), checked 18 Nov 2026.
    public static let approximateDownloadBytes: Int64 = 108_326_416

    public enum InstallError: LocalizedError {
        case listing(String), badPath(String), http(Int, String), mismatch(String), notHuggingFace(String), badModel(String)
        public var errorDescription: String? {
            switch self {
            case .listing(let s): "Couldn't list the model files (\(s))."
            case .badPath(let p): "Unexpected file in the model: \(p)"
            case .http(let code, let f): "Download of \(f) failed (HTTP \(code))."
            case .mismatch(let f): "\(f) didn't match what Hugging Face said it should be."
            case .notHuggingFace(let h): "Refused a redirect to \(h)."
            case .badModel(let s): "The model isn't what Doorstep expects (\(s))."
            }
        }
    }

    public struct RemoteFile: Decodable, Sendable {
        public let type: String
        public let path: String
        public let size: Int64
        public let lfs: LFS?
        public struct LFS: Decodable, Sendable { public let oid: String; public let size: Int64 }
    }

    public let files: SemanticModelFiles
    public init(files: SemanticModelFiles = .standard) { self.files = files }

    /// Downloads, verifies, compiles and installs. `progress` gets (bytes so far, total bytes).
    public func install(progress: @escaping @Sendable (Int64, Int64) -> Void,
                        compiling: @escaping @Sendable () -> Void = {}) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: files.root, withIntermediateDirectories: true)
        let staging = files.root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var remote: [RemoteFile] = []
        for p in Self.packages { remote += try await list(package: p) }
        let total = remote.reduce(Int64(0)) { $0 + $1.size } + Self.mergesSize
        let counter = ByteCounter(total: total, report: progress)
        progress(0, total)

        for f in remote {
            let dest = staging.appendingPathComponent(f.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let src = URL(string: "https://huggingface.co/\(Self.repo)/resolve/main/")!
                .appendingPathComponent(f.path)
            try await Downloader.fetch(src, to: dest, counter: counter)
            try Self.verify(dest, size: f.size, sha256: f.lfs?.oid, name: f.path)
        }
        let mergesDest = staging.appendingPathComponent("clip-merges.txt")
        try await Downloader.fetch(Self.mergesURL, to: mergesDest, counter: counter)
        try Self.verify(mergesDest, size: Self.mergesSize, sha256: Self.mergesSHA256, name: "merges.txt")

        compiling()
        let ready = staging.appendingPathComponent(SemanticModelFiles.modelName, isDirectory: true)
        try fm.createDirectory(at: ready, withIntermediateDirectories: true)
        let built = SemanticModelFiles(root: staging)
        for (p, out) in zip(Self.packages, [built.imageModel, built.textModel]) {
            let compiled = try await MLModel.compileModel(at: staging.appendingPathComponent(p))
            try fm.moveItem(at: compiled, to: out)
            try? fm.removeItem(at: staging.appendingPathComponent(p))
        }
        try fm.moveItem(at: mergesDest, to: built.merges)
        // Load once so a broken model fails here, not on the first search.
        _ = try SemanticEncoder(files: built)

        try? files.remove()
        try fm.moveItem(at: ready, to: files.folder)
    }

    /// Every file in one .mlpackage, from the Hugging Face tree API.
    func list(package: String) async throws -> [RemoteFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(Self.repo)/tree/main/\(package)?recursive=true")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError.listing("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let all = try JSONDecoder().decode([RemoteFile].self, from: data).filter { $0.type == "file" }
        for f in all where !Self.isSafe(f.path, under: package) { throw InstallError.badPath(f.path) }
        guard all.contains(where: { $0.path == "\(package)/Manifest.json" }) else {
            throw InstallError.listing("no Manifest.json in \(package)")
        }
        return all
    }

    /// Only plain relative paths inside the package folder.
    static func isSafe(_ path: String, under package: String) -> Bool {
        guard path.hasPrefix(package + "/"), !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    static func verify(_ file: URL, size: Int64, sha256: String?, name: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attrs[.size] as? NSNumber)?.int64Value == size else { throw InstallError.mismatch(name) }
        if let sha256 {
            var hasher = SHA256()
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == sha256.lowercased() else { throw InstallError.mismatch(name) }
        }
    }
}

/// Running byte total across files.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0
    let total: Int64
    let report: @Sendable (Int64, Int64) -> Void
    init(total: Int64, report: @escaping @Sendable (Int64, Int64) -> Void) { self.total = total; self.report = report }
    func add(_ n: Int64) {
        lock.lock(); done += n; let d = done; lock.unlock()
        report(min(d, total), total)
    }
}

/// One file download with byte progress, cancellable, Hugging Face hosts only.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let counter: ByteCounter
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(destination: URL, counter: ByteCounter) {
        self.destination = destination
        self.counter = counter
    }

    static func fetch(_ url: URL, to destination: URL, counter: ByteCounter) async throws {
        let d = Downloader(destination: destination, counter: counter)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                d.lock.lock(); d.continuation = c; d.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func isHuggingFace(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host == "hf.co" || host.hasSuffix(".hf.co")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if Self.isHuggingFace(request.url) {
            completionHandler(request)
        } else {
            lock.lock(); failure = SemanticModelInstaller.InstallError.notHuggingFace(request.url?.host ?? "?"); lock.unlock()
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        counter.add(bytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard status == 200 else {
                throw SemanticModelInstaller.InstallError.http(status, destination.lastPathComponent)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.lock(); if failure == nil { failure = error }; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        let err = failure ?? error
        lock.unlock()
        if let err { c?.resume(throwing: err) } else { c?.resume() }
    }
}

/// The two loaded encoders plus the tokenizer. Core ML predictions are thread-safe.
public final class SemanticEncoder: @unchecked Sendable {
    public let dimensions: Int
    let image: MLModel
    let text: MLModel
    let tokenizer: CLIPTokenizer
    let imageInput: String
    let imageConstraint: MLImageConstraint
    let textInput: String
    let contextLength: Int
    let imageOutput: String
    let textOutput: String

    public init(files: SemanticModelFiles, computeUnits: MLComputeUnits = .all) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        image = try MLModel(contentsOf: files.imageModel, configuration: config)
        text = try MLModel(contentsOf: files.textModel, configuration: config)
        tokenizer = try CLIPTokenizer(mergesURL: files.merges)

        // Read the shapes from the models rather than assuming them (S0: 256×256 BGRA in, 1×77 Int32 in, 1×512 out).
        guard let (iName, iDesc) = image.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = iDesc.imageConstraint else { throw SemanticModelInstaller.InstallError.badModel("no image input") }
        guard let (tName, tDesc) = text.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .multiArray }),
              let tShape = tDesc.multiArrayConstraint?.shape.last?.intValue, tShape > 2 else {
            throw SemanticModelInstaller.InstallError.badModel("no token input")
        }
        guard let (ioName, ioDesc) = image.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }),
              let (toName, toDesc) = text.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }),
              let dI = ioDesc.multiArrayConstraint?.shape.last?.intValue,
              let dT = toDesc.multiArrayConstraint?.shape.last?.intValue, dI == dT, dI > 0 else {
            throw SemanticModelInstaller.InstallError.badModel("embedding sizes")
        }
        imageInput = iName; imageConstraint = constraint
        textInput = tName; contextLength = tShape
        imageOutput = ioName; textOutput = toName
        dimensions = dI
    }

    /// Unit-length embedding of a picture. The model takes 0 to 255 pixels and does its own
    /// scaling (MobileCLIP has no mean/std step); we only centre-crop and resize to its input.
    public func embed(image cg: CGImage) throws -> [Float] {
        let value = try MLFeatureValue(cgImage: cg, constraint: imageConstraint,
                                       options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue])
        let out = try image.prediction(from: MLDictionaryFeatureProvider(dictionary: [imageInput: value]))
        return try Self.vector(out, imageOutput)
    }

    /// Unit-length embedding of a phrase.
    public func embed(text phrase: String) throws -> [Float] {
        let ids = tokenizer.encode(phrase, contextLength: contextLength)
        let arr = try MLMultiArray(shape: [1, NSNumber(value: contextLength)], dataType: .int32)
        for (i, id) in ids.enumerated() { arr[i] = NSNumber(value: id) }
        let out = try text.prediction(from: MLDictionaryFeatureProvider(dictionary: [textInput: arr]))
        return try Self.vector(out, textOutput)
    }

    private static func vector(_ out: MLFeatureProvider, _ name: String) throws -> [Float] {
        guard let m = out.featureValue(for: name)?.multiArrayValue else {
            throw SemanticModelInstaller.InstallError.badModel("no output")
        }
        var v = [Float](repeating: 0, count: m.count)
        for i in 0..<m.count { v[i] = m[i].floatValue }
        return VectorMath.normalised(v)
    }
}

/// The app-wide switch for picture search: install state, download progress, removal.
@MainActor
public final class SemanticModel: ObservableObject {
    public static let shared = SemanticModel()

    public enum State: Equatable, Sendable {
        case notInstalled
        case downloading(Double)      // 0...1
        case compiling
        case ready
        case failed(String)
    }

    @Published public private(set) var state: State
    @Published public private(set) var installedBytes: Int64 = 0
    public let files: SemanticModelFiles
    private var job: Task<Void, Never>?

    public init(files: SemanticModelFiles = .standard) {
        self.files = files
        state = files.isInstalled ? .ready : .notInstalled
        if files.isInstalled { installedBytes = files.installedBytes }
    }

    public var isReady: Bool { state == .ready }
    public static var downloadBytes: Int64 { SemanticModelInstaller.approximateDownloadBytes }

    /// One-off download from Hugging Face. Only call from a button the user pressed.
    public func download() {
        guard job == nil, state != .ready else { return }
        state = .downloading(0)
        let installer = SemanticModelInstaller(files: files)
        job = Task { [weak self] in
            do {
                try await installer.install(progress: { done, total in
                    let fraction = total > 0 ? Double(done) / Double(total) : 0
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }, compiling: {
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .compiling
                    }
                })
                await SemanticIndex.shared.unloadModel()
                self?.state = .ready
                self?.installedBytes = self?.files.installedBytes ?? 0
            } catch is CancellationError {
                self?.state = .notInstalled
            } catch let e as URLError where e.code == .cancelled {
                self?.state = .notInstalled
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            self?.job = nil
        }
    }

    public func cancel() { job?.cancel() }

    /// Deletes the model. The picture index is kept (it's small and still valid if re-downloaded).
    public func remove() {
        job?.cancel()
        job = nil
        Task { await SemanticIndex.shared.unloadModel() }
        try? files.remove()
        installedBytes = 0
        state = .notInstalled
    }
}
