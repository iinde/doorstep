import Testing
import Foundation
import Network
@testable import OpenRingFeature

@Suite struct MQTTPacketTests {
    @Test func remainingLengthBoundaries() throws {
        #expect(try MQTTPacket.encodeRemainingLength(0) == [0x00])
        #expect(try MQTTPacket.encodeRemainingLength(127) == [0x7F])
        #expect(try MQTTPacket.encodeRemainingLength(128) == [0x80, 0x01])
        #expect(try MQTTPacket.encodeRemainingLength(16_383) == [0xFF, 0x7F])
        #expect(try MQTTPacket.encodeRemainingLength(16_384) == [0x80, 0x80, 0x01])
        #expect(try MQTTPacket.encodeRemainingLength(2_097_151) == [0xFF, 0xFF, 0x7F])
        #expect(try MQTTPacket.encodeRemainingLength(2_097_152) == [0x80, 0x80, 0x80, 0x01])
        #expect(try MQTTPacket.encodeRemainingLength(268_435_455) == [0xFF, 0xFF, 0xFF, 0x7F])
        #expect(throws: MQTTPacket.PacketError.self) { try MQTTPacket.encodeRemainingLength(268_435_456) }
        #expect(throws: MQTTPacket.PacketError.self) { try MQTTPacket.encodeRemainingLength(-1) }
    }

    @Test func remainingLengthRoundTrips() throws {
        for n in [0, 1, 127, 128, 300, 16_383, 16_384, 2_097_151, 2_097_152, 268_435_455] {
            let enc = try MQTTPacket.encodeRemainingLength(n)
            let dec = try #require(try MQTTPacket.decodeRemainingLength(enc, at: 0))
            #expect(dec.value == n)
            #expect(dec.byteCount == enc.count)
        }
        // Incomplete: needs more bytes.
        #expect(try MQTTPacket.decodeRemainingLength([0x80], at: 0) == nil)
        // Five continuation bytes is malformed.
        #expect(throws: MQTTPacket.PacketError.self) { try MQTTPacket.decodeRemainingLength([0x80, 0x80, 0x80, 0x80, 0x01], at: 0) }
    }

    @Test func connectWithCredentialsAndWill() throws {
        let will = MQTTPacket.Will(topic: "d/s", payload: Array("offline".utf8), qos: 1, retain: true)
        let bytes = try MQTTPacket.connect(clientId: "abc", username: "u", password: "p",
                                           keepAlive: 60, cleanSession: true, will: will)
        var expected: [UInt8] = [0x10, 35, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04]
        expected.append(0xEE)                              // user, pass, will retain, will QoS 1, will, clean
        expected += [0x00, 0x3C]                           // keep-alive 60
        expected += [0x00, 0x03, 0x61, 0x62, 0x63]         // "abc"
        expected += [0x00, 0x03, 0x64, 0x2F, 0x73]         // "d/s"
        expected += [0x00, 0x07]
        expected += Array("offline".utf8)
        expected += [0x00, 0x01, 0x75]                     // "u"
        expected += [0x00, 0x01, 0x70]                     // "p"
        #expect(bytes == expected)
    }

    @Test func connectWithoutCredentials() throws {
        let bytes = try MQTTPacket.connect(clientId: "x", username: nil, password: "ignored",
                                           keepAlive: 30, cleanSession: true, will: nil)
        #expect(bytes == [0x10, 13, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x1E, 0x00, 0x01, 0x78])
    }

    @Test func publishQoS0Retained() throws {
        let bytes = try MQTTPacket.publish(topic: "a/b", payload: Array("hi".utf8), qos: 0, retain: true, packetId: nil)
        #expect(bytes == [0x31, 0x07, 0x00, 0x03, 0x61, 0x2F, 0x62, 0x68, 0x69])
    }

