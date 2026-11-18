import Foundation

// MARK: - Constants

/// Every Google / Ring constant the push path uses, with where it came from.
enum RingPushConstants {
    // dgreif/ring packages/ring-client-api/api.ts registerPushReceiver(): the Ring
    // *Android* app's Firebase project, passed to PushReceiver as `firebase`.
    static let firebaseAPIKey = "AIzaSyCv-hdFBmmdBBJadNy-TFwB-xN_H5m3Bk8"
    static let firebaseProjectId = "ring-17770"
    static let firebaseSenderId = "876313859327" // "for Ring android app. 703521446232 for ring-site"
    static let firebaseAppId = "1:876313859327:android:e10ec6ddb3c81f39"

    // eneris/push-receiver 4.4.0 (the version ring-client-api pins) src/client.ts constructor defaults.
    static let bundleId = "receiver.push.com"
    static let chromeId = "org.chromium.linux"
    static let chromeVersion = "94.0.4606.51"
    static let vapidKey = "" // ring passes none, so FCM gets no applicationPubKey
    static let heartbeatIntervalMs: Int32 = 5 * 60 * 1000

    // push-receiver src/gcm.ts doRegister(): the default `sender` when vapidKey is empty.
    static let defaultChromeSender =
        "BDOU99-h67HcA6JeFXHbSNMu7e2yNNu3RzoMj8TM4W88jITfq7ZmPvIM1Iv-4_l2LxQcYwhqby2xGpWwzjfAnG4"

    // push-receiver src/gcm.ts
    static let checkinURL = URL(string: "https://android.clients.google.com/checkin")!
    static let registerURL = URL(string: "https://android.clients.google.com/c2dm/register3")!
    // push-receiver src/fcm.ts
    static let fcmSendBase = "https://fcm.googleapis.com/fcm/send/"
    static let installationsBase = "https://firebaseinstallations.googleapis.com/v1/projects/\(firebaseProjectId)/"
    static let registrationsBase = "https://fcmregistrations.googleapis.com/v1/projects/\(firebaseProjectId)/"
    static let fisAuthVersion = "FIS_v2"
    static let fisSDKVersion = "w:0.6.6"
    /// fcm.ts getEmptyHeatbeat(): btoa(JSON.stringify({ heartbeats: [], version: 2 })).
    static let emptyFirebaseHeartbeat = Data(#"{"heartbeats":[],"version":2}"#.utf8).base64EncodedString()
    /// fcm.ts INSTALLATION_REFRESH_MARGIN: refresh the 7-day FIS token an hour early.
    static let installationRefreshMargin: TimeInterval = 60 * 60

    // dgreif/ring rest-client.ts: clientApiBaseUrl, apiVersion, and the PATCH body in api.ts.
    static let ringClientsAPI = "https://api.ring.com/clients_api/"
    static let ringAPIVersion = 11
    static let ringDeviceModel = "Doorstep" // ring uses controlCenterDisplayName ?? 'ring-client-api'
}

// MARK: - Persisted credentials

/// The same pieces push-receiver's `Credentials` type holds (src/types.ts).
struct PushCredentials: Codable, Sendable, Equatable {
    struct GCM: Codable, Sendable, Equatable {
        var androidId: String       // uint64 as decimal, like protobufjs `longs: String`
        var securityToken: String   // uint64 as decimal
        var token: String           // register3 token, used in the FCM endpoint URL
        var appId: String           // "wp:receiver.push.com#<uuid>"
    }

    struct Installation: Codable, Sendable, Equatable {
        var token: String
        var createdAt: Date
        var expiresIn: TimeInterval
        var refreshToken: String
        var fid: String

        func isExpired(now: Date = Date(), margin: TimeInterval = RingPushConstants.installationRefreshMargin) -> Bool {
            createdAt.addingTimeInterval(expiresIn - margin) <= now
        }
    }

    struct FCM: Codable, Sendable, Equatable {
        var token: String           // what Ring gets as push_notification_token
        var installation: Installation
    }

