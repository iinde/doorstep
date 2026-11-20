import Foundation
import AVFoundation
import AppKit
import QuartzCore
import UserNotifications
import RingClient

// MARK: - Rain on a parcel

/// "It's raining and a parcel's been on your step since 14:02." Weather from Open-Meteo:
/// free, no key, no account. Only a rounded position (about 1 km) is sent.
public actor RainWatch {
    public static let shared = RainWatch()
    private var lastCheck = Date.distantPast
    private var warned: Set<String> = []

    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: "rainWarnings") as? Bool ?? true }

    public func check(moments: [Moment]) async {
        guard Self.isEnabled, Date().timeIntervalSince(lastCheck) > 600, let home = EventDirectory.shared.home else { return }
        // A parcel left in the last 4 hours, with nothing taking it since.
        let recent = moments.filter { $0.end > Date().addingTimeInterval(-4 * 3600) }
        guard let left = recent.filter(\.parcelLeft).max(by: { $0.end < $1.end }),
              !recent.contains(where: { $0.parcelTaken && $0.end > left.end }),
              !warned.contains(left.id) else { return }
        lastCheck = Date()
        let lat = (home.0 * 100).rounded() / 100, lon = (home.1 * 100).rounded() / 100
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=precipitation,rain,showers"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any] else { return }
        let wet = ["precipitation", "rain", "showers"].compactMap { current[$0] as? Double }.max() ?? 0
        guard wet >= 0.1 else { return }
        warned.insert(left.id)
        let content = UNMutableNotificationContent()
        content.title = "It's raining on your parcel"
        content.body = "A parcel has been at \(left.deviceName) since \(left.end.formatted(date: .omitted, time: .shortened))."
        if Busy.alertSound { content.sound = .default }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "rain-\(left.id)", content: content, trigger: nil))
        NSLog("🌧 Rain warning for parcel at \(left.deviceName)")
    }
}

// MARK: - Your day in 60 seconds

/// Stitches a few seconds of each visit into one short video with the time and what
/// happened written on each part. Uses Ring's clips, or this Mac's recordings.
public enum HighlightReel {
    public static func make(day: Date, moments: [Moment], progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let picks = moments.filter { $0.tier >= .people && Calendar.current.isDate($0.end, inSameDayAs: day) }
            .sorted { $0.start < $1.start }.suffix(20)
        guard !picks.isEmpty else { throw URLError(.fileDoesNotExist) }

        let size = CGSize(width: 1280, height: 720)
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw URLError(.cannotCreateFile)
        }
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var captions: [(String, CMTime, CMTime)] = []
        var cursor = CMTime.zero
        let piece = CMTime(seconds: 3, preferredTimescale: 600)

        for (i, m) in picks.enumerated() {
            progress("Clip \(i + 1) of \(picks.count)")
            let e = m.headline
            var url: URL? = try? await RingClient.shared.getEventVideoURL(eventId: e.id)
            if url == nil { url = await MainActor.run { LocalClipStore.shared.clip(deviceId: e.deviceId, around: e.createdAt)?.url } }
            guard let url else { continue }
            let asset = AVURLAsset(url: url)
            guard let src = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration),
                  let natural = try? await src.load(.naturalSize),
                  let transform = try? await src.load(.preferredTransform) else { continue }
            let start = CMTime(seconds: min(1, max(0, duration.seconds - 3)), preferredTimescale: 600)
            let length = CMTimeMinimum(piece, duration - start)
            guard length.seconds > 0.5, (try? track.insertTimeRange(CMTimeRange(start: start, duration: length), of: src, at: cursor)) != nil
            else { continue }

            // Fit the clip (square doorbell or wide camera) inside 1280x720.
            let oriented = natural.applying(transform)
            let w = abs(oriented.width), h = abs(oriented.height)
            let scale = min(size.width / w, size.height / h)
            let fit = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (size.width - w * scale) / 2, y: (size.height - h * scale) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(fit, at: cursor)
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = CMTimeRange(start: cursor, duration: length)
            ins.layerInstructions = [layer]
            instructions.append(ins)
            captions.append(("\(m.end.formatted(date: .omitted, time: .shortened))  \(m.title)", cursor, length))
            cursor = cursor + length
        }
        guard !instructions.isEmpty else { throw URLError(.fileDoesNotExist) }

        let video = AVMutableVideoComposition()
        video.renderSize = size
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = instructions

        // Captions: one text layer per clip, shown only during its part.
        let parent = CALayer(), videoLayer = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        for (text, at, length) in captions {
            let t = CALayer()
            let img = textImage(text, size: 30, weight: .semibold, colour: NSColor(srgbRed: 0.95, green: 0.94, blue: 0.91, alpha: 1))
            t.contents = img
            t.frame = CGRect(x: 40, y: 28, width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
            t.opacity = 0
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = AVCoreAnimationBeginTimeAtZero + at.seconds
            show.duration = length.seconds
            show.isRemovedOnCompletion = false
            t.add(show, forKey: "show")
            parent.addSublayer(t)
        }
        let markImage = textImage("Doorstep · \(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))", size: 20,
                                  weight: .medium, colour: NSColor(srgbRed: 0.96, green: 0.71, blue: 0.27, alpha: 1))
        let mark = CALayer()
        mark.contents = markImage
        mark.frame = CGRect(x: 40, y: size.height - 30 - CGFloat(markImage.height) / 2,
                            width: CGFloat(markImage.width) / 2, height: CGFloat(markImage.height) / 2)
        parent.addSublayer(mark)
        video.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        let out = await LocalClipStore.folder.appendingPathComponent(
            "\(day.formatted(.iso8601.year().month().day()))/Day in 60 seconds.mp4")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPreset1280x720) else {
            throw URLError(.cannotCreateFile)
        }
        export.videoComposition = video
        export.outputURL = out
        export.outputFileType = .mp4
        progress("Putting it together")
        await export.export()
        if export.status != .completed { throw export.error ?? URLError(.cannotWriteToFile) }
        return out
    }

    /// Text drawn into an image at 2x, with a soft shadow so it reads over any picture.
    /// (CATextLayer doesn't render reliably into exported video on macOS.)
    static func textImage(_ text: String, size: CGFloat, weight: NSFont.Weight, colour: NSColor) -> CGImage {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 2, weight: weight),
                                                    .foregroundColor: colour, .shadow: shadow]
        let str = NSAttributedString(string: text, attributes: attrs)
        let bounds = str.size()
        let w = Int(ceil(bounds.width)) + 24, h = Int(ceil(bounds.height)) + 24
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        str.draw(at: NSPoint(x: 12, y: 12))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
