import Foundation
import AVFoundation
import AppKit
import UserNotifications
import RingClient

// MARK: - Text to sound

/// Turns a sentence into sound for the camera's speaker, with a voice already on this Mac.
enum SpeechSynth {
    /// The nicest voice installed for your language (Premium, then Enhanced, then standard).
    static func voice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "replyVoice"), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let all = AVSpeechSynthesisVoice.speechVoices()
        let mine = all.filter { $0.language == lang }
        let pool = mine.isEmpty ? all.filter { $0.language.hasPrefix(String(lang.prefix(2))) } : mine
        return pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: lang)
    }

    private final class Collector: @unchecked Sendable {
        let synth = AVSpeechSynthesizer()
        var samples: [Float] = []
        var rate = 22_050.0
        var done = false
    }

    /// 48 kHz mono samples, with a short pause either side so nothing is clipped.
    static func samples(_ text: String) async -> [Int16] {
        let c = Collector()
        let u = AVSpeechUtterance(string: text)
        u.voice = voice()
        let mono: [Float] = await withCheckedContinuation { cont in
            c.synth.write(u) { buffer in
                guard !c.done else { return }
                guard let b = buffer as? AVAudioPCMBuffer, b.frameLength > 0 else {
                    c.done = true
                    cont.resume(returning: c.samples)
                    return
                }
                c.rate = b.format.sampleRate
                let n = Int(b.frameLength)
                if let f = b.floatChannelData {
                    c.samples.append(contentsOf: UnsafeBufferPointer(start: f[0], count: n))
                } else if let i = b.int16ChannelData {
                    c.samples.append(contentsOf: UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32_768 })
                } else if let i = b.int32ChannelData {
                    c.samples.append(contentsOf: UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 2_147_483_648 })
                }
            }
        }
        return resample(mono, from: c.rate)
    }

    static func resample(_ input: [Float], from rate: Double) -> [Int16] {
        guard !input.isEmpty, rate > 0 else { return [] }
        let out = SpeechAudioDevice.sampleRate
        let peak = max(input.map { abs($0) }.max() ?? 1, 0.05)
        let gain = min(0.9 / peak, 4)          // doorbell speakers are small: use the headroom
        let count = Int(Double(input.count) * out / rate)
        let pad = [Int16](repeating: 0, count: Int(out * 0.35))
        var result = pad
        result.reserveCapacity(count + pad.count * 2)
        for i in 0..<count {
            let pos = Double(i) * rate / out
            let a = Int(pos), b = min(a + 1, input.count - 1)
            let v = input[a] + (input[b] - input[a]) * Float(pos - Double(a))
            result.append(Int16(max(-1, min(1, v * gain)) * 32_000))
        }
        return result + pad
    }
}

// MARK: - Say it at the door

/// Type a sentence and your Mac says it through the camera, in a natural voice. The
/// microphone is never opened: the sound goes straight from the voice into the call.
@MainActor
public final class SpokenReplies: ObservableObject {
    public static let shared = SpokenReplies()
    public static let starters = ["Hello, I'll be right there.",
                                  "Please leave it by the door. Thank you.",
                                  "Sorry, we can't come to the door right now.",
                                  "No thank you, we're not interested."]

    @Published public var saved: [String] { didSet { if !DemoMode.isOn { UserDefaults.standard.set(saved, forKey: "spokenReplies") } } }
    /// The camera being spoken through right now.
    @Published public private(set) var speaking: Int?
    @Published public private(set) var status: String?
    private var preview: AVSpeechSynthesizer?

    private init() {
        saved = (DemoMode.isOn ? nil : UserDefaults.standard.stringArray(forKey: "spokenReplies")) ?? Self.starters
    }

