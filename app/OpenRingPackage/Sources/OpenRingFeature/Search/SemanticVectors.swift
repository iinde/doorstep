import Accelerate
import Foundation

/// Small vector helpers for embeddings.
public enum VectorMath {
    /// Unit length copy (a zero vector stays zero).
    public static func normalised(_ v: [Float]) -> [Float] {
        let norm = (dot(v, v)).squareRoot()
        guard norm > 0, norm.isFinite else { return v }
        return vDSP.divide(v, norm)
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vector lengths differ")
        return vDSP.dot(a, b)
    }

    /// Cosine similarity, for vectors of any length.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let d = (dot(a, a) * dot(b, b)).squareRoot()
        return d > 0 ? dot(a, b) / d : 0
    }
}

/// The on-disk form of the picture index: one fixed-length Float32 vector per event id.
///
/// Layout (little-endian):
/// `"DSEM"` · UInt16 format version · UInt16 model name length · model name (UTF-8) ·
/// UInt32 dimensions · UInt32 count · then per entry: UInt16 id length · id (UTF-8) ·
/// dimensions × Float32.
/// About 2 KB a visit at 512 dimensions.
public enum SemanticIndexFile {
    public static let formatVersion: UInt16 = 1
    private static let magic = Data("DSEM".utf8)

    public enum ReadError: Error, Equatable { case notAnIndex, unsupportedVersion, truncated }

    public struct Contents: Equatable, Sendable {
        public var model: String
        public var dimensions: Int
        public var vectors: [String: [Float]]
        public init(model: String, dimensions: Int, vectors: [String: [Float]]) {
            self.model = model; self.dimensions = dimensions; self.vectors = vectors
        }
    }

    public static func encode(_ c: Contents) -> Data {
        var out = Data()
        let entries = c.vectors.filter { $0.value.count == c.dimensions && $0.key.utf8.count <= Int(UInt16.max) }
        out.reserveCapacity(16 + entries.count * (c.dimensions * 4 + 24))
        out.append(magic)
        append(&out, formatVersion)
        let name = Data(c.model.utf8.prefix(Int(UInt16.max)))
        append(&out, UInt16(name.count))
        out.append(name)
        append(&out, UInt32(c.dimensions))
        append(&out, UInt32(entries.count))
        for (id, v) in entries.sorted(by: { $0.key < $1.key }) {
            let idData = Data(id.utf8)
            append(&out, UInt16(idData.count))
            out.append(idData)
            // Every Apple platform is little-endian, so the floats go in as they sit in memory.
            v.withUnsafeBytes { out.append(contentsOf: $0) }
        }
        return out
    }

    public static func decode(_ data: Data) throws -> Contents {
        var r = Reader(data: data)
        guard r.bytes(4) == magic else { throw ReadError.notAnIndex }
        guard let version: UInt16 = r.int() else { throw ReadError.truncated }
        guard version == formatVersion else { throw ReadError.unsupportedVersion }
        guard let nameLen: UInt16 = r.int(), let name = r.bytes(Int(nameLen)),
              let dims: UInt32 = r.int(), let count: UInt32 = r.int() else { throw ReadError.truncated }
        let d = Int(dims)
        var vectors: [String: [Float]] = [:]
        vectors.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let idLen: UInt16 = r.int(), let idData = r.bytes(Int(idLen)),
                  let raw = r.bytes(d * 4) else { throw ReadError.truncated }
            var v = [Float](repeating: 0, count: d)
            v.withUnsafeMutableBytes { dst in raw.withUnsafeBytes { dst.copyMemory(from: $0) } }
            vectors[String(decoding: idData, as: UTF8.self)] = v
        }
        return Contents(model: String(decoding: name, as: UTF8.self), dimensions: d, vectors: vectors)
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var offset: Int
        init(data: Data) { self.data = data; offset = data.startIndex }
        mutating func bytes(_ n: Int) -> Data? {
            guard n >= 0, offset + n <= data.endIndex else { return nil }
            defer { offset += n }
            return data.subdata(in: offset..<(offset + n))
        }
        mutating func int<T: FixedWidthInteger>() -> T? {
            guard let b = bytes(MemoryLayout<T>.size) else { return nil }
            return b.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }
    }
}
