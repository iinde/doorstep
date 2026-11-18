import Foundation
import AVFoundation
import AppKit
import RingClient
@preconcurrency import WebRTC

/// A clip this Mac recorded from a live stream (works without a Ring subscription).
public struct LocalClip: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var deviceId: Int
    public var deviceName: String
    public var start: Date
    public var end: Date
    public var file: String          // path
    public var reason: String        // "Person", "Motion", "Ring event"
    public var url: URL { URL(fileURLWithPath: file) }
}

/// Settings and the list of recordings.
@MainActor
public final class LocalClipStore: ObservableObject {
    public static let shared = LocalClipStore()
    @Published public private(set) var clips: [LocalClip] = []
    private let index: URL

    public static var folder: URL {
        if let path = UserDefaults.standard.string(forKey: "recordFolder"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Doorstep Recordings", isDirectory: true)
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        index = support.appendingPathComponent("Doorstep/recordings.json")
        if !DemoMode.isOn, let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([LocalClip].self, from: data) {
            clips = saved.filter { FileManager.default.fileExists(atPath: $0.file) }
        }
    }

    func add(_ clip: LocalClip) {
        clips.append(clip)
        clips.sort { $0.start > $1.start }
        save()
    }

    /// A recording on this camera that covers (or is within a minute of) this moment.
    public func clip(deviceId: Int?, around date: Date) -> LocalClip? {
        clips.first { c in
            (deviceId == nil || c.deviceId == deviceId)
                && c.start.addingTimeInterval(-60) <= date && c.end.addingTimeInterval(60) >= date
        }
    }

    public func clips(on day: Date) -> [LocalClip] {
        clips.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
    }

    /// Delete recordings older than the retention setting.
    public func prune() {
        let days = UserDefaults.standard.object(forKey: "recordKeepDays") as? Int ?? 14
        guard days > 0 else { return }   // 0 = keep until I delete them
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let old = clips.filter { $0.start < cutoff }
        for c in old { try? FileManager.default.removeItem(at: c.url) }
        if !old.isEmpty { clips.removeAll { $0.start < cutoff }; save() }
    }

    public var totalBytes: Int64 {
        clips.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.file)[.size] as? Int64) ?? 0) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(clips) { if !DemoMode.isOn { try? data.write(to: index, options: .atomic) } }
    }
}

/// Records one camera's live video into rolling 4-second segments, keeps the last few as
/// pre-roll, and when something happens stitches pre-roll + event + a short tail into a clip.
final class CameraRecorder: NSObject, RTCVideoRenderer, @unchecked Sendable {
    let device: RingDevice
    private let queue: DispatchQueue
    private let tmp: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var segmentStart: CMTime?
    private var segmentStartDate = Date()
    private var segmentSize: CGSize = .zero
    /// Finished segments: (file, start, end)
    private var segments: [(URL, Date, Date)] = []
    private var keepUntil: Date?
    private var keptReason = ""
    private var kept: [(URL, Date, Date)] = []
    private let analyzer: FrameAnalyzer
    private var lastAnalysis = Date.distantPast
    private(set) weak var track: RTCVideoTrack?
    static let segmentLength: TimeInterval = 4
    static let preRollSegments = 3