    /// Hear it on this Mac first (nothing goes to the camera).
    public func hear(_ text: String) {
        let s = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: text)
        u.voice = SpeechSynth.voice()
        preview = s
        s.speak(u)
    }

    /// Say `text` through this camera's speaker. Returns whether it went out.
    @discardableResult
    public func say(_ text: String, on device: RingDevice) async -> Bool {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard !text.isEmpty, speaking == nil else { return false }
        speaking = device.id
        status = "Connecting to \(device.name)…"
        defer { speaking = nil }
        if DemoMode.isOn {
            hear(text)
            status = "Saying it at \(device.name)…"
            try? await Task.sleep(for: .seconds(2.5))
            status = "Said at \(device.name)"
            return true
        }
        let samples = await SpeechSynth.samples(text)
        guard !samples.isEmpty else { status = "This Mac couldn't make the voice"; return false }
        do {
            let session = try await RingClient.shared.startLiveView(deviceId: device.id, twoWay: true, speech: true)
            try await session.start()
            var connected = false
            for _ in 0..<60 {
                let s = await session.state
                if s == .connected { connected = true; break }
                if case .failed = s { break }
                if s == .disconnected { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard connected else {
                await session.stop()
                status = "Couldn't reach \(device.name)"
                return false
            }
            await session.startTalking()
            status = "Saying it at \(device.name)…"
            try? await Task.sleep(for: .milliseconds(500))
            await SpeechAudioDevice.shared.play(samples)
            try? await Task.sleep(for: .milliseconds(600))
            await session.stop()
            status = "Said at \(device.name)"
            NSLog("🗣 Said at \(device.name): \(text.count) characters")
            return true
        } catch {
            NSLog("🗣 Speak failed: \(error)")
            status = "Couldn't reach \(device.name)"
            return false
        }
    }
}

// MARK: - Answer couriers for you

/// When a courier rings and you can't answer, Doorstep can tell them where to leave it.
/// Off until you switch it on, and it only ever says the sentence you wrote.
@MainActor
public enum CourierReply {
    public static let defaultMessage = "Hello. Please leave the parcel by the door. Thank you."
    private static var lastSpoke: [Int: Date] = [:]

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "courierReplyEnabled") }
    public static var message: String {
        let m = UserDefaults.standard.string(forKey: "courierReplyText") ?? ""
        return m.trimmingCharacters(in: .whitespaces).isEmpty ? defaultMessage : m
    }
    /// "away": only in Away mode. "always": any time.
    static var whenRule: String { UserDefaults.standard.string(forKey: "courierReplyWhen") ?? "away" }
    static var onlyIfExpecting: Bool { UserDefaults.standard.object(forKey: "courierReplyExpecting") as? Bool ?? true }
    static var onlyCouriers: Bool { UserDefaults.standard.object(forKey: "courierReplyCouriersOnly") as? Bool ?? true }

    /// Why it wouldn't speak right now, or nil if a ring would be answered.
    public static func holdReason() -> String? {
        if whenRule == "away", !(Modes.shared.enabled && Modes.shared.current == .away) { return "Doorstep isn't in Away mode" }
        if onlyIfExpecting, ParcelStore.shared.active.isEmpty { return "no parcels are expected" }
        return nil
    }

    /// The doorbell just rang.
    public static func doorbellRang(_ device: RingDevice) async {
        guard isEnabled, !DemoMode.isOn, device.deviceType == .doorbell else { return }
        if let last = lastSpoke[device.id], Date().timeIntervalSince(last) < 600 { return }
        if let why = holdReason() { NSLog("🗣 Courier reply held: \(why)"); return }
        lastSpoke[device.id] = Date()   // one attempt per ring, whatever happens next

        var who = "the person at \(device.name)"
        if onlyCouriers {
            var found: Identity?
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
                guard let data = try? await RingClient.shared.getSnapshot(deviceId: device.id),
                      let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let id = await ThumbnailCache.identify(frames: [image], first: nil, last: nil, camera: device.name,
                                                       deviceId: device.id, allowCloud: false)
                if id.isDelivery { found = id; break }
            }
            guard let found else {
                NSLog("🗣 Courier reply held: didn't recognise a courier")
                lastSpoke[device.id] = nil
                return
            }
            who = found.carrier.map { "the \($0.rawValue) driver" } ?? "the courier"
        }
        let text = message
        let said = await SpokenReplies.shared.say(text, on: device)
        guard said else { return }
        let c = UNMutableNotificationContent()
        c.title = "Doorstep answered \(device.name)"
        c.body = "Told \(who): \"\(text)\""
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "courier-reply-\(UUID().uuidString)", content: c, trigger: nil))
        await PhoneAlerts.send(title: c.title, body: c.body, image: nil)
    }
}
