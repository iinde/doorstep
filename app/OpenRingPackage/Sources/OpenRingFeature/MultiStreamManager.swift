import Foundation
import RingClient
@preconcurrency import WebRTC

/// Manages multiple simultaneous WebRTC streams for all cameras
@MainActor
public class MultiStreamManager: ObservableObject {

    public struct StreamInfo: Identifiable {
        public let id: Int  // Device ID
        public let deviceName: String
        public var session: LiveViewSession?
        public var videoTrack: RTCVideoTrack?
        public var audioTrack: RTCAudioTrack?
        public var state: LiveViewSession.State = .idle
        public var error: String?
    }

    @Published public var streams: [Int: StreamInfo] = [:]
    @Published public var isConnecting = false
    @Published public var activeDeviceId: Int?  // Currently active device (audio plays from this one)

    private var devices: [RingDevice] = []
    /// Bumped on every stop; a start that finishes after a stop throws its session away.
    private var generation = 0

    public init() {}

    /// One manager for the whole app: every surface (popover, windows) shares the
    /// same live sessions. Two managers meant two sessions per camera, which battery
    /// cameras can't serve reliably.
    public static let shared = MultiStreamManager()

    private var viewers = 0
    /// Cameras the recorder keeps streaming even when no window is showing them.
    public private(set) var pinned: Set<Int> = []

    /// Keep these cameras streaming (the recorder). Others stop when nobody's looking.
    public func pin(_ devices: [RingDevice]) async {
        let old = pinned
        pinned = Set(devices.map(\.id))
        if !devices.isEmpty { await startAllStreams(for: devices) }
        if viewers == 0 { await stopStreams(except: pinned) }
        _ = old
    }

    /// A view started showing streams. Starts any that aren't running.
    public func addViewer(devices: [RingDevice]) async {
        viewers += 1
        await startAllStreams(for: devices)
    }

    /// The device list changed while views are open.
    public func refresh(devices: [RingDevice]) async {
        if viewers > 0 {
            await startAllStreams(for: devices)
        } else if !pinned.isEmpty {
            await startAllStreams(for: devices.filter { pinned.contains($0.id) })
        }
    }

