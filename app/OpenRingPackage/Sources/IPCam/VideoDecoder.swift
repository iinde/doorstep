import Foundation
import CoreMedia
import VideoToolbox

/// Hardware decoding of H.264 / H.265 frames into pixel buffers (BGRA, IOSurface-backed,
/// so they can go straight onto a layer and into Vision).
public final class VideoDecoder: @unchecked Sendable {
    public let codec: RTSPClient.Codec
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var vps: Data?, sps: Data?, pps: Data?
    private var waitingForKeyframe = true
    public var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    public private(set) var size: CGSize = .zero

    public init(codec: RTSPClient.Codec, parameterSets: [Data] = []) {
        self.codec = codec
        for p in parameterSets { note(p) }
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    private func type(_ nal: Data) -> Int {
        guard let b = nal.first else { return -1 }
        return codec == .h264 ? Int(b & 0x1F) : Int((b >> 1) & 0x3F)
    }

    /// Remembers parameter sets; returns true if it was one.
    @discardableResult
    private func note(_ nal: Data) -> Bool {
        let t = type(nal)
        switch (codec, t) {
        case (.h264, 7), (.h265, 33): if sps != nal { sps = nal; format = nil }; return true
        case (.h264, 8), (.h265, 34): if pps != nal { pps = nal; format = nil }; return true
        case (.h265, 32): if vps != nal { vps = nal; format = nil }; return true
        default: return false
        }
    }

    private func isKeyframe(_ nals: [Data]) -> Bool {
        nals.contains { let t = type($0); return codec == .h264 ? t == 5 : (16...21).contains(t) }
    }

    public func decode(_ nals: [Data], timestamp: UInt32) {
        var slices: [Data] = []
        for n in nals where !note(n) {
            let t = type(n)
            if codec == .h264, t == 6 || t == 9 { continue }      // SEI, delimiter
            if codec == .h265, t == 35 || t == 39 || t == 40 { continue }
            slices.append(n)
        }
        guard !slices.isEmpty else { return }
        if format == nil { makeSession() }
        guard let session, let format else { return }
        if waitingForKeyframe { guard isKeyframe(slices) else { return }; waitingForKeyframe = false }

        var avcc = Data()
        for s in slices {
            var len = UInt32(s.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(s)
        }
        var block: CMBlockBuffer?
        let count = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 90_000), decodeTimeStamp: .invalid)
        var sizes = [count]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr, let sample else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            self?.onFrame?(image)
        }
        if status == kVTInvalidSessionErr { self.session = nil; self.format = nil; waitingForKeyframe = true }
    }

    private func makeSession() {
        if let session { VTDecompressionSessionInvalidate(session); self.session = nil }
        guard let sps, let pps else { return }
        var desc: CMVideoFormatDescription?
        let sets = codec == .h265 ? [vps, sps, pps].compactMap { $0 } : [sps, pps]
        guard codec == .h264 || sets.count == 3 else { return }
        let ok: OSStatus = withPointers(sets) { ptrs, lens in
            if codec == .h264 {
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs,
                                                                          parameterSetSizes: lens, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs,
                                                                      parameterSetSizes: lens, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        }
        guard ok == noErr, let desc else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        size = CGSize(width: Int(dims.width), height: Int(dims.height))
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &s) == noErr else { return }
        session = s
        format = desc
        waitingForKeyframe = true
    }

    private func withPointers<R>(_ sets: [Data], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let copies = sets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) }, sets.map(\.count))
    }
}

/// RTSP + depacketizer + decoder, wired together: give it an address, get frames.
public final class IPStream: @unchecked Sendable {
    public let client: RTSPClient
    private var depacketizer: Depacketizer?
    private var decoder: VideoDecoder?
    private let lock = NSLock()
    public var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    public var onClose: (@Sendable (Error?) -> Void)?
    public private(set) var frames = 0

    public init?(url: URL, user: String? = nil, password: String? = nil) {
        guard let c = RTSPClient(url: url, user: user, password: password) else { return nil }
        client = c
    }

    public func start() async throws {
        client.onPacket = { [weak self] packet in self?.handle(packet) }
        client.onClose = { [weak self] e in self?.onClose?(e) }
        let track = try await client.start()
        if lock.withLock({ depacketizer == nil }) { prepare(track) }
    }

    private func prepare(_ track: RTSPClient.Track) {
        let d = VideoDecoder(codec: track.codec, parameterSets: track.parameterSets)
        d.onFrame = { [weak self] image in
            guard let self else { return }
            self.lock.withLock { self.frames += 1 }
            self.onFrame?(image)
        }
        lock.withLock {
            depacketizer = Depacketizer(codec: track.codec)
            decoder = d
        }
    }

    public func stop() { client.stop() }

    private func handle(_ packet: Data) {
        // Packets can arrive in the same read as the PLAY reply, before start() returns.
        if lock.withLock({ depacketizer == nil }), let track = client.track { prepare(track) }
        // Decode outside the lock: VideoToolbox may call back (and count the frame) synchronously.
        let (frame, decoder): ((nals: [Data], timestamp: UInt32)?, VideoDecoder?) = lock.withLock {
            guard depacketizer != nil else { return (nil, nil) }
            return (depacketizer!.push(packet), self.decoder)
        }
        if let frame { decoder?.decode(frame.nals, timestamp: frame.timestamp) }
    }
}
