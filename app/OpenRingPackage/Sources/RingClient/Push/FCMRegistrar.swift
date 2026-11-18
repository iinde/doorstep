import Foundation
import os

// Android checkin + GCM register3 + Firebase Installations + FCM registration,
// ported from push-receiver 4.4.0 src/gcm.ts and src/fcm.ts. Despite the
// "Android" names, push-receiver checks in as a Chrome browser on macOS and
// registers a web push subscription; that is the flow dgreif/ring uses today.
//
// The request builders are separate static functions so tests can check the
// exact bytes without touching the network.

enum PushRegistrationError: Error, Sendable, Equatable {
    case http(endpoint: String, status: Int)
    case badResponse(endpoint: String)
    case registerFailed(String)
}

struct FCMRegistrar: Sendable {
    let session: URLSession
    private static let log = Logger(subsystem: "dev.open-ring", category: "RingPush")

    init(session: URLSession = .shared) { self.session = session }

    // MARK: - Full registration (client.ts registerIfNeeded, new-credentials branch)

    func register() async throws -> PushCredentials {
        let keys = WebPushKeys.generate()
        let checkin = try await checkIn(existing: nil)
        guard let androidId = checkin.androidId, let securityToken = checkin.securityToken else {
            throw PushRegistrationError.badResponse(endpoint: "checkin")
        }
        let gcm = try await registerGCM(androidId: String(androidId), securityToken: String(securityToken))
        let installation = try await installFirebase()
        let fcmToken = try await registerFCM(gcmToken: gcm.token, installation: installation, keys: keys)
        Self.log.info("Push registration complete (FCM token \(fcmToken.count) chars)")
        return PushCredentials(gcm: gcm, fcm: .init(token: fcmToken, installation: installation),
                               keys: .init(keys), config: .current, tokenRegisteredWithRing: nil)
    }

    // MARK: - Checkin (gcm.ts checkIn)

    static func checkinRequest(existing: PushCredentials.GCM?, timeZone: String = TimeZone.current.identifier) -> URLRequest {
        let body = AndroidCheckinRequest(
            chromeVersion: RingPushConstants.chromeVersion,
            androidId: existing.flatMap { UInt64($0.androidId) },
            securityToken: existing.flatMap { UInt64($0.securityToken) },
            timeZone: timeZone
        ).encode()
        var r = URLRequest(url: RingPushConstants.checkinURL)
        r.httpMethod = "POST"
        r.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        return r
    }

    @discardableResult
    func checkIn(existing: PushCredentials.GCM?) async throws -> AndroidCheckinResponse {
        let data = try await send(Self.checkinRequest(existing: existing), name: "checkin")
        do {
            return try AndroidCheckinResponse.decode(data)
        } catch {
            throw PushRegistrationError.badResponse(endpoint: "checkin")
        }
    }

    // MARK: - GCM register3 (gcm.ts doRegister / postRegister)

    static func register3Request(androidId: String, securityToken: String, appId: String) -> URLRequest {
        let fields: [(String, String)] = [
            ("app", RingPushConstants.chromeId),
            ("X-subtype", appId),
            ("device", androidId),
            ("sender", RingPushConstants.vapidKey.isEmpty ? RingPushConstants.defaultChromeSender : RingPushConstants.vapidKey),
        ]
        var r = URLRequest(url: RingPushConstants.registerURL)
        r.httpMethod = "POST"
        r.setValue("AidLogin \(androidId):\(securityToken)", forHTTPHeaderField: "Authorization")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(formEncode(fields).utf8)
        return r
    }