    init(device: RingDevice) {
        self.device = device
        queue = DispatchQueue(label: "doorstep.recorder.\(device.id)", qos: .utility)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("doorstep-rec-\(device.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        analyzer = FrameAnalyzer(deviceId: device.id)
    }

    func attach(_ track: RTCVideoTrack) {
        guard self.track !== track else { return }
        self.track?.remove(self)
        self.track = track
        track.add(self)
    }

    func detach() {
        track?.remove(self)
        track = nil
        queue.async { self.closeSegment(); }
    }

    /// Something happened (a Ring event, a person): keep video until `seconds` from now.
    func keep(for seconds: TimeInterval, reason: String) {
        queue.async {
            let until = Date().addingTimeInterval(seconds)
            if self.keepUntil == nil {
                self.keptReason = reason
                // Pre-roll: the last few finished segments.
                self.kept = Array(self.segments.suffix(Self.preRollSegments))
                NSLog("⏺ \(self.device.name): recording (\(reason))")
            } else if reason == "Person" {
                self.keptReason = reason
            }
            self.keepUntil = max(self.keepUntil ?? until, until)
        }
    }

    // MARK: RTCVideoRenderer

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let buffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return }
        let time = CMTime(value: frame.timeStampNs, timescale: 1_000_000_000)
        queue.async { self.append(buffer, at: time) }
    }

    private func append(_ buffer: CVPixelBuffer, at time: CMTime) {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if writer == nil || size != segmentSize
            || (segmentStart.map { (time - $0).seconds >= Self.segmentLength } ?? false) {
            closeSegment()
            openSegment(size: size, at: time)
        }
        if let input, input.isReadyForMoreMediaData, let adaptor {
            adaptor.append(buffer, withPresentationTime: time)
        }
        // Look at the picture twice a second.
        if Date().timeIntervalSince(lastAnalysis) >= 0.5 {
            lastAnalysis = Date()
            let state = analyzer.analyse(buffer)
            let id = device.id
            DispatchQueue.main.async { LiveIntel.shared.update(id, state) }
            let personTrigger = !state.people.isEmpty
            let motionTrigger = UserDefaults.standard.bool(forKey: "recordOnMotion") && state.motion > 0.04
            if personTrigger || motionTrigger {
                let until = Date().addingTimeInterval(10)
                if keepUntil == nil {
                    keptReason = personTrigger ? "Person" : "Motion"
                    kept = Array(segments.suffix(Self.preRollSegments))
                    NSLog("⏺ \(device.name): recording (\(keptReason))")
                } else if personTrigger { keptReason = "Person" }
                keepUntil = max(keepUntil ?? until, until)
            }
        }
    }

    private func openSegment(size: CGSize, at time: CMTime) {
        let url = tmp.appendingPathComponent("\(UUID().uuidString).mp4")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(size.width * size.height * 2.5),
                                              AVVideoExpectedSourceFrameRateKey: 15],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard w.canAdd(input) else { return }
        w.add(input)
        w.startWriting()
        w.startSession(atSourceTime: time)
        writer = w
        self.input = input
        self.adaptor = adaptor
        segmentStart = time
        segmentStartDate = Date()
        segmentSize = size
    }

    private func closeSegment() {
        guard let w = writer, let input else { return }
        let url = w.outputURL
        let start = segmentStartDate, end = Date()
        writer = nil; self.input = nil; adaptor = nil; segmentStart = nil
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        w.finishWriting { done.signal() }
        done.wait()
        guard w.status == .completed else { try? FileManager.default.removeItem(at: url); return }
        segments.append((url, start, end))

        // 24/7: keep everything, in 10-minute files.
        let continuous = (UserDefaults.standard.array(forKey: "continuousCameras") as? [Int] ?? []).contains(device.id)
        if continuous && keepUntil == nil {
            keepUntil = .distantFuture
            keptReason = "Continuous"
            kept = []
        } else if !continuous && keepUntil == .distantFuture {
            keepUntil = Date()   // switched off: finish what we have
        }

        if let until = keepUntil {
            kept.append((url, start, end))
            let span = (kept.last?.2 ?? end).timeIntervalSince(kept.first?.1 ?? start)
            if continuous && span >= 600 {
                let clip = kept
                kept = []
                finish(clip, reason: "Continuous")
            } else if Date() > until {
                let clip = kept
                let reason = keptReason
                keepUntil = nil
                kept = []
                finish(clip, reason: reason)
            }
        }
        // Drop old segments that nothing is keeping.
        let keptURLs = Set(kept.map(\.0))
        while segments.count > Self.preRollSegments + 1 {
            let old = segments.removeFirst()
            if !keptURLs.contains(old.0) { try? FileManager.default.removeItem(at: old.0) }
        }
    }

    /// Join the kept segments into one file in the recordings folder.
    private func finish(_ parts: [(URL, Date, Date)], reason: String) {
        guard let first = parts.first, let last = parts.last else { return }
        let device = self.device
        Task {
            let comp = AVMutableComposition()
            guard let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
            var cursor = CMTime.zero
            for (url, _, _) in parts {
                let asset = AVURLAsset(url: url)
                guard let src = try? await asset.loadTracks(withMediaType: .video).first,
                      let duration = try? await asset.load(.duration) else { continue }
                try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: src, at: cursor)
                cursor = cursor + duration
            }
            let day = first.1.formatted(.iso8601.year().month().day())
            let dir = await LocalClipStore.folder.appendingPathComponent(day, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let time = first.1.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .replacingOccurrences(of: ":", with: "-")
            let out = dir.appendingPathComponent("\(device.name) \(time).mp4")
            try? FileManager.default.removeItem(at: out)
            guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return }
            export.outputURL = out
            export.outputFileType = .mp4
            await export.export()
            for (url, _, _) in parts { try? FileManager.default.removeItem(at: url) }
            guard export.status == .completed else {
                NSLog("⏺ \(device.name): couldn't save clip (\(export.error?.localizedDescription ?? "?"))")
                return
            }
            let clip = LocalClip(id: UUID().uuidString, deviceId: device.id, deviceName: device.name,
                                 start: first.1, end: last.2, file: out.path, reason: reason)
            await MainActor.run { LocalClipStore.shared.add(clip) }
            NSLog("⏺ Saved \(out.lastPathComponent) (\(Int(last.2.timeIntervalSince(first.1)))s, \(reason))")
        }
    }
}

