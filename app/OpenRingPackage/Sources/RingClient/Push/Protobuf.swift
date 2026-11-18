import Foundation

// A tiny protobuf (proto2) wire-format writer and reader, just enough for the
// Android checkin and MCS messages that push-receiver uses. No reflection, no
// generated code: each message in PushMessages.swift encodes and decodes itself.

enum ProtoWireType: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

enum ProtoError: Error, Equatable, Sendable {
    case truncated
    case malformedVarint
    case unsupportedWireType(UInt8)
    case invalidUTF8(field: Int)
    case missingRequiredField(String)
}

// MARK: - Writer

struct ProtoWriter {
    private(set) var data = Data()

    init() {}

    static func varint(_ value: UInt64) -> Data {
        var out = Data()
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    mutating func writeRawVarint(_ value: UInt64) {
        data.append(Self.varint(value))
    }

    private mutating func writeKey(_ field: Int, _ type: ProtoWireType) {
        writeRawVarint(UInt64(field) << 3 | UInt64(type.rawValue))
    }

    mutating func writeUInt64(_ field: Int, _ value: UInt64) {
        writeKey(field, .varint)
        writeRawVarint(value)
    }

    /// int64 is the two's complement bit pattern as a varint (negatives take 10 bytes).
    mutating func writeInt64(_ field: Int, _ value: Int64) {
        writeUInt64(field, UInt64(bitPattern: value))
    }

    /// int32 negatives are sign-extended to 64 bits, as protobuf requires.
    mutating func writeInt32(_ field: Int, _ value: Int32) {
        writeUInt64(field, UInt64(bitPattern: Int64(value)))
    }

    mutating func writeUInt32(_ field: Int, _ value: UInt32) {
        writeUInt64(field, UInt64(value))
    }

    mutating func writeBool(_ field: Int, _ value: Bool) {
        writeUInt64(field, value ? 1 : 0)
    }

    mutating func writeFixed64(_ field: Int, _ value: UInt64) {
        writeKey(field, .fixed64)
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func writeBytes(_ field: Int, _ value: Data) {
        writeKey(field, .lengthDelimited)
        writeRawVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func writeString(_ field: Int, _ value: String) {
        writeBytes(field, Data(value.utf8))
    }

    mutating func writeMessage(_ field: Int, _ message: Data) {
        writeBytes(field, message)
    }
}

// MARK: - Reader

enum ProtoValue: Sendable, Equatable {
    case varint(UInt64)
    case fixed64(UInt64)
    case bytes(Data)
    case fixed32(UInt32)

    var uint64: UInt64? {
        switch self {
        case .varint(let v), .fixed64(let v): return v
        case .fixed32(let v): return UInt64(v)
        case .bytes: return nil
        }
    }

    var int64: Int64? { uint64.map { Int64(bitPattern: $0) } }

    /// int32 on the wire is a sign-extended varint; truncate to the low 32 bits.
    var int32: Int32? { uint64.map { Int32(truncatingIfNeeded: Int64(bitPattern: $0)) } }

    var bool: Bool? { uint64.map { $0 != 0 } }

    var data: Data? {
        if case .bytes(let d) = self { return d }
        return nil
    }

    var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
}

struct ProtoField: Sendable, Equatable {
    let number: Int
    let value: ProtoValue
}

struct ProtoReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { offset >= bytes.count }

    /// Reads a varint. Throws `.truncated` if the buffer ends mid-varint, so a
    /// stream parser can tell "need more bytes" apart from garbage.
    static func readVarint(_ bytes: [UInt8], at start: Int) throws -> (value: UInt64, length: Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while true {
            guard i < bytes.count else { throw ProtoError.truncated }
            let b = bytes[i]
            i += 1
            if shift == 63 && b > 1 { throw ProtoError.malformedVarint }
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            if shift > 63 { throw ProtoError.malformedVarint }
        }
        return (result, i - start)
    }

    mutating func readVarint() throws -> UInt64 {
        let (v, n) = try Self.readVarint(bytes, at: offset)
        offset += n
        return v
    }

    mutating func nextField() throws -> ProtoField? {
        guard !isAtEnd else { return nil }
        let key = try readVarint()
        let number = Int(key >> 3)
        let rawType = UInt8(key & 0x7)
        guard let type = ProtoWireType(rawValue: rawType) else {
            throw ProtoError.unsupportedWireType(rawType)
        }
        switch type {
        case .varint:
            return ProtoField(number: number, value: .varint(try readVarint()))
        case .fixed64:
            guard offset + 8 <= bytes.count else { throw ProtoError.truncated }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
            offset += 8
            return ProtoField(number: number, value: .fixed64(v))
        case .fixed32:
            guard offset + 4 <= bytes.count else { throw ProtoError.truncated }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
            offset += 4
            return ProtoField(number: number, value: .fixed32(v))
        case .lengthDelimited:
            let len = try readVarint()
            guard len <= UInt64(bytes.count - offset) else { throw ProtoError.truncated }
            let end = offset + Int(len)
            let slice = Data(bytes[offset..<end])
            offset = end
            return ProtoField(number: number, value: .bytes(slice))
        }
    }

    /// Every field in the message, in wire order. Unknown fields are kept, so
    /// callers just ignore numbers they don't care about.
    static func fields(_ data: Data) throws -> [ProtoField] {
        var reader = ProtoReader(data)
        var out: [ProtoField] = []
        while let f = try reader.nextField() { out.append(f) }
        return out
    }
}

extension Array where Element == ProtoField {
    func first(_ number: Int) -> ProtoValue? { first { $0.number == number }?.value }
    func all(_ number: Int) -> [ProtoValue] { filter { $0.number == number }.map(\.value) }

    func string(_ number: Int) throws -> String? {
        guard let v = first(number) else { return nil }
        guard let s = v.string else { throw ProtoError.invalidUTF8(field: number) }
        return s
    }
}
