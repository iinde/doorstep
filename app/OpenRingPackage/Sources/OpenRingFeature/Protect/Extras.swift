import Foundation
import AppKit
import Speech
import UserNotifications
import RingClient

// MARK: - What visitors said

/// Speech in doorbell clips, turned into text on this Mac (Apple's on-device recogniser).
public final class TranscriptIndex: ObservableObject, @unchecked Sendable {
    public static let shared = TranscriptIndex()
    private let lock = NSLock()
    private var store: [String: String] = [:]
    private let file: URL
    @Published public private(set) var version = 0

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "transcribeClips") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        file = support.appendingPathComponent("Doorstep/transcripts.json")
        if !DemoMode.isOn, let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([String: String].self, from: d) { store = s }
    }

    public func text(_ eventId: String) -> String? { lock.lock(); defer { lock.unlock() }; return store[eventId] }

    func set(_ eventId: String, _ text: String) {
        lock.lock(); store[eventId] = text; let snap = store; lock.unlock()
        if !DemoMode.isOn, let d = try? JSONEncoder().encode(snap) { try? d.write(to: file, options: .atomic) }
        DispatchQueue.main.async { self.version += 1 }
    }

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    /// Transcribe a downloaded clip. On-device only: if this Mac can't do it locally, skip.
    static func transcribe(_ url: URL) async -> String? {
        guard isEnabled, SFSpeechRecognizer.authorizationStatus() == .authorized,
              let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")) ?? SFSpeechRecognizer(),
              rec.supportsOnDeviceRecognition else { return nil }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        return await withCheckedContinuation { c in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    let t = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespaces)
                    c.resume(returning: t.split(separator: " ").count >= 2 ? t : nil)
                } else if error != nil {
                    done = true
                    c.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Camera health

/// Battery and Wi-Fi for every camera, with a gentle alert when a battery's low or a camera
/// drops off. Checked every hour.
@MainActor
public final class HealthMonitor: ObservableObject {
    public static let shared = HealthMonitor()
    @Published public private(set) var health: [Int: CameraHealth] = [:]
    private var lastCheck = Date.distantPast

    public func check(_ devices: [RingDevice], force: Bool = false) async {
        guard !DemoMode.isOn, force || Date().timeIntervalSince(lastCheck) > 3600 else { return }
        lastCheck = Date()
        for d in devices where d.deviceType == .doorbell || d.deviceType == .camera {
            guard let h = try? await RingClient.shared.fetchHealth(deviceId: d.id) else { continue }
            health[d.id] = h
            let battery = h.batteryPercent ?? d.batteryLevel
            if let b = battery, d.isBatteryPowered { await HomeAssistantBridge.shared.publishBattery(cameraId: String(d.id), percent: b) }
            if let b = battery, b <= 20, d.isBatteryPowered { await nudge("battery-\(d.id)", "\(d.name) battery is at \(b)%", "Time to charge it.") }
        }
        for d in devices where !d.isOnline { await nudge("offline-\(d.id)", "\(d.name) is offline", "It isn't connected to Ring. Check its power and Wi-Fi.") }
    }

    /// Once a day per subject.
    private func nudge(_ key: String, _ title: String, _ body: String) async {
        let day = Date().formatted(.iso8601.year().month().day())
        let d = UserDefaults.standard
        guard d.string(forKey: "health." + key) != day else { return }
        d.set(day, forKey: "health." + key)
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "health-\(key)-\(day)", content: c, trigger: nil))
        await PhoneAlerts.send(title: title, body: body, image: nil)
    }
}

// MARK: - Alerts on your phone

/// Doorstep's alerts (with the picture) on your phone, through a service you choose, using your
/// own topic or token: ntfy (no account needed), Pushover, or Telegram.
public enum PhoneAlerts {
    public enum Service: String, CaseIterable, Identifiable { case off = "Off", ntfy = "ntfy", pushover = "Pushover", telegram = "Telegram"; public var id: String { rawValue } }

    public static var service: Service { Service(rawValue: UserDefaults.standard.string(forKey: "phoneService") ?? "") ?? .off }