/// Keeps the chosen cameras streaming and recording while switched on.
@MainActor
public final class RecorderController: ObservableObject {
    public static let shared = RecorderController()
    @Published public private(set) var recording: [Int: String] = [:]   // device id -> name
    private var recorders: [Int: CameraRecorder] = [:]
    private var watcher: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "recorderEnabled") }

    /// Which cameras record: chosen in Settings; by default every camera that isn't on batteries.
    public static func chosen(from devices: [RingDevice]) -> [RingDevice] {
        let cams = devices.filter { $0.deviceType == .doorbell || $0.deviceType == .camera }
        if let byMode = Modes.shared.recordingCameras() { return cams.filter { byMode.contains($0.id) } }
        if let ids = UserDefaults.standard.array(forKey: "recordDevices") as? [Int] {
            return cams.filter { ids.contains($0.id) }
        }
        return cams.filter { !$0.isBatteryPowered }
    }

    public func sync(devices: [RingDevice]) async {
        guard Self.isEnabled else { await stop(); return }
        let wanted = Self.chosen(from: devices)
        if recorders.isEmpty {
            NSLog("⏺ Recorder: \(devices.map { "\($0.name) kind=\($0.kind) battery=\($0.batteryLevel.map(String.init) ?? "-") ext=\($0.externalConnection.map(String.init) ?? "-") sub=\($0.subscribed.map(String.init) ?? "-")" }) -> \(wanted.map(\.name))")
        }
        await MultiStreamManager.shared.pin(wanted)
        for d in wanted where recorders[d.id] == nil {
            recorders[d.id] = CameraRecorder(device: d)
            recording[d.id] = d.name
        }
        for (id, r) in recorders where !wanted.contains(where: { $0.id == id }) {
            r.detach(); recorders[id] = nil; recording[id] = nil
            LiveIntel.shared.clear(id)
        }
        // Keep the Mac awake while recording (it can still sleep its display).
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Doorstep is recording your cameras")
        }
        // Streams reconnect and swap tracks: re-attach every couple of seconds.
        if watcher == nil {
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    for (id, r) in self.recorders {
                        if let t = MultiStreamManager.shared.getVideoTrack(for: id) { r.attach(t) }
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        LocalClipStore.shared.prune()
        // Testing: `-DoorstepRecordTest YES` forces a short recording on each camera after 20s.
        if UserDefaults.standard.bool(forKey: "DoorstepRecordTest"), !testDone {
            testDone = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                for r in self?.recorders.values ?? [:].values { r.keep(for: 6, reason: "Test") }
            }
        }
    }
    private var testDone = false

    /// A Ring event on a recording camera: make sure that stretch is kept.
    public func ringEvent(_ event: RingEvent) {
        // Ring logs our own live views as events; those aren't something happening outside.
        guard MomentBuilder.isOutsideEvent(event), let id = event.deviceId, let r = recorders[id] else { return }
        r.keep(for: 20, reason: event.kind == .ding ? "Doorbell" : "Ring event")
    }

    public func stop() async {
        watcher?.cancel(); watcher = nil
        for r in recorders.values { r.detach() }
        recorders = [:]
        recording = [:]
        await MultiStreamManager.shared.pin([])
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
}
