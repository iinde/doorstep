import Foundation

// MCS wire framing, ported from push-receiver src/parser.ts (itself a port of
// Chromium's connection_handler_impl.cc):
//
//   first server packet:  [version:1][tag:1][size:varint32][proto bytes]
//   every packet after:             [tag:1][size:varint32][proto bytes]
//
// Our first client packet is [41][2 = LoginRequest][size][bytes].

struct MCSFrame: Sendable, Equatable {
    let tag: UInt8
    let payload: Data

    var knownTag: MCSTag? { MCSTag(rawValue: tag) }
}

enum MCSFramingError: Error, Equatable, Sendable {
    case badVersion(UInt8)
    case badSizeVarint
    case frameTooLarge(Int)
}

/// Incremental parser. Feed it whatever the socket hands you, in any split,
/// and it returns the complete frames. Never recursive, so a burst of buffered
/// frames can't blow the stack (the bug push-receiver's parser.ts fixed).
struct MCSFrameParser: Sendable {
    /// Chromium's MCS limit is 4 KiB but allows bigger; anything this large is garbage.
    static let maxFrameSize = 4 * 1024 * 1024

    private var buffer = [UInt8]()
    private var readOffset = 0
    private var expectingVersion = true
    private(set) var serverVersion: UInt8?

    init(expectingVersion: Bool = true) {
        self.expectingVersion = expectingVersion
    }

    mutating func feed(_ data: Data) throws -> [MCSFrame] {
        buffer.append(contentsOf: data)
        var frames: [MCSFrame] = []

        while true {
            var cursor = readOffset

            if expectingVersion {
                guard cursor < buffer.count else { break }
                let version = buffer[cursor]
                if version < MCSConstants.version && version != MCSConstants.legacyAcceptedVersion {
                    throw MCSFramingError.badVersion(version)
                }
                // Consume the version byte once, even if the rest hasn't arrived.
                serverVersion = version
                expectingVersion = false
                cursor += 1
                readOffset = cursor
            }

            guard cursor < buffer.count else { break }
            let tag = buffer[cursor]
            cursor += 1

            let size: UInt64
            let sizeLength: Int
            do {
                (size, sizeLength) = try ProtoReader.readVarint(buffer, at: cursor)
            } catch ProtoError.truncated {
                // Size varint split across reads: wait for more.
                if buffer.count - cursor >= 5 { throw MCSFramingError.badSizeVarint }
                break
            } catch {
                throw MCSFramingError.badSizeVarint
            }
            guard sizeLength <= 5 else { throw MCSFramingError.badSizeVarint }
            guard size <= UInt64(Self.maxFrameSize) else { throw MCSFramingError.frameTooLarge(Int(clamping: size)) }
            cursor += sizeLength

            let end = cursor + Int(size)
            guard end <= buffer.count else { break }

            frames.append(MCSFrame(tag: tag, payload: Data(buffer[cursor..<end])))
            readOffset = end
        }

        // Compact occasionally so the buffer doesn't grow forever.
        if readOffset > 0 && (readOffset == buffer.count || readOffset > 64 * 1024) {
            buffer.removeFirst(readOffset)
            readOffset = 0
        }
        return frames
    }

    var bufferedByteCount: Int { buffer.count - readOffset }
}

enum MCSFrameEncoder {
    /// [tag][varint size][bytes], i.e. the tag byte plus protobufjs encodeDelimited.
    static func frame(tag: MCSTag, payload: Data) -> Data {
        var out = Data([tag.rawValue])
        out.append(ProtoWriter.varint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    /// The very first packet: [kMCSVersion][kLoginRequestTag][size][bytes].
    static func loginPacket(_ login: MCSLoginRequest) -> Data {
        var out = Data([MCSConstants.version])
        out.append(frame(tag: .loginRequest, payload: login.encode()))
        return out
    }
}