    public static func send(title: String, body: String, image: Data?) async {
        let d = UserDefaults.standard
        switch service {
        case .off: return
        case .ntfy:
            let server = (d.string(forKey: "ntfyServer") ?? "").isEmpty ? "https://ntfy.sh" : d.string(forKey: "ntfyServer")!
            guard let topic = d.string(forKey: "ntfyTopic"), !topic.isEmpty,
                  let url = URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + topic) else { return }
            var r = URLRequest(url: url)
            r.httpMethod = "PUT"
            let encodedTitle = "=?UTF-8?B?" + Data(title.utf8).base64EncodedString() + "?="
            r.setValue(encodedTitle, forHTTPHeaderField: "Title")
            r.setValue(body.replacingOccurrences(of: "\n", with: " "), forHTTPHeaderField: "Message")
            r.setValue("door,house", forHTTPHeaderField: "Tags")
            if let image {
                r.setValue("doorstep.jpg", forHTTPHeaderField: "Filename")
                r.httpBody = image
            } else {
                r.httpBody = body.data(using: .utf8)
            }
            _ = try? await URLSession.shared.data(for: r)
        case .pushover:
            guard let user = (try? await KeychainManager.shared.secret(for: "pushoverUser")) ?? nil,
                  let token = (try? await KeychainManager.shared.secret(for: "pushoverToken")) ?? nil else { return }
            var r = URLRequest(url: URL(string: "https://api.pushover.net/1/messages.json")!)
            r.httpMethod = "POST"
            let b = "----doorstep\(UUID().uuidString)"
            r.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
            var data = Data()
            func field(_ n: String, _ v: String) { data.append("--\(b)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!) }
            field("token", token); field("user", user); field("title", title); field("message", body)
            if let image {
                data.append("--\(b)\r\nContent-Disposition: form-data; name=\"attachment\"; filename=\"doorstep.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
                data.append(image); data.append("\r\n".data(using: .utf8)!)
            }
            data.append("--\(b)--\r\n".data(using: .utf8)!)
            r.httpBody = data
            _ = try? await URLSession.shared.data(for: r)
        case .telegram:
            guard let bot = (try? await KeychainManager.shared.secret(for: "telegramBot")) ?? nil,
                  let chat = d.string(forKey: "telegramChat"), !chat.isEmpty else { return }
            let text = "*\(title)*\n\(body)"
            if let image {
                var r = URLRequest(url: URL(string: "https://api.telegram.org/bot\(bot)/sendPhoto")!)
                r.httpMethod = "POST"
                let b = "----doorstep\(UUID().uuidString)"
                r.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
                var data = Data()
                func field(_ n: String, _ v: String) { data.append("--\(b)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!) }
                field("chat_id", chat); field("caption", text); field("parse_mode", "Markdown")
                data.append("--\(b)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"doorstep.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
                data.append(image); data.append("\r\n--\(b)--\r\n".data(using: .utf8)!)
                r.httpBody = data
                _ = try? await URLSession.shared.data(for: r)
            } else {
                var r = URLRequest(url: URL(string: "https://api.telegram.org/bot\(bot)/sendMessage")!)
                r.httpMethod = "POST"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": chat, "text": text, "parse_mode": "Markdown"])
                _ = try? await URLSession.shared.data(for: r)
            }
        }
    }
}

// MARK: - Local AI (Ollama)

/// Descriptions from a vision model running on your own Mac with Ollama: richer than the
/// built-in sentence, and nothing leaves your home. Used before Claude when switched on.
public enum LocalAI {
    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "ollamaEnabled") }
    public static var server: String {
        let s = UserDefaults.standard.string(forKey: "ollamaServer") ?? ""
        return s.isEmpty ? "http://127.0.0.1:11434" : s
    }
    public static var model: String { UserDefaults.standard.string(forKey: "ollamaModel") ?? "" }

    /// Models installed in Ollama.
    public static func models() async -> [String] {
        guard let url = URL(string: server + "/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }.sorted()
    }

    static func describe(frames: [CGImage], camera: String) async -> Identity? {
        guard isEnabled, !model.isEmpty, let url = URL(string: server + "/api/generate") else { return nil }
        let images: [String] = frames.prefix(3).compactMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.7])?.base64EncodedString()
        }
        let carriers = Carrier.allCases.map(\.rawValue).joined(separator: ", ")
        let prompt = """
        These are frames from a home security camera called "\(camera)" in the UK. Reply with only JSON: \
        {"is_delivery": bool, "carrier": one of [\(carriers)] or null, "description": "one sentence, under 20 words, \
        describing what the person or vehicle is doing; no names or personal details"}
        """
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt, "images": images,
                                                                   "stream": false, "format": "json"])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String,
              let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        let carrier = (answer["carrier"] as? String).flatMap { n in Carrier.allCases.first { $0.rawValue.caseInsensitiveCompare(n) == .orderedSame } }
        return Identity(carrier: carrier, isDelivery: answer["is_delivery"] as? Bool ?? false, confidence: 0.7,
                        source: .claude, note: answer["description"] as? String)
    }
}
