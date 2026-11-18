import Foundation
import RingClient

/// What Doorstep worked out about a moment at a camera.
public enum DoorstepEventKind: String, Codable, CaseIterable, Sendable {
    case doorbell, person, approaching, delivery, familiarFace, parcelLeft, parcelTaken, unusual, motion

    public init(_ trigger: DoorTrigger) {
        switch trigger {
        case .doorbell: self = .doorbell
        case .person: self = .person
        case .approaching: self = .approaching
        case .delivery: self = .delivery
        case .parcelLeft: self = .parcelLeft
        case .parcelTaken: self = .parcelTaken
        case .loitering: self = .person
        }
    }

    /// Whether this means someone is there, which turns the Person sensor on.
    var meansPerson: Bool {
        switch self {
        case .doorbell, .person, .approaching, .delivery, .familiarFace, .unusual: return true
        case .parcelLeft, .parcelTaken, .motion: return false
        }
    }
}

/// Saved connection details. The password lives in the Keychain, never here.
public struct MQTTBrokerSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var host = ""
    public var port = 1883
    public var username = ""
    public var useTLS = false
    public var trustSelfSigned = false
    /// SHA-256 of the broker's self-signed certificate, pinned the first time it is seen.
    public var pinnedCertificate: String?
    public var baseTopic = "doorstep"
    public var discoveryPrefix = "homeassistant"
    public init() {}

    static let defaultsKey = "mqttBrokerSettings"
    static let keychainKey = "mqtt_password"
}

/// Publishes Doorstep's events to the user's own MQTT broker so Home Assistant (or
/// Homebridge via an MQTT plugin) picks them up automatically through MQTT Discovery.
/// Off unless the user turns it on; never talks to anything except the broker they type in.
@MainActor
public final class HomeAssistantBridge: ObservableObject {
    public static let shared = HomeAssistantBridge()

    @Published public private(set) var status: String = "Not connected"
    @Published public private(set) var isConnected = false
    @Published public var settings: MQTTBrokerSettings { didSet { saveSettings() } }

    /// Home Assistant asked for a mode ("Home", "Away", "Night" or "Quiet").
    public var onModeCommand: ((String) -> Void)?

    private var client: MQTTClient?
    private var topics = HomeAssistantTopics()
    private var cameras: [String: HomeAssistantCamera] = [:]
    private var announced: Set<String> = []           // camera ids whose discovery went out this connection
    private var batteryAnnounced: Set<String> = []
    private var lastMode: String?
    private var lastParcelsDue: Int?
    private let clientId: String

    public init(settings: MQTTBrokerSettings? = nil) {
        if let settings {
            self.settings = settings
        } else if !DemoMode.isOn, let data = UserDefaults.standard.data(forKey: MQTTBrokerSettings.defaultsKey),
                  let saved = try? JSONDecoder().decode(MQTTBrokerSettings.self, from: data) {
            self.settings = saved
        } else {
            self.settings = MQTTBrokerSettings()
        }
        let key = "mqttClientId"
        if let id = UserDefaults.standard.string(forKey: key) {
            clientId = id
        } else {
            clientId = "doorstep-" + UUID().uuidString.prefix(8).lowercased()
            UserDefaults.standard.set(clientId, forKey: key)
        }
    }

