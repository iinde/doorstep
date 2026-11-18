import AppKit
import RingClient

/// The optional cloud check: three frames to Claude when this Mac can't tell who it was.
/// Off unless switched on in Settings, uses your own key, and stops at a daily cap.
enum ClaudeCheck {
    static let model = "claude-haiku-5-5"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "claudeCheckEnabled") }
    static var dailyCap: Int {
        let v = UserDefaults.standard.integer(forKey: "claudeCheckDailyCap")
        return v > 0 ? v : 20
    }

    /// Calls made today (resets at midnight).
    static var usedToday: Int {
        let d = UserDefaults.standard
        guard d.string(forKey: "claudeCheckDay") == dayKey else { return 0 }
        return d.integer(forKey: "claudeCheckCount")
    }

    private static var dayKey: String { Date().formatted(.iso8601.year().month().day()) }

    private static func countOne() {
        let d = UserDefaults.standard
        if d.string(forKey: "claudeCheckDay") != dayKey {
            d.set(dayKey, forKey: "claudeCheckDay")
            d.set(0, forKey: "claudeCheckCount")
        }
        d.set(d.integer(forKey: "claudeCheckCount") + 1, forKey: "claudeCheckCount")
    }

    struct Answer: Decodable {
        var is_delivery: Bool
        var carrier: String?
        var carrying_parcel: Bool?
        var confidence: Double?
        var description: String?
    }

    static func ask(frames: [CGImage], camera: String) async -> Identity? {
        guard enabled, usedToday < dailyCap,
              let key = try? await KeychainManager.shared.getAnthropicAPIKey(), !key.isEmpty else { return nil }
        let carriers = Carrier.allCases.map(\.rawValue).joined(separator: ", ")
        var content: [[String: Any]] = frames.prefix(3).compactMap { frame in
            let rep = NSBitmapImageRep(cgImage: frame)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
            return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
        }
        content.append(["type": "text", "text": """
        These are frames from a home security camera called "\(camera)" in the UK. \
        Is the person a delivery driver or postal worker? If so, which company (one of: \(carriers)), \
        judged from uniform, logos, van livery or bags? Reply with only JSON: \
        {"is_delivery": bool, "carrier": string or null, "carrying_parcel": bool, "confidence": 0 to 1, \
        "description": "under 12 words, no names or personal details"}
        """])
        let body: [String: Any] = ["model": model, "max_tokens": 200,
                                   "messages": [["role": "user", "content": content]]]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        countOne()
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]],
              let text = blocks.compactMap({ $0["text"] as? String }).first,
              let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(text[start...end].utf8))
        else {
            NSLog("🧠 Claude check failed or unreadable")
            return nil
        }
        let carrier = answer.carrier.flatMap { name in
            Carrier.allCases.first { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }
        }
        return Identity(carrier: carrier, isDelivery: answer.is_delivery,
                        confidence: answer.confidence ?? 0.7, source: .claude, note: answer.description)
    }
}
