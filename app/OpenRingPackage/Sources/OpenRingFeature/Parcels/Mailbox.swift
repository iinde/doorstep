import Foundation
import RingClient

/// Optional: read delivery emails straight from a Microsoft mailbox (Outlook.com or work).
///
/// Self-contained by design: there is no Doorstep server. Microsoft requires every app that
/// reads mail to have an "Application (client) ID", so whoever wants this enters their own
/// (a free app registration, see Settings > Parcels). Without one, parcels come in by paste
/// or by dragging emails onto Doorstep. Read-only (Mail.Read); tokens stay in the Keychain.
@MainActor
public final class Mailbox: ObservableObject {
    public static let shared = Mailbox()

    public enum State: Equatable {
        case notSetUp
        case signedOut
        case awaitingCode(userCode: String, url: URL)
        case signedIn(String)
        case failed(String)
    }

    @Published public private(set) var state: State = .notSetUp
    @Published public private(set) var lastChecked: Date?

    private let tokenKey = "ms_refresh_token"
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var signInTask: Task<Void, Never>?

    public var clientId: String {
        (UserDefaults.standard.string(forKey: "msClientId") ?? "").trimmingCharacters(in: .whitespaces)
    }

    private init() {}

    public func refreshState() async {
        guard !clientId.isEmpty else { state = .notSetUp; return }
        if (try? await KeychainManager.shared.secret(for: tokenKey)) != nil {
            state = .signedIn(UserDefaults.standard.string(forKey: "msAccountName") ?? "Signed in")
        } else if case .awaitingCode = state {
        } else {
            state = .signedOut
        }
    }

    private var authority: String { "https://login.microsoftonline.com/common/oauth2/v2.0" }
    private let scope = "offline_access Mail.Read User.Read"

    /// Device-code sign-in: shows a short code; you enter it on microsoft.com in your browser.
    public func signIn() {
        guard !clientId.isEmpty else { state = .notSetUp; return }
        signInTask?.cancel()
        signInTask = Task {
            do {
                let start = try await form("\(authority)/devicecode", ["client_id": clientId, "scope": scope])
                guard let code = start["user_code"] as? String, let device = start["device_code"] as? String,
                      let uri = (start["verification_uri"] as? String).flatMap(URL.init(string:)) else {
                    state = .failed((start["error_description"] as? String) ?? "Microsoft didn't start sign-in.")
                    return
                }
                state = .awaitingCode(userCode: code, url: uri)
                let interval = max(5, start["interval"] as? Int ?? 5)
                let deadline = Date().addingTimeInterval(TimeInterval(start["expires_in"] as? Int ?? 900))
                while Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    let tok = try await form("\(authority)/token", [
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "client_id": clientId, "device_code": device,
                    ])
                    if let err = tok["error"] as? String {
                        if err == "authorization_pending" || err == "slow_down" { continue }
                        state = .failed((tok["error_description"] as? String)?.components(separatedBy: "\r").first ?? err)
                        return
                    }
                    try await store(tok)
                    let me = try await get("https://graph.microsoft.com/v1.0/me?$select=userPrincipalName,displayName")
                    let name = (me["userPrincipalName"] as? String) ?? (me["displayName"] as? String) ?? "Signed in"
                    UserDefaults.standard.set(name, forKey: "msAccountName")
                    state = .signedIn(name)
                    await check()
                    return
                }
                if !Task.isCancelled { state = .failed("The code expired. Try again.") }
            } catch {
                if !Task.isCancelled { state = .failed(error.localizedDescription) }
            }
        }
    }

    public func signOut() async {
        signInTask?.cancel()
        try? await KeychainManager.shared.deleteSecret(for: tokenKey)
        accessToken = nil
        UserDefaults.standard.removeObject(forKey: "msAccountName")
        state = clientId.isEmpty ? .notSetUp : .signedOut
    }

    /// Look through the last 14 days of mail for delivery messages. Only messages that
    /// look like deliveries are read; only the parcel facts are kept.
    public func check() async {
        guard case .signedIn = state else { return }
        do {
            let since = Date().addingTimeInterval(-14 * 86400).formatted(.iso8601)
            let filter = "receivedDateTime ge \(since)"
            var url = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
            url.queryItems = [
                .init(name: "$filter", value: filter),
                .init(name: "$orderby", value: "receivedDateTime desc"),
                .init(name: "$top", value: "100"),
                .init(name: "$select", value: "subject,from,receivedDateTime,bodyPreview"),
            ]
            let list = try await get(url.url!.absoluteString)
            let messages = list["value"] as? [[String: Any]] ?? []
            var found: [Parcel] = []
            let iso = ISO8601DateFormatter()
            for m in messages {
                let subject = m["subject"] as? String ?? ""
                let address = ((m["from"] as? [String: Any])?["emailAddress"] as? [String: Any])
                let sender = "\(address?["name"] as? String ?? "") <\(address?["address"] as? String ?? "")>"
                let preview = m["bodyPreview"] as? String ?? ""
                let date = (m["receivedDateTime"] as? String).flatMap(iso.date(from:)) ?? Date()
                guard looksLikeDelivery(subject: subject, sender: sender, preview: preview) else { continue }
                var body = preview
                // Tracking numbers are often below the preview: fetch the full text for these only.
                if let id = m["id"] as? String, ParcelParser.numbers(in: preview, carrier: nil).isEmpty {
                    if let full = try? await get("https://graph.microsoft.com/v1.0/me/messages/\(id)?$select=body"),
                       let html = (full["body"] as? [String: Any])?["content"] as? String {
                        body = Self.plain(html)
                    }
                }
                found += ParcelParser.parse(subject: subject, from: sender, body: body, date: date)
            }
            let changed = ParcelStore.shared.ingest(found)
            lastChecked = Date()
            NSLog("📬 Mailbox: \(messages.count) recent messages, \(found.count) parcel updates, \(changed) changed")
        } catch {
            NSLog("📬 Mailbox check failed: \(error.localizedDescription)")
        }
    }

    private func looksLikeDelivery(subject: String, sender: String, preview: String) -> Bool {
        let s = (subject + " " + sender + " " + preview).lowercased()
        let words = ["deliver", "parcel", "dispatch", "shipped", "tracking", "on its way", "out for delivery", "missed you", "courier"]
        return words.contains { s.contains($0) }
            || Carrier.allCases.contains { c in c.mailDomains.contains { sender.lowercased().contains($0) } }
    }

    nonisolated static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</tr>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        return s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }

    // MARK: HTTP

    private func store(_ tok: [String: Any]) async throws {
        guard let access = tok["access_token"] as? String else { throw URLError(.userAuthenticationRequired) }
        accessToken = access
        accessExpiry = Date().addingTimeInterval(TimeInterval((tok["expires_in"] as? Int ?? 3600) - 120))
        if let refresh = tok["refresh_token"] as? String {
            try await KeychainManager.shared.saveSecret(refresh, for: tokenKey)
        }
    }

    private func token() async throws -> String {
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let refresh = try await KeychainManager.shared.secret(for: tokenKey) else {
            state = .signedOut
            throw URLError(.userAuthenticationRequired)
        }
        let tok = try await form("\(authority)/token", [
            "grant_type": "refresh_token", "client_id": clientId, "refresh_token": refresh, "scope": scope,
        ])
        if tok["error"] != nil {
            await signOut()
            throw URLError(.userAuthenticationRequired)
        }
        try await store(tok)
        return accessToken!
    }

    private func form(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func get(_ url: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