    @Test func publishQoS1() throws {
        let bytes = try MQTTPacket.publish(topic: "a/b", payload: Array("hi".utf8), qos: 1, retain: false, packetId: 10)
        #expect(bytes == [0x32, 0x09, 0x00, 0x03, 0x61, 0x2F, 0x62, 0x00, 0x0A, 0x68, 0x69])
        #expect(throws: MQTTPacket.PacketError.self) {
            try MQTTPacket.publish(topic: "a", payload: [], qos: 1, retain: false, packetId: nil)
        }
    }

    @Test func largePublishUsesMultiByteLength() throws {
        let payload = [UInt8](repeating: 0xAB, count: 200_000)
        let bytes = try MQTTPacket.publish(topic: "t", payload: payload, qos: 0, retain: false, packetId: nil)
        #expect(Array(bytes[1...3]) == (try MQTTPacket.encodeRemainingLength(3 + 200_000)))
        #expect(bytes.count == 1 + 3 + 3 + 200_000)
    }

    @Test func subscribeAndSmallPackets() throws {
        #expect(try MQTTPacket.subscribe(packetId: 1, topics: ["m/s"]) == [0x82, 0x08, 0x00, 0x01, 0x00, 0x03, 0x6D, 0x2F, 0x73, 0x00])
        #expect(MQTTPacket.puback(packetId: 0x0102) == [0x40, 0x02, 0x01, 0x02])
        #expect(MQTTPacket.pingreq == [0xC0, 0x00])
        #expect(MQTTPacket.disconnect == [0xE0, 0x00])
    }

    @Test func parsesIncomingAndKeepsPartial() throws {
        var buf: [UInt8] = [0x20, 0x02, 0x00, 0x00,          // CONNACK ok
                            0x40, 0x02, 0x00, 0x07,          // PUBACK 7
                            0xD0, 0x00,                      // PINGRESP
                            0x30, 0x06, 0x00, 0x01, 0x6D, 0x48, 0x6F, 0x6D,  // PUBLISH m "Hom"
                            0x30, 0x09, 0x00]                // partial
        let out = try MQTTPacket.parse(&buf)
        #expect(out == [.connack(sessionPresent: false, returnCode: 0), .puback(packetId: 7), .pingresp,
                        .publish(topic: "m", payload: Array("Hom".utf8), qos: 0, retain: false, packetId: nil)])
        #expect(buf == [0x30, 0x09, 0x00])
    }
}

@Suite struct HomeAssistantDiscoveryTests {
    func json(_ m: HomeAssistantDiscovery.Message) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(m.payload)) as? [String: Any])
    }

    @Test func cameraEntities() throws {
        let t = HomeAssistantTopics()
        let cam = HomeAssistantCamera(id: "12345", name: "Front Door", hasBattery: true, model: "doorbell_v4")
        let msgs = HomeAssistantDiscovery.cameraConfigs(t, cam)
        #expect(msgs.map(\.topic) == [
            "homeassistant/binary_sensor/doorstep_12345/person/config",
            "homeassistant/binary_sensor/doorstep_12345/doorbell/config",
            "homeassistant/sensor/doorstep_12345/last_visitor/config",
            "homeassistant/sensor/doorstep_12345/last_event/config",
            "homeassistant/sensor/doorstep_12345/parcel/config",
            "homeassistant/image/doorstep_12345/snapshot/config",
            "homeassistant/sensor/doorstep_12345/battery/config",
        ])
        let all = try msgs.map(json)
        let ids = all.compactMap { $0["unique_id"] as? String }
        #expect(Set(ids).count == msgs.count)
        for c in all {
            #expect(c["availability_topic"] as? String == "doorstep/status")
            let dev = try #require(c["device"] as? [String: Any])
            #expect(dev["manufacturer"] as? String == "Ring (via Doorstep)")
            #expect(dev["identifiers"] as? [String] == ["doorstep_12345"])
            #expect(dev["name"] as? String == "Front Door")
            #expect(dev["via_device"] as? String == "doorstep_hub")
        }
        let person = all[0]
        #expect(person["unique_id"] as? String == "doorstep_12345_person")
        #expect(person["state_topic"] as? String == "doorstep/camera/12345/person")
        #expect(person["device_class"] as? String == "occupancy")
        #expect(all[1]["off_delay"] as? Int == 30)
        #expect(all[3]["device_class"] as? String == "timestamp")
        #expect(all[3]["json_attributes_topic"] as? String == "doorstep/camera/12345/event")
        #expect(all[4]["options"] as? [String] == ["none", "left", "taken"])
        #expect(all[5]["image_topic"] as? String == "doorstep/camera/12345/snapshot")
        #expect(all[5]["content_type"] as? String == "image/jpeg")
        #expect(all[6]["unit_of_measurement"] as? String == "%")
        #expect(all[6]["device_class"] as? String == "battery")
    }

    @Test func noBatteryEntityForWiredCamera() {
        let msgs = HomeAssistantDiscovery.cameraConfigs(HomeAssistantTopics(), HomeAssistantCamera(id: "9", name: "Garden"))
        #expect(!msgs.contains { $0.topic.contains("battery") })
        #expect(msgs.count == 6)
    }

    @Test func hubEntities() throws {
        let t = HomeAssistantTopics(base: "home/doorstep", discoveryPrefix: "ha")
        let msgs = HomeAssistantDiscovery.hubConfigs(t)
        #expect(msgs.map(\.topic) == ["ha/select/doorstep/mode/config", "ha/sensor/doorstep/parcels_due/config"])
        let mode = try json(msgs[0])
        #expect(mode["options"] as? [String] == ["Home", "Away", "Night", "Quiet"])
        #expect(mode["command_topic"] as? String == "home/doorstep/mode/set")
        #expect(mode["state_topic"] as? String == "home/doorstep/mode")
        #expect(mode["unique_id"] as? String == "doorstep_mode")
        #expect(mode["availability_topic"] as? String == "home/doorstep/status")
        let due = try json(msgs[1])
        #expect(due["state_topic"] as? String == "home/doorstep/parcels_due")
    }

    @Test func topicsAreSanitised() {
        #expect(HomeAssistantTopics(base: "/door#step/+/", discoveryPrefix: "").base == "doorstep")
        #expect(HomeAssistantTopics(base: "", discoveryPrefix: " ").discoveryPrefix == "homeassistant")
        #expect(HomeAssistantTopics.slug("Front Door/+#") == "front_door___")
    }
}