    private func saveSettings() {
        guard !DemoMode.isOn, let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: MQTTBrokerSettings.defaultsKey)
    }

    // MARK: Connection

    /// Connects if the user switched this on before. Call once at launch.
    public func startIfEnabled() async {
        if settings.enabled { await connect() }
    }

    public func connect() async {
        guard !DemoMode.isOn else { status = "Not available in demo mode"; return }
        let host = settings.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { status = "Enter your broker's address"; return }
        guard let port = UInt16(exactly: settings.port), port > 0 else { status = "That port number is not valid"; return }
        await client?.stop()

        let password = (try? await KeychainManager.shared.secret(for: MQTTBrokerSettings.keychainKey)) ?? nil
        topics = HomeAssistantTopics(base: settings.baseTopic, discoveryPrefix: settings.discoveryPrefix)
        let tls: MQTTClient.TLSMode = !settings.useTLS ? .none
            : settings.trustSelfSigned ? .selfSigned(pinnedSHA256: settings.pinnedCertificate) : .system
        let user = settings.username.trimmingCharacters(in: .whitespaces)
        let config = MQTTClient.Configuration(
            host: host, port: port, clientId: clientId,
            username: user.isEmpty ? nil : user, password: password,
            keepAlive: 60, cleanSession: true,
            will: MQTTPacket.Will(topic: topics.availability, payload: Array("offline".utf8), qos: 1, retain: true),
            tls: tls)
        let c = MQTTClient(config: config)
        client = c
        settings.enabled = true
        await c.setHandlers(
            onState: { [weak self] _ in await self?.clientChanged(c) },
            onMessage: { [weak self] topic, payload in await self?.received(topic, payload, from: c) },
            onCertificate: { [weak self] fp in await self?.pin(fp) })
        try? await c.subscribe(topics.modeSet)
        try? await c.subscribe(topics.homeAssistantStatus)
        NSLog("🏠 MQTT: connecting to \(host):\(port)\(settings.useTLS ? " (TLS)" : "")")
        await c.start()
    }

    public func disconnect() async {
        settings.enabled = false
        guard let c = client else { status = "Not connected"; return }
        client = nil
        // Leave a clean "offline" behind, as the will would have.
        try? await c.publish(topics.availability, "offline", qos: 1, retain: true)
        await c.stop()
        isConnected = false
        status = "Not connected"
    }

    private func clientChanged(_ c: MQTTClient) async {
        guard c === client else { return }
        let state = await c.state         // read now: notifications may arrive out of order
        switch state {
        case .idle: status = "Not connected"; isConnected = false
        case .connecting: status = "Connecting…"; isConnected = false
        case .retrying(let s, let reason): status = "\(reason). Trying again in \(s) s"; isConnected = false
        case .failed(let reason): status = reason; isConnected = false; settings.enabled = false
        case .connected:
            isConnected = true
            status = "Connected to \(settings.host)"
            NSLog("🏠 MQTT: connected")
            await announceAll(c)
        }
    }

    private func received(_ topic: String, _ payload: [UInt8], from c: MQTTClient) async {
        guard c === client else { return }
        let text = String(decoding: payload.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if topic == topics.modeSet {
            guard let mode = HomeAssistantDiscovery.modeOptions.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else { return }
            NSLog("🏠 MQTT: Home Assistant asked for \(mode) mode")
            onModeCommand?(mode)
        } else if topic == topics.homeAssistantStatus, text == "online" {
            // Home Assistant restarted: send discovery again so nothing goes missing.
            await announceAll(c)
        }
    }

    private func pin(_ fingerprint: String) {
        guard settings.trustSelfSigned, settings.pinnedCertificate == nil else { return }
        settings.pinnedCertificate = fingerprint
        NSLog("🏠 MQTT: trusting the broker's own certificate from now on")
    }

    /// Forget the pinned certificate (for when the broker gets a new one).
    public func forgetCertificate() { settings.pinnedCertificate = nil }

    private func announceAll(_ c: MQTTClient) async {
        announced.removeAll(); batteryAnnounced.removeAll()
        await send(c, topics.availability, Array("online".utf8), qos: 1, retain: true)
        for m in HomeAssistantDiscovery.hubConfigs(topics) { await send(c, m.topic, m.payload, qos: 1, retain: true) }
        for cam in cameras.values { await announce(cam, on: c) }
        if let lastMode { await send(c, topics.mode, Array(lastMode.utf8), qos: 1, retain: true) }
        if let lastParcelsDue { await send(c, topics.parcelsDue, Array(String(lastParcelsDue).utf8), qos: 1, retain: true) }
    }

    private func announce(_ cam: HomeAssistantCamera, on c: MQTTClient) async {
        for m in HomeAssistantDiscovery.cameraConfigs(topics, cam) { await send(c, m.topic, m.payload, qos: 1, retain: true) }
        announced.insert(cam.id)
        if cam.hasBattery { batteryAnnounced.insert(cam.id) }
    }

    private func send(_ c: MQTTClient, _ topic: String, _ payload: [UInt8], qos: UInt8, retain: Bool) async {
        do { try await c.publish(topic, payload, qos: qos, retain: retain) } catch {
            // Payloads are never logged: they can hold snapshots.
            if case MQTTClient.ClientError.notConnected = error { return }
            NSLog("🏠 MQTT: publish to \(topic) failed (\(error))")
        }
    }

    // MARK: Cameras

    /// Tell the bridge which cameras exist, so each appears in Home Assistant straight away.
    public func setCameras(_ devices: [RingDevice]) async {
        for d in devices where d.deviceType != .chime {
            await register(HomeAssistantCamera(id: String(d.id), name: d.name, hasBattery: d.batteryLevel != nil,
                                               model: d.kind))
        }
    }

    public func register(_ cam: HomeAssistantCamera) async {
        let old = cameras[cam.id]
        cameras[cam.id] = cam
        guard let c = client, isConnected, old != cam || !announced.contains(cam.id) else { return }
        await announce(cam, on: c)
    }

    // MARK: Publishing

    /// Something happened at a camera. `who` is a courier or familiar face by name, if known.
    public func publishEvent(cameraId: String, cameraName: String, kind: DoorstepEventKind,
                             who: String? = nil, description: String? = nil, snapshotJPEG: Data? = nil,
                             at time: Date = Date()) async {
        if cameras[cameraId] == nil {
            await register(HomeAssistantCamera(id: cameraId, name: cameraName))
        }
        guard let c = client, isConnected else { return }
        if kind.meansPerson { await send(c, topics.camera(cameraId, "person"), Array("ON".utf8), qos: 0, retain: false) }
        if kind == .doorbell { await send(c, topics.camera(cameraId, "doorbell"), Array("ON".utf8), qos: 0, retain: false) }
        switch kind {
        case .parcelLeft: await send(c, topics.camera(cameraId, "parcel"), Array("left".utf8), qos: 1, retain: true)
        case .parcelTaken: await send(c, topics.camera(cameraId, "parcel"), Array("taken".utf8), qos: 1, retain: true)
        default: break
        }
        if let who = who?.trimmingCharacters(in: .whitespacesAndNewlines), !who.isEmpty {
            await send(c, topics.camera(cameraId, "last_visitor"), Array(String(who.prefix(255)).utf8), qos: 1, retain: true)
        }
        let stamp = Self.iso.string(from: time)
        var attrs: [String: Any] = ["kind": kind.rawValue, "camera": cameraName, "time": stamp]
        if let who, !who.isEmpty { attrs["who"] = who }
        if let description, !description.isEmpty { attrs["description"] = String(description.prefix(1000)) }
        if let json = try? JSONSerialization.data(withJSONObject: attrs, options: [.sortedKeys]) {
            await send(c, topics.camera(cameraId, "event"), [UInt8](json), qos: 1, retain: true)
        }
        await send(c, topics.camera(cameraId, "last_event"), Array(stamp.utf8), qos: 1, retain: true)
        if let jpeg = snapshotJPEG, !jpeg.isEmpty, jpeg.count < 4_000_000 {
            await send(c, topics.camera(cameraId, "snapshot"), [UInt8](jpeg), qos: 0, retain: true)
        }
    }

    /// Convenience for the triggers Automations already uses.
    public func publishEvent(cameraId: Int, cameraName: String, trigger: DoorTrigger, who: String? = nil,
                             description: String? = nil, snapshotJPEG: Data? = nil) async {
        await publishEvent(cameraId: String(cameraId), cameraName: cameraName, kind: DoorstepEventKind(trigger),
                           who: who, description: description, snapshotJPEG: snapshotJPEG)
    }

    public func publishMode(_ mode: String) async {
        guard HomeAssistantDiscovery.modeOptions.contains(mode) else { return }
        lastMode = mode
        guard let c = client, isConnected else { return }
        await send(c, topics.mode, Array(mode.utf8), qos: 1, retain: true)
    }

    public func publishMode(_ mode: Modes.Mode) async { await publishMode(mode.rawValue) }

    public func publishBattery(cameraId: String, percent: Int) async {
        let p = max(0, min(100, percent))
        if var cam = cameras[cameraId], !cam.hasBattery {
            cam.hasBattery = true
            cameras[cameraId] = cam
        }
        guard let c = client, isConnected else { return }
        if let cam = cameras[cameraId], !batteryAnnounced.contains(cameraId) {
            let m = HomeAssistantDiscovery.batteryConfig(topics, cam)
            await send(c, m.topic, m.payload, qos: 1, retain: true)
            batteryAnnounced.insert(cameraId)
        }
        await send(c, topics.camera(cameraId, "battery"), Array(String(p).utf8), qos: 1, retain: true)
    }

    public func publishParcelsDue(_ count: Int) async {
        lastParcelsDue = max(0, count)
        guard let c = client, isConnected else { return }
        await send(c, topics.parcelsDue, Array(String(max(0, count)).utf8), qos: 1, retain: true)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
