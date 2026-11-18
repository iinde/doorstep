import Foundation
import os

/// Instant Ring doorbell / motion events over Firebase Cloud Messaging.
///
/// A native port of what dgreif/ring (ring-client-api) does with
/// @eneris/push-receiver: register as a push client with Ring's Android
/// Firebase project, give Ring the FCM token (PATCH clients_api/device), then
/// hold an MCS connection to mtalk.google.com:5228 and decrypt what arrives.
///
/// Everything fails soft: errors are logged (never tokens or payloads) and the
/// actor keeps retrying with backoff, so the app can carry on polling meanwhile.
public actor RingPush {
    public static let shared = RingPush()

    /// True while the MCS connection is logged in and able to receive pushes.
    public private(set) var isConnected = false

    private static let log = Logger(subsystem: "dev.open-ring", category: "RingPush")

    private let registrar = FCMRegistrar()
    private var onEvent: (@Sendable (RingPushEvent) -> Void)?
    private var runTask: Task<Void, Never>?
    private var ringTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    private var credentials: PushCredentials?
    private var ids = PersistentIdState()
    private var lastCheckin: Date?

    // Per-connection state (push-receiver client.ts).
    private var connection: MCSConnection?
    private var streamId: Int32 = 0
    private var lastStreamIdReported: Int32 = -1
    private var lastReceived = Date()
    private var pingSentSinceLastReceive = false
    private var sentLoginIds: [String] = []
    private var loggedIn = false
    private var consecutiveLoginErrors = 0

    private let heartbeatInterval = TimeInterval(RingPushConstants.heartbeatIntervalMs) / 1000
    private let ringReRegisterInterval: TimeInterval = 12 * 60 * 60
    private let checkinInterval: TimeInterval = 12 * 60 * 60

    public init() {}

    // MARK: - Public API

    /// Starts receiving. Safe to call again: the handler is replaced, the connection kept.
    public func start(onEvent: @escaping @Sendable (RingPushEvent) -> Void) async {
        self.onEvent = onEvent
        guard runTask == nil else { return }
        Self.log.info("Ring push starting")
        runTask = Task { [weak self] in await self?.runLoop() }
    }

    public func stop() async {
        runTask?.cancel()
        ringTask?.cancel()
        heartbeatTask?.cancel()
        runTask = nil
        ringTask = nil
        heartbeatTask = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        loggedIn = false
        Self.log.info("Ring push stopped")
    }

    /// Forgets the push registration (e.g. on sign-out). The next start registers afresh.
    public func resetRegistration() async {
        await stop()
        credentials = nil
        ids = PersistentIdState()
        await PushCredentialStore.deleteCredentials()
    }

    // MARK: - Main loop

    private func runLoop() async {
        var failures = 0
        while !Task.isCancelled {
            var delay: TimeInterval
            do {
                try await prepareCredentials()
                startRingRegistrationIfNeeded()
                let hadLogin = await connectAndServe()
                if hadLogin { failures = 0 }
                failures += 1
                // push-receiver #socketRetry: min(retryCount, 15) seconds. We go a bit further when it keeps failing.
                delay = failures <= 15 ? Double(failures) : min(Double(failures) * 4, 120)
            } catch is CancellationError {
                break
            } catch {
                failures += 1
                // Registration with Google failed: back off harder, up to 30 minutes.
                delay = min(pow(2, Double(failures)) * 15, 30 * 60)
                Self.log.error("Push registration failed (\(String(describing: error), privacy: .public)); retry in \(Int(delay))s")
            }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// client.ts registerIfNeeded(): reuse saved credentials (check in again and
    /// refresh the Firebase installation token if it's expired), or register anew.
    private func prepareCredentials() async throws {
        if credentials == nil {
            credentials = await PushCredentialStore.loadCredentials()
            ids = await PushCredentialStore.loadPersistentIds()
        }

        if var c = credentials, c.isUsable {
            if lastCheckin.map({ Date().timeIntervalSince($0) > checkinInterval }) ?? true {
                do {
                    try await registrar.checkIn(existing: c.gcm)
                    lastCheckin = Date()
                } catch {
                    Self.log.warning("Checkin failed, connecting anyway: \(String(describing: error), privacy: .public)")
                }
            }
            if c.fcm.installation.isExpired() {
                do {
                    c.fcm.installation = try await registrar.refreshInstallation(c.fcm.installation)
                    credentials = c
                    try? await PushCredentialStore.saveCredentials(c)
                } catch {
                    // Not needed for receiving; keep going (push-receiver does the same).
                    Self.log.warning("Installation token refresh failed: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }

        Self.log.info("No usable push credentials; registering")
        let fresh = try await registrar.register()
        credentials = fresh
        ids = PersistentIdState()
        lastCheckin = Date()
        try? await PushCredentialStore.saveCredentials(fresh)
        await PushCredentialStore.savePersistentIds(ids)
    }

    // MARK: - Ring token registration (dgreif/ring api.ts)

    private func startRingRegistrationIfNeeded() {
        guard ringTask == nil else { return }
        ringTask = Task { [weak self] in await self?.ringRegistrationLoop() }
    }

    /// PATCH the FCM token to Ring now, again every 12 hours (dgreif re-sends on
    /// every new Ring session), and again whenever the token changes.
    private func ringRegistrationLoop() async {
        var failures = 0
        var lastSent: (token: String, at: Date)?
        while !Task.isCancelled {
            guard let token = credentials?.fcm.token else {
                try? await Task.sleep(for: .seconds(30))
                continue
            }
            let due = lastSent == nil || lastSent?.token != token
                || Date().timeIntervalSince(lastSent!.at) > ringReRegisterInterval
            if due {
                do {
                    try await Self.registerTokenWithRing(token)
                    lastSent = (token, Date())
                    failures = 0
                    if var c = credentials, c.fcm.token == token, c.tokenRegisteredWithRing != token {
                        c.tokenRegisteredWithRing = token
                        credentials = c
                        try? await PushCredentialStore.saveCredentials(c)
                    }
                    Self.log.info("Push token registered with Ring")
                } catch is CancellationError {
                    return
                } catch {
                    failures += 1
                    let wait = min(pow(2, Double(failures)) * 30, 30 * 60)
                    Self.log.warning("Ring push token registration failed (\(String(describing: error), privacy: .public)); retry in \(Int(wait))s")
                    try? await Task.sleep(for: .seconds(wait))
                    continue
                }
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// The body dgreif/ring api.ts sends to PATCH clients_api/device.
    static func ringDeviceBody(token: String) -> Data {
        let body: [String: Any] = [
            "device": [
                "metadata": [
                    "api_version": RingPushConstants.ringAPIVersion,
                    "device_model": RingPushConstants.ringDeviceModel,
                    "pn_dict_version": "2.0.0",
                    "pn_service": "fcm",
                ],
                "os": "android",
                "push_notification_token": token,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// rest-client.ts fetchNewSession(): POST clients_api/session.
    static func ringSessionBody(hardwareId: String) -> Data {
        let body: [String: Any] = [
            "device": [
                "hardware_id": hardwareId,
                "metadata": [
                    "api_version": RingPushConstants.ringAPIVersion,
                    "device_model": RingPushConstants.ringDeviceModel,
                ],
                "os": "android",
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    private static func registerTokenWithRing(_ token: String) async throws {
        let ring = RingClient.shared
        var status = try await ring.clientsAPIStatus(path: "device", method: "PATCH", jsonBody: ringDeviceBody(token: token))
        if status == 404 {
            // rest-client.ts: a 404 means Ring has no session for this hardware_id. Create one, then retry.
            let hardwareId = try await KeychainManager.shared.getHardwareId()
            let created = try await ring.clientsAPIStatus(path: "session", method: "POST",
                                                          jsonBody: ringSessionBody(hardwareId: hardwareId))
            guard (200..<300).contains(created) else { throw RingAPIError.serverError(created) }
            status = try await ring.clientsAPIStatus(path: "device", method: "PATCH", jsonBody: ringDeviceBody(token: token))
        }
        guard (200..<300).contains(status) else {
            if status == 401 { throw RingAPIError.unauthorized }
            throw RingAPIError.serverError(status)
        }
    }

    // MARK: - MCS connection

    /// Runs one connection until it closes. Returns whether it got as far as a login.
    private func connectAndServe() async -> Bool {
        guard let creds = credentials else { return false }
        let conn = MCSConnection()
        connection = conn
        streamId = 0
        lastStreamIdReported = -1
        loggedIn = false
        lastReceived = Date()
        pingSentSinceLastReceive = false
        conn.start()

        var hadLogin = false
        for await event in conn.events {
            if Task.isCancelled { conn.cancel(); break }
            switch event {
            case .ready:
                await sendLogin(conn, creds)
                startHeartbeat(conn)
            case .frame(let frame):
                await handle(frame, conn)
                if loggedIn { hadLogin = true }
            case .closed(let reason):
                Self.log.info("MCS connection closed: \(reason, privacy: .public)")
            }
        }

        heartbeatTask?.cancel()
        heartbeatTask = nil
        if connection === conn { connection = nil }
        isConnected = false
        loggedIn = false
        return hadLogin
    }

    private func sendLogin(_ conn: MCSConnection, _ creds: PushCredentials) async {
        sentLoginIds = ids.pendingAck
        let login = MCSLoginRequest.make(androidId: creds.gcm.androidId, securityToken: creds.gcm.securityToken,
                                         chromeVersion: RingPushConstants.chromeVersion,
                                         persistentIds: sentLoginIds,
                                         heartbeatIntervalMs: RingPushConstants.heartbeatIntervalMs)
        do {
            try await conn.send(MCSFrameEncoder.loginPacket(login))
            Self.log.debug("MCS login sent (acking \(self.sentLoginIds.count) ids)")
        } catch {
            Self.log.error("MCS login send failed: \(error.localizedDescription, privacy: .public)")
            conn.cancel()
        }
    }

    /// client.ts #startHeartbeat: ping after `interval` with nothing received,
    /// give up on the socket after 2 x interval of silence.
    private func startHeartbeat(_ conn: MCSConnection) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                await self.heartbeatTick(conn)
            }
        }
    }

    private func heartbeatTick(_ conn: MCSConnection) async {
        let silence = Date().timeIntervalSince(lastReceived)
        if silence >= heartbeatInterval * 2 {
            Self.log.warning("MCS heartbeat timed out; reconnecting")
            conn.cancel()
        } else if silence >= heartbeatInterval && !pingSentSinceLastReceive {
            pingSentSinceLastReceive = true
            let ping = MCSHeartbeat(lastStreamIdReceived: takeStreamIdIfNew())
            try? await conn.send(MCSFrameEncoder.frame(tag: .heartbeatPing, payload: ping.encode()))
        }
    }

    /// client.ts #getStreamId / #newStreamIdAvailable.
    private func takeStreamIdIfNew() -> Int32? {
        guard lastStreamIdReported != streamId else { return nil }
        lastStreamIdReported = streamId
        return streamId
    }

    private func handle(_ frame: MCSFrame, _ conn: MCSConnection) async {
        lastReceived = Date()
        pingSentSinceLastReceive = false

        guard let tag = frame.knownTag else {
            Self.log.debug("MCS unknown tag \(frame.tag), \(frame.payload.count) bytes")
            return
        }
        do {
            switch tag {
            case .loginResponse:
                let r = try MCSLoginResponse.decode(frame.payload)
                if let error = r.error {
                    consecutiveLoginErrors += 1
                    Self.log.error("MCS login rejected (code \(error.code))")
                    if consecutiveLoginErrors >= 3 {
                        // The checkin credentials are no good any more: register from scratch.
                        Self.log.error("Discarding push credentials after repeated login errors")
                        credentials = nil
                        await PushCredentialStore.deleteCredentials()
                        consecutiveLoginErrors = 0
                    }
                    conn.cancel()
                    return
                }
                consecutiveLoginErrors = 0
                ids.loginAcknowledged(sent: sentLoginIds)
                sentLoginIds = []
                await PushCredentialStore.savePersistentIds(ids)
                loggedIn = true
                isConnected = true
                Self.log.info("MCS connected")

            case .dataMessageStanza:
                let stanza = try MCSDataMessageStanza.decode(frame.payload)
                await handleData(stanza)

            case .heartbeatPing:
                let ping = try MCSHeartbeat.decode(frame.payload)
                var ack = MCSHeartbeat(lastStreamIdReceived: takeStreamIdIfNew())
                if let status = ping.status, status != 0 { ack.status = status }
                try? await conn.send(MCSFrameEncoder.frame(tag: .heartbeatAck, payload: ack.encode()))

            case .heartbeatAck:
                break

            case .close:
                Self.log.info("MCS server asked to close")
                conn.cancel()

            case .streamErrorStanza:
                let e = try MCSStreamError.decode(frame.payload)
                Self.log.error("MCS stream error: \(e.type, privacy: .public)")
                conn.cancel()

            case .iqStanza:
                let iq = try MCSIqStanza.decode(frame.payload)
                Self.log.debug("MCS IqStanza type \(iq.type) extension \(iq.extensionId ?? -1)")

            default:
                Self.log.debug("MCS tag \(tag.rawValue) ignored, \(frame.payload.count) bytes")
            }
        } catch {
            Self.log.error("MCS message (tag \(tag.rawValue)) did not decode: \(String(describing: error), privacy: .public)")
        }
        streamId &+= 1
    }

    private func handleData(_ stanza: MCSDataMessageStanza) async {
        if let pid = stanza.persistentId, ids.hasSeen(pid) { return }

        guard let keys = credentials?.keys.webPushKeys else { return }
        let plaintext: Data
        do {
            plaintext = try WebPushAESGCM.decrypt(stanza: stanza, keys: keys)
        } catch {
            // client.ts drops undecryptable messages (bad tag, missing crypto-key or salt).
            Self.log.debug("Push dropped, could not decrypt: \(String(describing: error), privacy: .public) (\(stanza.rawData?.count ?? 0) bytes)")
            await remember(stanza.persistentId)
            return
        }
        await remember(stanza.persistentId)

        switch RingPushParser.parse(decryptedMessage: plaintext) {
        case .event(let event):
            Self.log.info("Push event: \(event.kind.rawValue, privacy: .public) (\(plaintext.count) bytes)")
            onEvent?(event)
        case .ignored(let reason):
            Self.log.debug("Push ignored: \(reason, privacy: .public) (\(plaintext.count) bytes)")
        }
    }

    private func remember(_ persistentId: String?) async {
        guard let persistentId else { return }
        ids.record(persistentId)
        await PushCredentialStore.savePersistentIds(ids)
    }
}