// MARK: - Loopback broker (127.0.0.1 only)

/// Just enough of a broker to prove the client talks MQTT: answers CONNECT, SUBSCRIBE,
/// QoS 1 PUBLISH and PINGREQ, and records what it was sent.
actor FakeBroker {
    struct Packet: Sendable { let header: UInt8; let body: [UInt8] }
    private(set) var packets: [Packet] = []
    private var listener: NWListener?
    private var conns: [NWConnection] = []
    private var buffers: [ObjectIdentifier: [UInt8]] = [:]
    private let queue = DispatchQueue(label: "fake.broker")

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in Task { await self?.accept(c) } }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            l.stateUpdateHandler = { s in
                switch s {
                case .ready: if once.take() { cont.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): if once.take() { cont.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    func stop() { listener?.cancel(); conns.forEach { $0.cancel() } }

    private func accept(_ c: NWConnection) {
        conns.append(c)
        c.start(queue: queue)
        read(c)
    }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, _ in
            let bytes = data.map { [UInt8]($0) } ?? []
            Task { await self?.got(bytes, from: c, done: done) }
        }
    }

    private func got(_ bytes: [UInt8], from c: NWConnection, done: Bool) {
        let key = ObjectIdentifier(c)
        var buf = (buffers[key] ?? []) + bytes
        while buf.count >= 2, let (len, n) = try? MQTTPacket.decodeRemainingLength(buf, at: 1), buf.count >= 1 + n + len {
            let p = Packet(header: buf[0], body: Array(buf[(1 + n)..<(1 + n + len)]))
            buf.removeFirst(1 + n + len)
            packets.append(p)
            switch p.header >> 4 {
            case 1: c.send(content: Data([0x20, 0x02, 0x00, 0x00]), completion: .idempotent)
            case 8: c.send(content: Data([0x90, 0x03, p.body[0], p.body[1], 0x00]), completion: .idempotent)
            case 12: c.send(content: Data([0xD0, 0x00]), completion: .idempotent)
            case 3 where (p.header >> 1) & 0x03 == 1:
                let tl = Int(p.body[0]) << 8 | Int(p.body[1])
                c.send(content: Data([0x40, 0x02, p.body[2 + tl], p.body[3 + tl]]), completion: .idempotent)
            default: break
            }
        }
        buffers[key] = buf
        if !done { read(c) }
    }

    /// Sends a PUBLISH to every connected client.
    func push(_ topic: String, _ text: String) throws {
        let bytes = try MQTTPacket.publish(topic: topic, payload: Array(text.utf8), qos: 0, retain: false, packetId: nil)
        for c in conns { c.send(content: Data(bytes), completion: .idempotent) }
    }

    func publishes() -> [(topic: String, payload: [UInt8], retain: Bool, qos: UInt8)] {
        packets.filter { $0.header >> 4 == 3 }.compactMap { p in
            guard case let .publish(t, pl, q, r, _)? = try? MQTTPacket.decode(header: p.header, body: p.body) else { return nil }
            return (t, pl, r, q)
        }
    }

    func types() -> [UInt8] { packets.map { $0.header >> 4 } }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

actor Inbox {
    var messages: [(String, String)] = []
    var states: [MQTTClient.State] = []
    func add(_ t: String, _ p: [UInt8]) { messages.append((t, String(decoding: p, as: UTF8.self))) }
    func add(_ s: MQTTClient.State) { states.append(s) }
}

func waitUntil(_ seconds: Double = 5, isolation: isolated (any Actor)? = #isolation, _ check: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if await check() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await check()
}

@Suite(.serialized) struct MQTTLoopbackTests {
    @Test func clientTalksToLocalBroker() async throws {
        let broker = FakeBroker()
        let port = try await broker.start()
        defer { Task { await broker.stop() } }

        let client = MQTTClient(config: .init(
            host: "127.0.0.1", port: port, clientId: "test", username: "u", password: "p",
            will: .init(topic: "doorstep/status", payload: Array("offline".utf8))))
        let inbox = Inbox()
        await client.setHandlers(onState: { await inbox.add($0) }, onMessage: { await inbox.add($0, $1) })
        try await client.subscribe("doorstep/mode/set")
        await client.start()
        let ok1 = await waitUntil { await client.state == .connected }
        #expect(ok1)

        try await client.publish("doorstep/status", "online", qos: 1, retain: true)   // returns only after PUBACK
        try await client.publish("doorstep/camera/1/person", "ON")
        let ok2 = await waitUntil { await broker.publishes().count == 2 }
        #expect(ok2)
        let pubs = await broker.publishes()
        #expect(pubs[0].topic == "doorstep/status" && pubs[0].retain && pubs[0].qos == 1)
        #expect(pubs[1].topic == "doorstep/camera/1/person" && !pubs[1].retain && pubs[1].qos == 0)
        #expect(await broker.types().prefix(2) == [1, 8])   // CONNECT, then SUBSCRIBE

        try await broker.push("doorstep/mode/set", "Away")
        let ok3 = await waitUntil { await inbox.messages.contains { $0 == ("doorstep/mode/set", "Away") } }
        #expect(ok3)

        await client.stop()
        #expect(await waitUntil { await broker.types().last == 14 })   // DISCONNECT
        #expect(await client.state == .idle)
    }

    @Test func reconnectsAfterBrokerGoesAway() async throws {
        // Nothing listening: the client should back off and say it will retry.
        let broker = FakeBroker()
        let port = try await broker.start()
        await broker.stop()
        try? await Task.sleep(for: .milliseconds(100))
        let client = MQTTClient(config: .init(host: "127.0.0.1", port: port, clientId: "t2"))
        await client.start()
        let retrying = await waitUntil {
            if case .retrying = await client.state { return true } else { return false }
        }
        #expect(retrying)
        await client.stop()
        #expect(await client.state == .idle)
    }

    @MainActor @Test func bridgePublishesDiscoveryAndEvents() async throws {
        let broker = FakeBroker()
        let port = try await broker.start()
        defer { Task { await broker.stop() } }

        var s = MQTTBrokerSettings()
        s.host = "127.0.0.1"; s.port = Int(port)
        let bridge = HomeAssistantBridge(settings: s)
        var asked: [String] = []
        bridge.onModeCommand = { asked.append($0) }
        await bridge.register(HomeAssistantCamera(id: "77", name: "Porch", hasBattery: false))
        await bridge.connect()
        let ok4 = await waitUntil { bridge.isConnected }
        #expect(ok4)
        let ok5 = await waitUntil { await broker.publishes().contains { $0.topic == "homeassistant/image/doorstep_77/snapshot/config" } }
        #expect(ok5)

        await bridge.publishEvent(cameraId: "77", cameraName: "Porch", kind: .doorbell, who: "DPD",
                                  description: "DPD rang and left a parcel", snapshotJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        await bridge.publishBattery(cameraId: "77", percent: 81)
        await bridge.publishMode("Night")
        await bridge.publishParcelsDue(2)
        let ok6 = await waitUntil { await broker.publishes().contains { $0.topic == "doorstep/parcels_due" } }
        #expect(ok6)
        let pubs = await broker.publishes()
        func last(_ t: String) -> String? { pubs.last { $0.topic == t }.map { String(decoding: $0.payload, as: UTF8.self) } }
        #expect(last("doorstep/status") == "online")
        #expect(last("doorstep/camera/77/doorbell") == "ON")
        #expect(last("doorstep/camera/77/person") == "ON")
        #expect(last("doorstep/camera/77/last_visitor") == "DPD")
        #expect(last("doorstep/camera/77/battery") == "81")
        #expect(last("doorstep/mode") == "Night")
        #expect(last("doorstep/parcels_due") == "2")
        #expect(pubs.contains { $0.topic == "homeassistant/sensor/doorstep_77/battery/config" })
        #expect(pubs.last { $0.topic == "doorstep/camera/77/snapshot" }?.payload == [0xFF, 0xD8, 0xFF, 0xD9])
        #expect(pubs.contains { $0.topic == "homeassistant/select/doorstep/mode/config" })

        try await broker.push("doorstep/mode/set", "away")
        try await broker.push("doorstep/mode/set", "Party")    // not a mode: ignored
        let ok7 = await waitUntil { asked == ["Away"] }
        #expect(ok7)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(asked == ["Away"])

        await bridge.disconnect()
        #expect(!bridge.isConnected)
        let ok8 = await waitUntil { await broker.types().last == 14 }
        #expect(ok8)
    }
}
