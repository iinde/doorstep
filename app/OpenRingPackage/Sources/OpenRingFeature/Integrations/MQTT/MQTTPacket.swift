import Foundation

/// MQTT 3.1.1 packet encoding and decoding. Pure functions with no I/O, so every byte
/// can be checked in tests. Only the packets Doorstep needs: it publishes, subscribes to a
/// couple of command topics at QoS 0, and keeps the connection alive.
public enum MQTTPacket {

    public enum PacketError: Error, Equatable, Sendable {
        case remainingLengthTooLarge(Int)
        case stringTooLong(Int)
        case malformedRemainingLength
        case malformedPacket(String)
    }

    /// Largest value the 4-byte variable length scheme can carry (MQTT 3.1.1, 2.2.3).
    public static let maxRemainingLength = 268_435_455

    // MARK: Remaining length

    /// Variable length encoding: 7 bits per byte, top bit means "more bytes follow".
    public static func encodeRemainingLength(_ length: Int) throws -> [UInt8] {
        guard length >= 0, length <= maxRemainingLength else { throw PacketError.remainingLengthTooLarge(length) }
        var x = length
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 0x80 }
            out.append(byte)
        } while x > 0
        return out
    }

    /// Decodes a remaining length starting at `offset`. Returns nil when more bytes are needed.
    public static func decodeRemainingLength(_ bytes: [UInt8], at offset: Int) throws -> (value: Int, byteCount: Int)? {
        var multiplier = 1
        var value = 0
        var i = offset
        for count in 1...4 {
            guard i < bytes.count else { return nil }
            let byte = bytes[i]
            value += Int(byte & 0x7F) * multiplier
            if byte & 0x80 == 0 { return (value, count) }
            multiplier *= 128
            i += 1
        }
        throw PacketError.malformedRemainingLength
    }

    // MARK: Primitives

    static func encodeString(_ s: String) throws -> [UInt8] {
        try encodeBinary(Array(s.utf8))
    }

    static func encodeBinary(_ b: [UInt8]) throws -> [UInt8] {
        guard b.count <= 65_535 else { throw PacketError.stringTooLong(b.count) }
        return [UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b
    }

    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    static func frame(_ header: UInt8, _ body: [UInt8]) throws -> [UInt8] {
        [header] + (try encodeRemainingLength(body.count)) + body
    }

    // MARK: Outgoing packets

    public struct Will: Sendable, Equatable {
        public var topic: String
        public var payload: [UInt8]
        public var qos: UInt8
        public var retain: Bool
        public init(topic: String, payload: [UInt8], qos: UInt8 = 1, retain: Bool = true) {
            self.topic = topic; self.payload = payload; self.qos = min(qos, 1); self.retain = retain
        }
    }

    public static func connect(clientId: String, username: String?, password: String?,
                               keepAlive: UInt16, cleanSession: Bool, will: Will?) throws -> [UInt8] {
        var flags: UInt8 = 0
        if cleanSession { flags |= 0x02 }
        if let will {
            flags |= 0x04
            flags |= (will.qos & 0x03) << 3
            if will.retain { flags |= 0x20 }
        }
        // A password without a username is not allowed in 3.1.1 (3.1.2.9).
        let user = (username?.isEmpty == false) ? username : nil
        let pass = user != nil ? password : nil
        if user != nil { flags |= 0x80 }
        if pass != nil { flags |= 0x40 }

        var body: [UInt8] = try encodeString("MQTT")
        body.append(0x04)            // protocol level 3.1.1
        body.append(flags)
        body += u16(keepAlive)
        body += try encodeString(clientId)
        if let will {
            body += try encodeString(will.topic)
            body += try encodeBinary(will.payload)
        }
        if let user { body += try encodeString(user) }
        if let pass { body += try encodeBinary(Array(pass.utf8)) }
        return try frame(0x10, body)
    }

    public static func publish(topic: String, payload: [UInt8], qos: UInt8, retain: Bool,
                               packetId: UInt16?, dup: Bool = false) throws -> [UInt8] {
        let q = min(qos, 1)
        var header: UInt8 = 0x30 | (q << 1)
        if retain { header |= 0x01 }
        if dup && q > 0 { header |= 0x08 }
        var body = try encodeString(topic)
        if q > 0 {
            guard let packetId, packetId != 0 else { throw PacketError.malformedPacket("QoS 1 needs a packet id") }
            body += u16(packetId)
        }
        body += payload
        return try frame(header, body)
    }

    public static func subscribe(packetId: UInt16, topics: [String]) throws -> [UInt8] {
        var body = u16(packetId)
        for t in topics { body += try encodeString(t); body.append(0x00) }   // QoS 0
        return try frame(0x82, body)
    }

    public static func puback(packetId: UInt16) -> [UInt8] { [0x40, 0x02] + u16(packetId) }
    public static let pingreq: [UInt8] = [0xC0, 0x00]
    public static let disconnect: [UInt8] = [0xE0, 0x00]

    // MARK: Incoming packets

    public enum Incoming: Equatable, Sendable {
        case connack(sessionPresent: Bool, returnCode: UInt8)
        case publish(topic: String, payload: [UInt8], qos: UInt8, retain: Bool, packetId: UInt16?)
        case puback(packetId: UInt16)
        case suback(packetId: UInt16, codes: [UInt8])
        case pingresp
        case other(type: UInt8)
    }

    /// Takes every complete packet off the front of `buffer`, leaving any partial packet behind.
    public static func parse(_ buffer: inout [UInt8]) throws -> [Incoming] {
        var out: [Incoming] = []
        var start = 0
        while start < buffer.count {
            guard let (length, lenBytes) = try decodeRemainingLength(buffer, at: start + 1) else { break }
            let bodyStart = start + 1 + lenBytes
            let end = bodyStart + length
            guard end <= buffer.count else { break }
            out.append(try decode(header: buffer[start], body: Array(buffer[bodyStart..<end])))
            start = end
        }
        if start > 0 { buffer.removeFirst(start) }
        return out
    }

    static func decode(header: UInt8, body: [UInt8]) throws -> Incoming {
        func id(_ at: Int) throws -> UInt16 {
            guard body.count >= at + 2 else { throw PacketError.malformedPacket("short packet") }
            return UInt16(body[at]) << 8 | UInt16(body[at + 1])
        }
        switch header >> 4 {
        case 2:
            guard body.count == 2 else { throw PacketError.malformedPacket("CONNACK length") }
            return .connack(sessionPresent: body[0] & 0x01 == 1, returnCode: body[1])
        case 3:
            let qos = (header >> 1) & 0x03
            let topicLen = Int(try id(0))
            var i = 2 + topicLen
            guard body.count >= i else { throw PacketError.malformedPacket("PUBLISH topic") }
            let topic = String(decoding: body[2..<i], as: UTF8.self)
            var pid: UInt16?
            if qos > 0 { pid = try id(i); i += 2 }
            return .publish(topic: topic, payload: Array(body[i...]), qos: qos, retain: header & 0x01 == 1, packetId: pid)
        case 4: return .puback(packetId: try id(0))
        case 9: return .suback(packetId: try id(0), codes: Array(body.dropFirst(2)))
        case 13: return .pingresp
        default: return .other(type: header >> 4)
        }
    }

    /// Human wording for a refused CONNACK.
    public static func connackReason(_ code: UInt8) -> String {
        switch code {
        case 1: return "The broker does not support MQTT 3.1.1"
        case 2: return "The broker refused the client id"
        case 3: return "The broker is unavailable"
        case 4: return "The broker refused the username or password"
        case 5: return "The broker says this login is not allowed"
        default: return "The broker refused the connection (code \(code))"
        }
    }
}
