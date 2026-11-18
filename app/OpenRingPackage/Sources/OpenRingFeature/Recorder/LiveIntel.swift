import Foundation
import CoreImage
import Vision
import AVFoundation
@preconcurrency import WebRTC

/// What's happening on each camera right now, worked out on this Mac from the live video.
/// Feeds the recorder (when to keep video), the radar, and the "approaching" warning.
@MainActor
public final class LiveIntel: ObservableObject {
    public static let shared = LiveIntel()

    public struct CameraNow: Equatable, Sendable {
        /// 0...1, how much of the picture changed in the last half second.
        public var motion: Double = 0
        /// People in shot, Vision coordinates (origin bottom-left, 0...1).
        public var people: [CGRect] = []
        public var lastPersonAt: Date?
        /// Someone is walking towards the camera (their box is growing).
        public var approaching = false
        /// How long someone has been in view without leaving, in seconds.
        public var lingering: Double = 0
        public var updated = Date.distantPast
    }

    @Published public private(set) var cameras: [Int: CameraNow] = [:]
    /// Called when someone starts approaching a camera.
    public var onApproach: ((Int) -> Void)?
    /// Called once when someone has hung around longer than the loitering time.
    public var onLoiter: ((Int, Int) -> Void)?

    public static var loiterSeconds: Double {
        Double(UserDefaults.standard.object(forKey: "loiterSeconds") as? Int ?? 40)
    }

    func update(_ id: Int, _ now: CameraNow) {
        let was = cameras[id]?.approaching ?? false
        let wasLingering = cameras[id]?.lingering ?? 0
        cameras[id] = now
        if now.approaching && !was { onApproach?(id) }
        let limit = Self.loiterSeconds
        if limit > 0, now.lingering >= limit, wasLingering < limit { onLoiter?(id, Int(now.lingering)) }
    }

    func clear(_ id: Int) { cameras[id] = nil }
}

/// Cheap per-frame checks: a tiny greyscale difference for motion, Vision for people only
/// when something moved. Runs off the main thread on its own queue.
final class FrameAnalyzer: @unchecked Sendable {
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var previous: [UInt8] = []
    private var heights: [(Date, CGFloat)] = []
    private var state = LiveIntel.CameraNow()
    private var lastPlateRead = Date.distantPast
    private var presentSince: Date?
    let deviceId: Int
    var cameraName: String { EventDirectory.shared.devices.first { $0.id == deviceId }?.name ?? "Camera" }

    init(deviceId: Int) { self.deviceId = deviceId }

    /// Returns the updated state. Call at most a few times a second.
    func analyse(_ buffer: CVPixelBuffer) -> LiveIntel.CameraNow {
        let now = Date()
        let image = CIImage(cvPixelBuffer: buffer)
        // 64x36 greyscale thumbnail.
        let w = 64, h = 36
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width,
                                                             y: CGFloat(h) / image.extent.height))
            .applyingFilter("CIPhotoEffectMono")
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        ci.render(scaled, toBitmap: &pixels, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var grey = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { grey[i] = pixels[i * 4] }
        var changed = 0
        if previous.count == grey.count {
            for i in 0..<grey.count where abs(Int(grey[i]) - Int(previous[i])) > 22 { changed += 1 }
        }
        previous = grey
        state.motion = Double(changed) / Double(grey.count)

        // People: only look when something moved, or someone was there a moment ago.
        let recentlySawSomeone = state.lastPersonAt.map { now.timeIntervalSince($0) < 4 } ?? false
        if state.motion > 0.01 || recentlySawSomeone {
            let req = VNDetectHumanRectanglesRequest()
            req.upperBodyOnly = false
            try? VNImageRequestHandler(cvPixelBuffer: buffer).perform([req])
            // Only people inside this camera's zone (if it has one) count.
            state.people = (req.results ?? []).filter { $0.confidence > 0.55 }.map(\.boundingBox)
                .filter { ZoneStore.contains($0, camera: deviceId) }
            if !state.people.isEmpty { state.lastPersonAt = now }
        } else {
            state.people = []
        }

        // Approaching: the biggest person's box has grown by a third over ~2 seconds.
        if let tallest = state.people.map(\.height).max() {
            heights.append((now, tallest))
        }
        heights.removeAll { now.timeIntervalSince($0.0) > 2.5 }
        if let first = heights.first, let last = heights.last, heights.count >= 3,
           last.0.timeIntervalSince(first.0) > 1.2 {
            state.approaching = last.1 > first.1 * 1.33 && last.1 > 0.2
        } else if state.people.isEmpty {
            state.approaching = false
        }
        // Number plates from live video (opt-in), every 2 seconds while something moves.
        if PlateIndex.isEnabled, state.motion > 0.01, now.timeIntervalSince(lastPlateRead) > 2,
           let cg = ci.createCGImage(image, from: image.extent) {
            lastPlateRead = now
            let camera = cameraName
            for plate in PlateIndex.plates(in: cg) where PlateIndex.shared.record(plate, camera: camera, eventId: nil) {
                Task { await PlateAnnouncer.announce(plate, camera: camera) }
            }
        }
        // Lingering: someone in view continuously (allowing 3 s gaps for missed detections).
        if !state.people.isEmpty {
            if presentSince == nil { presentSince = now }
        } else if let last = state.lastPersonAt, now.timeIntervalSince(last) > 3 {
            presentSince = nil
        }
        state.lingering = presentSince.map { now.timeIntervalSince($0) } ?? 0
        state.updated = now
        return state
    }
}

/// Live analysis for a camera that isn't being recorded (e.g. on screen in the command
/// centre): same checks, no video kept.
final class AnalyzerTap: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let analyzer: FrameAnalyzer
    private let queue: DispatchQueue
    private var busy = false
    private var last = Date.distantPast
    let deviceId: Int
    weak var track: RTCVideoTrack?

    init(deviceId: Int) {
        self.deviceId = deviceId
        analyzer = FrameAnalyzer(deviceId: deviceId)
        queue = DispatchQueue(label: "doorstep.tap.\(deviceId)", qos: .utility)
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let buffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return }
        queue.async {
            guard !self.busy, Date().timeIntervalSince(self.last) >= 0.5 else { return }
            self.busy = true
            self.last = Date()
            let state = self.analyzer.analyse(buffer)
            let id = self.deviceId
            DispatchQueue.main.async { LiveIntel.shared.update(id, state) }
            self.busy = false
        }
    }
}

/// Taps for cameras on screen. The recorder does its own analysis, so those are skipped.
@MainActor
public final class LiveAnalysis {
    public static let shared = LiveAnalysis()
    private var taps: [Int: AnalyzerTap] = [:]

    public func watch(_ deviceId: Int, track: RTCVideoTrack) {
        guard RecorderController.shared.recording[deviceId] == nil else { return }
        if let t = taps[deviceId], t.track === track { return }
        taps[deviceId]?.track?.remove(taps[deviceId]!)
        let tap = AnalyzerTap(deviceId: deviceId)
        tap.track = track
        track.add(tap)
        taps[deviceId] = tap
    }

    public func unwatchAll() {
        for (id, t) in taps {
            t.track?.remove(t)
            if RecorderController.shared.recording[id] == nil { LiveIntel.shared.clear(id) }
        }
        taps = [:]
    }
}