    struct Keys: Codable, Sendable, Equatable {
        var privateKey: String      // base64url
        var publicKey: String
        var authSecret: String

        init(_ k: WebPushKeys) {
            privateKey = Base64URL.encode(k.privateKey)
            publicKey = Base64URL.encode(k.publicKey)
            authSecret = Base64URL.encode(k.authSecret)
        }

        var webPushKeys: WebPushKeys? {
            guard let p = Base64URL.decode(privateKey), let q = Base64URL.decode(publicKey),
                  let a = Base64URL.decode(authSecret) else { return nil }
            return WebPushKeys(privateKey: p, publicKey: q, authSecret: a)
        }
    }

    /// push-receiver checkCredentials(): credentials only count if made for this config.
    struct Config: Codable, Sendable, Equatable {
        var bundleId: String
        var projectId: String
        var vapidKey: String

        static let current = Config(bundleId: RingPushConstants.bundleId,
                                    projectId: RingPushConstants.firebaseProjectId,
                                    vapidKey: RingPushConstants.vapidKey)
    }

    var gcm: GCM
    var fcm: FCM
    var keys: Keys
    var config: Config
    /// The FCM token Ring last accepted, so we know when to PATCH again.
    var tokenRegisteredWithRing: String?

    var isUsable: Bool {
        config == .current && !gcm.androidId.isEmpty && !gcm.securityToken.isEmpty
            && !fcm.token.isEmpty && keys.webPushKeys != nil
    }
}

// MARK: - Keychain storage (KeychainManager's generic secret API)

enum PushCredentialStore {
    static let credentialsKey = "ring_push_credentials"
    static let persistentIdsKey = "ring_push_persistent_ids"

    static func loadCredentials() async -> PushCredentials? {
        guard let json = try? await KeychainManager.shared.secret(for: credentialsKey),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PushCredentials.self, from: data)
    }

    static func saveCredentials(_ credentials: PushCredentials) async throws {
        let data = try JSONEncoder().encode(credentials)
        try await KeychainManager.shared.saveSecret(String(decoding: data, as: UTF8.self), for: credentialsKey)
    }

    static func deleteCredentials() async {
        try? await KeychainManager.shared.deleteSecret(for: credentialsKey)
        try? await KeychainManager.shared.deleteSecret(for: persistentIdsKey)
    }

    static func loadPersistentIds() async -> PersistentIdState {
        guard let json = try? await KeychainManager.shared.secret(for: persistentIdsKey),
              let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(PersistentIdState.self, from: data) else {
            return PersistentIdState()
        }
        return state
    }

    static func savePersistentIds(_ state: PersistentIdState) async {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? await KeychainManager.shared.saveSecret(String(decoding: data, as: UTF8.self), for: persistentIdsKey)
    }
}

/// Persistent ids, handled as push-receiver does: every received id is sent
/// back in the next LoginRequest's `received_persistent_id` (that is the ack),
/// and cleared once a LoginResponse arrives. We also keep a bounded list of
/// recent ids to drop redeliveries, which push-receiver does with its
/// ever-growing `persistentIds` array.
struct PersistentIdState: Codable, Sendable, Equatable {
    static let recentLimit = 200

    var pendingAck: [String] = []
    var recent: [String] = []

    func hasSeen(_ id: String) -> Bool { recent.contains(id) }

    mutating func record(_ id: String) {
        if !pendingAck.contains(id) { pendingAck.append(id) }
        recent.removeAll { $0 == id }
        recent.append(id)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
        // The server only needs the ack once; cap it so a long outage can't bloat the login.
        if pendingAck.count > Self.recentLimit { pendingAck.removeFirst(pendingAck.count - Self.recentLimit) }
    }

    /// The server has the ids we sent in the login; forget those (and only those).
    mutating func loginAcknowledged(sent: [String]) {
        let sentSet = Set(sent)
        pendingAck.removeAll { sentSet.contains($0) }
    }
}
