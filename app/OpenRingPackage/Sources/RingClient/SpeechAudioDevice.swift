import Foundation
import AudioToolbox
@preconcurrency import WebRTC
import RTCAudioShim

/// A pretend microphone: WebRTC "records" whatever samples Doorstep hands it, so the Mac can
/// speak through a camera without ever opening the real microphone. 48 kHz, mono, 16-bit.
public final class SpeechAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    public static let shared = SpeechAudioDevice()
    public static let sampleRate = 48_000.0
    private static let chunk = 480   // 10 ms

    private let lock = NSLock()
    private var queue: [Int16] = []
    private var cursor = 0
    private var delegate: RTCAudioDeviceDelegate?
    private var recording = false
    private var recInit = false
    private var playing = false
    private var playInit = false
    private var pump: Thread?
    private var drained: [CheckedContinuation<Void, Never>] = []

    /// Queue speech and return when the last sample has gone out.
    /// If WebRTC isn't capturing (the call never came up), returns at once instead of waiting forever.
    public func play(_ samples: [Int16]) async {
        await withCheckedContinuation { c in
            lock.lock()
            guard recording else { lock.unlock(); c.resume(); return }
            if cursor > 0 { queue.removeFirst(cursor); cursor = 0 }
            queue += samples
            drained.append(c)
            lock.unlock()
        }
    }

    public var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return recording }

    // MARK: RTCAudioDevice

    public var deviceInputSampleRate: Double { Self.sampleRate }
    public var inputIOBufferDuration: TimeInterval { 0.01 }
    public var inputNumberOfChannels: Int { 1 }
    public var inputLatency: TimeInterval { 0 }
    public var deviceOutputSampleRate: Double { Self.sampleRate }
    public var outputIOBufferDuration: TimeInterval { 0.01 }
    public var outputNumberOfChannels: Int { 1 }
    public var outputLatency: TimeInterval { 0 }

    public var isInitialized: Bool { lock.lock(); defer { lock.unlock() }; return delegate != nil }
    public func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.lock(); self.delegate = delegate; lock.unlock()
        return true
    }
    public func terminateDevice() -> Bool {
        _ = stopRecording()
        lock.lock(); delegate = nil; lock.unlock()
        return true
    }

    // What the camera hears is discarded here: these sessions only speak.
    public var isPlayoutInitialized: Bool { lock.lock(); defer { lock.unlock() }; return playInit }
    public func initializePlayout() -> Bool { lock.lock(); playInit = true; lock.unlock(); return true }
    public var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return playing }
    public func startPlayout() -> Bool { lock.lock(); playing = true; lock.unlock(); return true }
    public func stopPlayout() -> Bool { lock.lock(); playing = false; playInit = false; lock.unlock(); return true }

    public var isRecordingInitialized: Bool { lock.lock(); defer { lock.unlock() }; return recInit }
    public func initializeRecording() -> Bool { lock.lock(); recInit = true; lock.unlock(); return true }
    public var isRecording: Bool { isCapturing }

    public func startRecording() -> Bool {
        lock.lock()
        guard !recording else { lock.unlock(); return true }
        recording = true
        let t = Thread { [weak self] in self?.run() }
        t.name = "doorstep.speech-audio"
        t.qualityOfService = .userInteractive
        pump = t
        lock.unlock()
        t.start()
        return true
    }

    public func stopRecording() -> Bool {
        lock.lock()
        recording = false
        recInit = false
        pump = nil
        let waiting = drained; drained = []
        queue = []; cursor = 0
        lock.unlock()
        waiting.forEach { $0.resume() }
        return true
    }

    /// Hand WebRTC 10 ms at a time, on the clock: speech when there is some, silence otherwise.
    private func run() {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        let tick = UInt64(10_000_000) * UInt64(info.denom) / UInt64(info.numer)
        var next = mach_absolute_time()
        var sampleTime = 0.0
        var buffer = [Int16](repeating: 0, count: Self.chunk)
        while true {
            lock.lock()
            guard recording, let delegate else { lock.unlock(); return }
            let available = min(Self.chunk, queue.count - cursor)
            for i in 0..<Self.chunk { buffer[i] = i < available ? queue[cursor + i] : 0 }
            cursor += max(0, available)
            var finished: [CheckedContinuation<Void, Never>] = []
            if cursor >= queue.count, !drained.isEmpty { finished = drained; drained = []; queue = []; cursor = 0 }
            lock.unlock()

            var flags = AudioUnitRenderActionFlags()
            var stamp = AudioTimeStamp()
            stamp.mSampleTime = sampleTime
            stamp.mHostTime = mach_absolute_time()
            stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
            buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                _ = delegate.deliverRecordedData(&flags, &stamp, 1, UInt32(Self.chunk), &list, nil, nil)
            }
            finished.forEach { $0.resume() }
            sampleTime += Double(Self.chunk)
            next += tick
            let now = mach_absolute_time()
            if next > now { mach_wait_until(next) } else { next = now }
        }
    }
}

extension SharedWebRTC {
    /// A second factory for "say it" sessions: same WebRTC, but its microphone is
    /// `SpeechAudioDevice`, so nothing on the Mac listens.
    nonisolated(unsafe) static let speechFactory: RTCPeerConnectionFactory = {
        _ = SharedWebRTC.factory   // SSL init
        return DSFactoryWithAudioDevice(SpeechAudioDevice.shared)
    }()
}