    /// A view stopped showing streams. The last one out stops them.
    public func removeViewer() async {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            if pinned.isEmpty { await stopAllStreams() } else { await stopStreams(except: pinned) }
        }
    }

    /// Start streams for all provided devices
    public func startAllStreams(for devices: [RingDevice]) async {
        guard !DemoMode.isOn else { return }
        // Merge: several views (popover, call panel) may each pass their own subset.
        for d in devices where !self.devices.contains(where: { $0.id == d.id }) { self.devices.append(d) }
        isConnecting = true
        let gen = generation

        // Start devices with no entry yet, and retry ones that failed or dropped.
        // A device that's already connecting/connected is left alone.
        let toStart = devices.filter { device in
            guard let info = streams[device.id] else { return true }
            switch info.state {
            case .failed, .disconnected: return true
            default: return false
            }
        }
        for device in toStart {
            if let old = streams[device.id]?.session {
                streams[device.id]?.session = nil  // detach first: its callbacks are now stale
                Task { await old.stop() }
            }
            streams[device.id] = StreamInfo(
                id: device.id,
                deviceName: device.name
            )
        }

        // Run each connection in its own unstructured Task. The SwiftUI .task that
        // calls us gets cancelled and restarted on every popover open, and that
        // cancellation used to kill the in-flight Ring requests (-999 "cancelled").
        // Lifetime is owned by stopAllStreams() via `generation` instead.
        // Staggered: starting every camera in the same instant left the doorbell silent.
        let starts = toStart.enumerated().map { i, device in
            Task {
                if i > 0 { try? await Task.sleep(for: .milliseconds(400 * i)) }
                guard gen == self.generation else { return }
                await self.startStream(for: device, generation: gen)
            }
        }
        for t in starts { await t.value }

        if gen == generation { isConnecting = false }
    }

    /// Start a single stream
    private func startStream(for device: RingDevice, generation gen: Int) async {
        guard var streamInfo = streams[device.id] else { return }

        streamInfo.state = .connecting
        streams[device.id] = streamInfo

        // Ring answers BAD_REQUEST_SESSION_EXPIRED_RETRYABLE (HTTP 400) while a
        // camera is still closing the previous live session. Retry a few times,
        // each with a fresh session (new session_id), backing off 2s, 4s, 6s.
        var attempt = 0
        while true {
            attempt += 1
            let ok = await attemptStream(for: device, streamInfo: &streamInfo, generation: gen)
            if ok || attempt >= 4 || gen != generation || streams[device.id] == nil { return }
            if case .failed(let msg)? = streams[device.id]?.state, !msg.contains("400") { return }
            NSLog("🔁 MultiStreamManager: Retrying \(device.name) (attempt \(attempt + 1))")
            try? await Task.sleep(for: .seconds(2 * attempt))
            if gen != generation || streams[device.id] == nil { return }
            await retire(device.id)
            streamInfo = StreamInfo(id: device.id, deviceName: device.name)
            streamInfo.state = .connecting
            streams[device.id] = streamInfo
        }
    }

    /// One connection attempt. Returns true when the stream started.
    private func attemptStream(for device: RingDevice, streamInfo: inout StreamInfo, generation gen: Int) async -> Bool {
        do {
            let session = try await RingClient.shared.startLiveView(deviceId: device.id,
                                                                    twoWay: talkDevices.contains(device.id))
            startedAt[device.id] = Date()

            // Popover closed while we were waiting: don't resurrect the entry.
            guard gen == generation, streams[device.id] != nil else {
                await session.stop()
                return true
            }
            streamInfo.session = session
            streams[device.id] = streamInfo

            // Set up callbacks
            await session.setCallbacks(
                onStateChange: { [weak self] state in
                    Task { @MainActor in
                        guard let self = self else { return }
                        // Ignore late callbacks from a session we already replaced.
                        if var info = self.streams[device.id], info.session === session {
                            info.state = state
                            if case .failed(let msg) = state {
                                info.error = msg
                            }
                            let dropped: Bool
                            switch state {
                            case .disconnected, .failed: dropped = true
                            default: dropped = false
                            }
                            if dropped { info.videoTrack = nil; info.audioTrack = nil }
                            self.streams[device.id] = info
                            if dropped {
                                NSLog("🔌 MultiStreamManager: \(device.name) dropped (\(state)); reconnecting")
                                self.scheduleReconnect(device)
                            }
                        }
                    }
                },
                onVideoTrack: { [weak self] track in
                    Task { @MainActor in
                        guard let self = self else { return }
                        // Ignore late callbacks from a session we already replaced.
                        if var info = self.streams[device.id], info.session === session {
                            info.videoTrack = track
                            self.streams[device.id] = info
                            NSLog("📹 MultiStreamManager: Got video track for \(device.name)")
                        }
                    }
                },
                onAudioTrack: { [weak self] track in
                    Task { @MainActor in
                        guard let self = self else { return }
                        // Ignore late callbacks from a session we already replaced.
                        if var info = self.streams[device.id], info.session === session {
                            info.audioTrack = track
                            // Mute if not the active device
                            let shouldMute = self.activeDeviceId != device.id
                            track.isEnabled = !shouldMute
                            self.streams[device.id] = info
                            NSLog("🔊 MultiStreamManager: Got audio track for \(device.name), muted=\(shouldMute)")
                        }
                    }
                }
            )

            // Start the session
            try await session.start()

            // Stopped while connecting: shut this one down too.
            if gen != generation || streams[device.id]?.session == nil {
                await session.stop()
                return true
            }
            NSLog("📹 MultiStreamManager: Started stream for \(device.name)")
            return true

        } catch {
            NSLog("❌ MultiStreamManager: Failed to start stream for \(device.name): \(error)")
            if var info = streams[device.id] {
                info.state = .failed(error.localizedDescription)
                info.error = error.localizedDescription
                streams[device.id] = info
            }
            return false
        }
    }

    // MARK: Self-healing

    /// Consecutive reconnects without a frame, per device. Reset by `markHealthy`.
    private var reconnects: [Int: Int] = [:]
    private static let maxReconnects = 5

    /// When each device's current session started, to spot sessions Ring closes at once.
    private var startedAt: [Int: Date] = [:]
    /// Devices that have sent at least one frame while this viewer session is open.
    private var everSentVideo: Set<Int> = []
    /// Devices we stopped retrying; the tile offers "Try again".
    @Published public private(set) var gaveUp: Set<Int> = []

    /// Frames are flowing for this device again (30s of steady video).
    public func markHealthy(_ deviceId: Int) {
        reconnects[deviceId] = 0
    }

    /// A first frame arrived for this device.
    public func markFrame(_ deviceId: Int) {
        everSentVideo.insert(deviceId)
    }

    /// Connected but no picture yet: ask for a fresh session now rather than waiting
    /// ~30s for Ring to close the silent one. Uses the same retry budget.
    public func nudge(deviceId: Int) async {
        guard viewers > 0, !everSentVideo.contains(deviceId),
              let device = devices.first(where: { $0.id == deviceId }) else { return }
        let n = (reconnects[deviceId] ?? 0) + 1
        reconnects[deviceId] = n
        guard n <= 1 else {
            NSLog("🔌 MultiStreamManager: \(device.name) still silent; giving up")
            gaveUp.insert(deviceId)
            await retire(deviceId)
            return
        }
        NSLog("👉 MultiStreamManager: \(device.name) connected but silent; asking again")
        await restartStream(deviceId: deviceId)
    }

    /// The user asked to try a camera again: fresh budget, fresh session.
    public func retry(deviceId: Int) async {
        reconnects[deviceId] = 0
        gaveUp.remove(deviceId)
        await restartStream(deviceId: deviceId)
    }

    /// Sessions to end on quit. Used by the app's terminate handler.
    public func sessionsForShutdown() -> [LiveViewSession] {
        generation += 1
        return streams.values.compactMap { $0.session }
    }

    /// Stop a camera's session on purpose. Detach it first so its final
    /// "disconnected" callback is ignored as stale rather than read as a drop.
    private func retire(_ deviceId: Int) async {
        guard let old = streams[deviceId]?.session else { return }
        streams[deviceId]?.session = nil
        streams[deviceId]?.videoTrack = nil
        streams[deviceId]?.audioTrack = nil
        await old.stop()
    }

    /// Start a fresh session for one camera (e.g. its feed froze). No-op if nobody's watching.
    public func restartStream(deviceId: Int) async {
        guard viewers > 0, let device = devices.first(where: { $0.id == deviceId }) else { return }
        let gen = generation
        await retire(deviceId)
        guard gen == generation, viewers > 0 else { return }
        NSLog("🔁 MultiStreamManager: Restarting \(device.name)")
        gaveUp.remove(deviceId)
        streams[deviceId] = StreamInfo(id: device.id, deviceName: device.name)
        await startStream(for: device, generation: gen)
    }

    private func scheduleReconnect(_ device: RingDevice) {
        let n = (reconnects[device.id] ?? 0) + 1
        reconnects[device.id] = n
        // A camera that has never sent a frame (privacy cover, asleep) gets one retry.
        let budget = everSentVideo.contains(device.id) ? Self.maxReconnects : 1
        guard n <= budget else {
            NSLog("🔌 MultiStreamManager: \(device.name) gave up after \(n - 1) reconnects")
            gaveUp.insert(device.id)
            return
        }
        // Ring closing a session within seconds usually means it still holds an older
        // one for this camera. Wait long enough for that to expire.
        let lived = startedAt[device.id].map { Date().timeIntervalSince($0) } ?? 60
        let delay: Double = lived < 20 ? Double(15 * n) : Double(min(2 * n, 10))
        NSLog("🔌 MultiStreamManager: \(device.name) retry \(n)/\(budget) in \(Int(delay))s (session lived \(Int(lived))s)")
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, gen == self.generation else { return }
            await self.restartStream(deviceId: device.id)
        }
    }

    /// Stop all streams
    public func stopAllStreams() async {
        NSLog("📹 MultiStreamManager: Stopping all streams")
        // Take ownership of the current sessions and clear state first, so a
        // reopen that starts new streams meanwhile is never wiped by this stop.
        generation += 1
        reconnects.removeAll()
        everSentVideo.removeAll()
        gaveUp.removeAll()
        let sessions = streams.values.compactMap { $0.session }
        streams.removeAll()
        for session in sessions {
            await session.stop()
        }
    }

    /// Stop every stream except these (the recorder's), leaving those untouched.
    public func stopStreams(except keep: Set<Int>) async {
        let drop = streams.keys.filter { !keep.contains($0) }
        guard !drop.isEmpty else { return }
        NSLog("📹 MultiStreamManager: stopping \(drop.count) streams, keeping \(keep.count) for recording")
        var sessions: [LiveViewSession] = []
        for id in drop {
            if let s = streams[id]?.session { sessions.append(s) }
            streams[id] = nil
            reconnects[id] = nil
            gaveUp.remove(id)
        }
        devices.removeAll { drop.contains($0.id) }
        for session in sessions { await session.stop() }
    }

    /// Get video track for a specific device
    public func getVideoTrack(for deviceId: Int) -> RTCVideoTrack? {
        return streams[deviceId]?.videoTrack
    }

    /// Get connection state for a specific device
    public func getState(for deviceId: Int) -> LiveViewSession.State {
        return streams[deviceId]?.state ?? .idle
    }

    /// Get error message for a specific device
    public func getError(for deviceId: Int) -> String? {
        return streams[deviceId]?.error
    }

    /// Check if a device has an active video track
    public func hasVideoTrack(for deviceId: Int) -> Bool {
        return streams[deviceId]?.videoTrack != nil
    }

    // MARK: - Active Device (Audio Control)

    /// Set the active device - only this device's audio will play
    public func setActiveDevice(_ deviceId: Int) {
        guard activeDeviceId != deviceId else { return }

        NSLog("🔊 MultiStreamManager: Switching audio to device \(deviceId)")
        activeDeviceId = deviceId

        // Mute all other devices, unmute the active one
        for (id, streamInfo) in streams {
            if let audioTrack = streamInfo.audioTrack {
                let shouldEnable = (id == deviceId)
                audioTrack.isEnabled = shouldEnable
                NSLog("🔊   Device \(streamInfo.deviceName): audio \(shouldEnable ? "ON" : "OFF")")
            }
        }
    }

    /// Mute/unmute the active device's incoming audio
    public func setMuted(_ muted: Bool) {
        guard let activeId = activeDeviceId,
              let audioTrack = streams[activeId]?.audioTrack else { return }
        audioTrack.isEnabled = !muted
        NSLog("🔊 MultiStreamManager: Active device audio \(muted ? "MUTED" : "UNMUTED")")
    }

    // MARK: - Push-to-Talk

    /// Cameras whose session sends audio (microphone open). Only while you're on them.
    private var talkDevices: Set<Int> = []
    @Published public private(set) var connectingMic: Set<Int> = []
    /// Still holding Talk (so a slow reconnect doesn't open the mic after you let go).
    private var talkHeld: Set<Int> = []

    /// Start talking. Sessions are listen-only (no microphone) until now, so the first
    /// press reconnects this camera two-way, which takes a couple of seconds.
    public func startTalking(for deviceId: Int) async {
        talkHeld.insert(deviceId)
        if let session = streams[deviceId]?.session, session.twoWay {
            await session.startTalking()
            return
        }
        guard let device = devices.first(where: { $0.id == deviceId }) else { return }
        talkDevices.insert(deviceId)
        connectingMic.insert(deviceId)
        NSLog("🎤 MultiStreamManager: reconnecting \(device.name) two-way for talk")
        await reconnect(device)
        // Wait for it to come back (up to 10s), then open the mic.
        for _ in 0..<40 {
            if let s = streams[deviceId]?.session, s.twoWay, streams[deviceId]?.state == .connected {
                connectingMic.remove(deviceId)
                if talkHeld.contains(deviceId) { await s.startTalking() }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        connectingMic.remove(deviceId)
    }

    /// Leaving a camera you talked on: go back to listen-only so the mic is released.
    public func endTalkMode(for deviceId: Int) async {
        guard talkDevices.remove(deviceId) != nil,
              let device = devices.first(where: { $0.id == deviceId }) else { return }
        NSLog("🎤 MultiStreamManager: \(device.name) back to listen-only (mic released)")
        await reconnect(device)
    }

    private func reconnect(_ device: RingDevice) async {
        let gen = generation
        await retire(device.id)
        guard gen == generation else { return }
        streams[device.id] = StreamInfo(id: device.id, deviceName: device.name)
        await startStream(for: device, generation: gen)
    }

    /// Stop talking on a specific device
    public func stopTalking(for deviceId: Int) async {
        talkHeld.remove(deviceId)
        guard let session = streams[deviceId]?.session else {
            NSLog("🎤 MultiStreamManager: No session for device \(deviceId)")
            return
        }
        await session.stopTalking()
    }

    /// Check if currently talking on a device
    public func isTalking(for deviceId: Int) async -> Bool {
        guard let session = streams[deviceId]?.session else { return false }
        return await session.isTalking
    }
}
