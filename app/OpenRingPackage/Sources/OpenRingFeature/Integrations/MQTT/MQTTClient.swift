import Foundation
import Network
import CryptoKit

/// A small MQTT 3.1.1 client on Network.framework. Enough for Doorstep to publish to the
/// user's own broker: CONNECT with a retained last will, PUBLISH at QoS 0 or 1, SUBSCRIBE
/// at QoS 0, keep-alive pings, and reconnecting with backoff. No third-party code.
public actor MQTTClient {

    public enum TLSMode: Sendable, Equatable {
        case none
        /// Normal certificate checks.
        case system
        /// Accepts a certificate the system doesn't trust (home brokers often use their own).
        /// With a pin, only that exact certificate is accepted; with none, the first one seen is
        /// accepted and reported through `onCertificate` so the caller can pin it.
        case selfSigned(pinnedSHA256: String?)
    }

    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        public var clientId: String
        public var username: String?
        public var password: String?
        public var keepAlive: UInt16
        public var cleanSession: Bool
        public var will: MQTTPacket.Will?
        public var tls: TLSMode

        public init(host: String, port: UInt16 = 1883, clientId: String, username: String? = nil,
                    password: String? = nil, keepAlive: UInt16 = 60, cleanSession: Bool = true,
                    will: MQTTPacket.Will? = nil, tls: TLSMode = .none) {
            self.host = host; self.port = port; self.clientId = clientId; self.username = username
            self.password = password; self.keepAlive = keepAlive; self.cleanSession = cleanSession
            self.will = will; self.tls = tls
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case retrying(inSeconds: Int, reason: String)
        case failed(String)
    }

    public enum ClientError: Error, Equatable, Sendable {
        case notConnected
        case timedOut
        case connectionLost
    }

    public typealias StateHandler = @Sendable (State) async -> Void
    public typealias MessageHandler = @Sendable (String, [UInt8]) async -> Void
    public typealias CertificateHandler = @Sendable (String) async -> Void

    public let config: Configuration
    public private(set) var state: State = .idle

    private var onState: StateHandler?
    private var onMessage: MessageHandler?
    private var onCertificate: CertificateHandler?

    private var connection: NWConnection?
    private var generation = 0                // bumps per socket, so late callbacks from an old one are ignored
    private var wanted = false                // the user asked to be connected
    private var attempt = 0
    private var buffer: [UInt8] = []
    private var nextId: UInt16 = 0
    private var subscriptions: [String] = []
    private var pendingAcks: [UInt16: CheckedContinuation<Void, Error>] = [:]
    private var awaitingPong = false
    private var pingTask: Task<Void, Never>?
    private var connackTimeout: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "doorstep.mqtt")

    public init(config: Configuration) { self.config = config }

    public func setHandlers(onState: StateHandler?, onMessage: MessageHandler?, onCertificate: CertificateHandler? = nil) {
        self.onState = onState; self.onMessage = onMessage; self.onCertificate = onCertificate
    }

    // MARK: Public

    /// Connects, and keeps reconnecting until `stop()`.
    public func start() {
        guard !wanted else { return }
        wanted = true
        attempt = 0
        open()
    }

    /// Says goodbye properly (so the broker does not send the last will) and stays down.
    public func stop() async {
        wanted = false
        retryTask?.cancel(); retryTask = nil
        if state == .connected, let c = connection {
            try? await send(MQTTPacket.disconnect, on: c)
        }
        teardown(error: .connectionLost)
        setState(.idle)
    }

    /// Adds a QoS 0 subscription, sent now if connected and again after every reconnect.
    public func subscribe(_ topic: String) async throws {
        if !subscriptions.contains(topic) { subscriptions.append(topic) }
        guard state == .connected, let c = connection else { return }
        try await send(MQTTPacket.subscribe(packetId: packetId(), topics: [topic]), on: c)
    }

    /// QoS 0 returns once the bytes are handed to the network; QoS 1 waits for the PUBACK.
    public func publish(_ topic: String, _ payload: [UInt8], qos: UInt8 = 0, retain: Bool = false) async throws {
        guard state == .connected, let c = connection else { throw ClientError.notConnected }
        if qos == 0 {
            try await send(MQTTPacket.publish(topic: topic, payload: payload, qos: 0, retain: retain, packetId: nil), on: c)
            return
        }
        let id = packetId()
        let bytes = try MQTTPacket.publish(topic: topic, payload: payload, qos: 1, retain: retain, packetId: id)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingAcks[id] = cont
            Task {
                do { try await self.send(bytes, on: c) } catch { self.failAck(id, error) }
            }
            Task {
                try? await Task.sleep(for: .seconds(15))
                self.failAck(id, ClientError.timedOut)
            }
        }
    }

    public func publish(_ topic: String, _ text: String, qos: UInt8 = 0, retain: Bool = false) async throws {
        try await publish(topic, Array(text.utf8), qos: qos, retain: retain)
    }

    // MARK: Connection

    private func open() {
        teardown(error: .connectionLost)
        generation += 1
        let gen = generation
        setState(.connecting)

        let params: NWParameters
        switch config.tls {
        case .none:
            params = .tcp
        case .system:
            params = NWParameters(tls: NWProtocolTLS.Options(), tcp: .init())
        case .selfSigned(let pin):
            let tls = NWProtocolTLS.Options()
            let report = onCertificate
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                if SecTrustEvaluateWithError(secTrust, nil) { complete(true); return }
                guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                      let leaf = chain.first else { complete(false); return }
                let fp = MQTTClient.fingerprint(SecCertificateCopyData(leaf) as Data)
                if let pin {
                    complete(fp == pin)
                } else {
                    if let report { Task { await report(fp) } }
                    complete(true)
                }
            }, queue)
            params = NWParameters(tls: tls, tcp: .init())
        }
        let port = NWEndpoint.Port(rawValue: config.port) ?? 1883
        let c = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: params)
        connection = c
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            Task { await self.socketState(s, gen: gen) }
        }
        c.start(queue: queue)
    }

    private func socketState(_ s: NWConnection.State, gen: Int) async {
        guard gen == generation, let c = connection else { return }
        switch s {
        case .ready:
            do {
                let pkt = try MQTTPacket.connect(clientId: config.clientId, username: config.username,
                                                 password: config.password, keepAlive: config.keepAlive,
                                                 cleanSession: config.cleanSession, will: config.will)
                receive(on: c, gen: gen)
                try await send(pkt, on: c)
                connackTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    await self?.lost(gen: gen, reason: "No answer from the broker")
                }
            } catch {
                lost(gen: gen, reason: "Could not send the login")
            }
        case .waiting(let e):
            lost(gen: gen, reason: Self.describe(e))
        case .failed(let e):
            lost(gen: gen, reason: Self.describe(e))
        case .cancelled:
            lost(gen: gen, reason: "Connection closed")
        default:
            break
        }
    }

    private func receive(on c: NWConnection, gen: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let bytes = data.map { [UInt8]($0) }
            Task { await self.received(bytes, done: isComplete || error != nil, on: c, gen: gen) }
        }
    }

    private func received(_ bytes: [UInt8]?, done: Bool, on c: NWConnection, gen: Int) async {
        guard gen == generation else { return }
        if let bytes { buffer += bytes }
        let packets: [MQTTPacket.Incoming]
        do { packets = try MQTTPacket.parse(&buffer) } catch {
            lost(gen: gen, reason: "The broker sent something unreadable"); return
        }
        for p in packets {
            guard gen == generation else { return }
            await handle(p, on: c, gen: gen)
        }
        if done { lost(gen: gen, reason: "The broker closed the connection"); return }
        if gen == generation { receive(on: c, gen: gen) }
    }

    private func handle(_ p: MQTTPacket.Incoming, on c: NWConnection, gen: Int) async {
        switch p {
        case .connack(_, let rc):
            connackTimeout?.cancel(); connackTimeout = nil
            guard rc == 0 else {
                let reason = MQTTPacket.connackReason(rc)
                if rc == 4 || rc == 5 || rc == 2 {
                    // Retrying won't fix a wrong password; wait for the user.
                    wanted = false
                    teardown(error: .connectionLost)
                    setState(.failed(reason))
                } else {
                    lost(gen: gen, reason: reason)
                }
                return
            }
            attempt = 0
            if !subscriptions.isEmpty {
                try? await send(MQTTPacket.subscribe(packetId: packetId(), topics: subscriptions), on: c)
            }
            startPinging(gen: gen)
            setState(.connected)
        case .publish(let topic, let payload, let qos, _, let pid):
            if qos > 0, let pid { try? await send(MQTTPacket.puback(packetId: pid), on: c) }
            await onMessage?(topic, payload)
        case .puback(let id):
            pendingAcks.removeValue(forKey: id)?.resume()
        case .pingresp:
            awaitingPong = false
        case .suback, .other:
            break
        }
    }

    private func startPinging(gen: Int) {
        pingTask?.cancel()
        awaitingPong = false
        let interval = max(5, Double(config.keepAlive) * 0.75)
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.ping(gen: gen)
            }
        }
    }

    private func ping(gen: Int) async {
        guard gen == generation, let c = connection else { return }
        if awaitingPong { lost(gen: gen, reason: "The broker stopped answering"); return }
        awaitingPong = true
        try? await send(MQTTPacket.pingreq, on: c)
    }

    /// The socket is gone. Tidy up and, if still wanted, try again later.
    private func lost(gen: Int, reason: String) {
        guard gen == generation else { return }
        teardown(error: .connectionLost)
        guard wanted else { setState(.idle); return }
        attempt += 1
        let delay = min(60, 1 << min(attempt, 6))     // 2, 4, 8 ... 60 seconds
        setState(.retrying(inSeconds: delay, reason: reason))
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(delay) + Double.random(in: 0...1)))
            guard !Task.isCancelled else { return }
            await self?.retry()
        }
    }

    private func retry() { if wanted { open() } }

    private func teardown(error: ClientError) {
        generation += 1
        pingTask?.cancel(); pingTask = nil
        connackTimeout?.cancel(); connackTimeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        let waiting = pendingAcks
        pendingAcks.removeAll()
        for (_, cont) in waiting { cont.resume(throwing: error) }
    }

    // MARK: Helpers

    private func failAck(_ id: UInt16, _ error: Error) {
        pendingAcks.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func packetId() -> UInt16 {
        nextId = nextId == UInt16.max ? 1 : nextId + 1
        return nextId
    }

    private func setState(_ s: State) {
        guard s != state else { return }
        state = s
        if let h = onState { Task { await h(s) } }
    }

    private func send(_ bytes: [UInt8], on c: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    nonisolated static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func describe(_ e: NWError) -> String {
        switch e {
        case .posix(let code) where code == .ECONNREFUSED: return "Nothing is listening on that port"
        case .posix(let code) where code == .ETIMEDOUT: return "The broker did not answer"
        case .dns: return "Could not find that host"
        case .tls: return "The secure connection failed (certificate?)"
        default: return e.localizedDescription
        }
    }
}