    /// application/x-www-form-urlencoded exactly like URLSearchParams.toString().
    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "*-._ ")
        func enc(_ s: String) -> String {
            (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: " ", with: "+")
        }
        return fields.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    }

    /// register3 answers "token=XYZ" or "Error=REASON".
    static func parseRegister3(_ body: String) throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("Error") {
            let reason = trimmed.components(separatedBy: "=").last ?? "unknown"
            throw PushRegistrationError.registerFailed(reason)
        }
        guard trimmed.hasPrefix("token="), trimmed.count > 6 else {
            throw PushRegistrationError.badResponse(endpoint: "register3")
        }
        return String(trimmed.dropFirst(6))
    }

    func registerGCM(androidId: String, securityToken: String) async throws -> PushCredentials.GCM {
        let appId = "wp:\(RingPushConstants.bundleId)#\(UUID().uuidString.lowercased())"
        let request = Self.register3Request(androidId: androidId, securityToken: securityToken, appId: appId)
        var lastError: Error = PushRegistrationError.registerFailed("unknown")
        // postRegister retries up to 5 times, 1 s apart, when the body contains "Error".
        for attempt in 0...5 {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            let data = try await send(request, name: "register3")
            do {
                let token = try Self.parseRegister3(String(decoding: data, as: UTF8.self))
                return .init(androidId: androidId, securityToken: securityToken, token: token, appId: appId)
            } catch {
                lastError = error
                Self.log.warning("register3 attempt \(attempt + 1) failed: \(String(describing: error), privacy: .public)")
            }
        }
        throw lastError
    }

    // MARK: - Firebase Installations (fcm.ts installFCM / refreshFCMInstallationToken)

    /// fcm.ts generateFirebaseFID(): 17 random bytes, top nibble 0b0111, base64url, first 22 chars.
    static func generateFID(randomBytes: [UInt8]? = nil) -> String {
        var bytes = randomBytes ?? (0..<17).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = 0b0111_0000 + (bytes[0] % 0b0001_0000)
        return String(Base64URL.encode(Data(bytes)).prefix(22))
    }

    static func installationRequest(fid: String) -> URLRequest {
        var r = URLRequest(url: URL(string: RingPushConstants.installationsBase + "installations")!)
        r.httpMethod = "POST"
        r.setValue(RingPushConstants.emptyFirebaseHeartbeat, forHTTPHeaderField: "x-firebase-client")
        r.setValue(RingPushConstants.firebaseAPIKey, forHTTPHeaderField: "x-goog-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "appId": RingPushConstants.firebaseAppId,
            "authVersion": RingPushConstants.fisAuthVersion,
            "fid": fid,
            "sdkVersion": RingPushConstants.fisSDKVersion,
        ], options: [.sortedKeys])
        return r
    }

    static func installationRefreshRequest(_ installation: PushCredentials.Installation) -> URLRequest {
        // encodeURIComponent: ASCII letters, digits and -_.!~*'() pass through.
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        let fid = installation.fid.addingPercentEncoding(withAllowedCharacters: allowed) ?? installation.fid
        let url = URL(string: RingPushConstants.installationsBase + "installations/\(fid)/authTokens:generate")!
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("\(RingPushConstants.fisAuthVersion) \(installation.refreshToken)", forHTTPHeaderField: "Authorization")
        r.setValue(RingPushConstants.emptyFirebaseHeartbeat, forHTTPHeaderField: "x-firebase-client")
        r.setValue(RingPushConstants.firebaseAPIKey, forHTTPHeaderField: "x-goog-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "installation": ["sdkVersion": RingPushConstants.fisSDKVersion, "appId": RingPushConstants.firebaseAppId],
        ], options: [.sortedKeys])
        return r
    }

    /// FIS sends expiresIn as a duration string like "604800s".
    static func parseDuration(_ s: String?) -> TimeInterval? {
        guard let s else { return nil }
        let digits = s.prefix { $0.isNumber || $0 == "." }
        return TimeInterval(digits)
    }

    func installFirebase() async throws -> PushCredentials.Installation {
        let data = try await send(Self.installationRequest(fid: Self.generateFID()), name: "installations")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["authToken"] as? [String: Any],
              let token = auth["token"] as? String,
              let expires = Self.parseDuration(auth["expiresIn"] as? String),
              let refresh = json["refreshToken"] as? String,
              let fid = json["fid"] as? String else {
            throw PushRegistrationError.badResponse(endpoint: "installations")
        }
        return .init(token: token, createdAt: Date(), expiresIn: expires, refreshToken: refresh, fid: fid)
    }

    func refreshInstallation(_ installation: PushCredentials.Installation) async throws -> PushCredentials.Installation {
        let data = try await send(Self.installationRefreshRequest(installation), name: "authTokens:generate")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              let expires = Self.parseDuration(json["expiresIn"] as? String) else {
            throw PushRegistrationError.badResponse(endpoint: "authTokens:generate")
        }
        var updated = installation
        updated.token = token
        updated.createdAt = Date()
        updated.expiresIn = expires
        return updated
    }

    // MARK: - FCM registration (fcm.ts registerFCM)

    static func fcmRegistrationRequest(gcmToken: String, installationToken: String, keys: WebPushKeys) -> URLRequest {
        var r = URLRequest(url: URL(string: RingPushConstants.registrationsBase + "registrations")!)
        r.httpMethod = "POST"
        r.setValue(RingPushConstants.firebaseAPIKey, forHTTPHeaderField: "x-goog-api-key")
        r.setValue(installationToken, forHTTPHeaderField: "x-goog-firebase-installations-auth")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var web: [String: String] = [
            "auth": Base64URL.encode(keys.authSecret),
            "endpoint": RingPushConstants.fcmSendBase + gcmToken,
            "p256dh": Base64URL.encode(keys.publicKey),
        ]
        // "Include VAPID only if it's not default key, otherwise FCM registration will fail"
        if !RingPushConstants.vapidKey.isEmpty { web["applicationPubKey"] = RingPushConstants.vapidKey }
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["web": web], options: [.sortedKeys])
        return r
    }

    func registerFCM(gcmToken: String, installation: PushCredentials.Installation, keys: WebPushKeys) async throws -> String {
        let data = try await send(Self.fcmRegistrationRequest(gcmToken: gcmToken, installationToken: installation.token,
                                                               keys: keys), name: "registrations")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PushRegistrationError.badResponse(endpoint: "registrations")
        }
        if json["error"] != nil { throw PushRegistrationError.registerFailed("fcm registration error") }
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw PushRegistrationError.badResponse(endpoint: "registrations")
        }
        return token
    }

    // MARK: - HTTP (utils/request.ts: retry on non-2xx, step 5 s, at most 3 retries)

    private func send(_ request: URLRequest, name: String) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                Self.log.warning("\(name, privacy: .public) -> HTTP \(status) (\(data.count) bytes)")
                // 4xx other than 429 won't fix itself by retrying.
                if attempt >= 3 || ((400..<500).contains(status) && status != 429) {
                    throw PushRegistrationError.http(endpoint: name, status: status)
                }
            } catch let e as PushRegistrationError {
                throw e
            } catch {
                Self.log.warning("\(name, privacy: .public) network error: \(error.localizedDescription, privacy: .public)")
                if attempt >= 3 { throw error }
            }
            attempt += 1
            try await Task.sleep(for: .seconds(min(attempt * 5, 15)))
        }
    }
}
