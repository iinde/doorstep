import Foundation
import AppKit
import AVFoundation
import RingClient

/// Battery cameras can't stream all day, so take a still every few minutes instead and
/// turn the day into a time-lapse. Stored next to the recordings.
public actor Snapshotter {
    public static let shared = Snapshotter()
    private var last: [Int: Date] = [:]

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "snapshotsEnabled") }
    static var interval: TimeInterval { Double(UserDefaults.standard.object(forKey: "snapshotMinutes") as? Int ?? 5) * 60 }

    public static func folder(day: Date, camera: String) async -> URL {
        let d = day.formatted(.iso8601.year().month().day())
        return await LocalClipStore.folder.appendingPathComponent("Snapshots/\(d)/\(camera)", isDirectory: true)
    }

    /// Call on each refresh; takes a picture of each battery camera when it's due.
    public func tick(devices: [RingDevice]) async {
        guard Self.isEnabled else { return }
        for d in devices where d.isBatteryPowered && (d.deviceType == .camera || d.deviceType == .doorbell) {
            if let t = last[d.id], Date().timeIntervalSince(t) < Self.interval { continue }
            last[d.id] = Date()
            guard let data = try? await RingClient.shared.getSnapshot(deviceId: d.id), data.count > 1000 else { continue }
            let dir = await Self.folder(day: Date(), camera: d.name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: ":", with: "") + ".jpg"
            try? data.write(to: dir.appendingPathComponent(name))
        }
    }

    /// Stills for a day and camera, oldest first.
    public static func stills(day: Date, camera: String) async -> [URL] {
        let dir = await folder(day: day, camera: camera)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Turns a list of images into a short video (8 frames a second).
public enum TimeLapse {
    public static func make(from images: [URL], to out: URL, fps: Int32 = 8) async throws {
        guard let firstImage = images.first.flatMap({ NSImage(contentsOf: $0) }),
              let cg = firstImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw URLError(.cannotDecodeContentData) }
        let size = CGSize(width: cg.width - cg.width % 2, height: cg.height - cg.height % 2)
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for (i, url) in images.enumerated() {
            guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let pool = adaptor.pixelBufferPool else { continue }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            ctx?.draw(img, in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? URLError(.cannotWriteToFile) }
    }
}
