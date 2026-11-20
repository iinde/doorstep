import Foundation

/// Turns RTP packets back into whole video frames (lists of NAL units) for H.264 (RFC 6184)
/// and H.265 (RFC 7798): single units, aggregation packets and fragments.
public struct Depacketizer: Sendable {
    public let codec: RTSPClient.Codec
    private var units: [Data] = []
    private var fragment: Data?
    private var timestamp: UInt32?
    private var lastSeq: UInt16?
    private var damaged = false

    public init(codec: RTSPClient.Codec) { self.codec = codec }

    /// Feed one RTP packet; returns a finished frame (and its 90 kHz timestamp) when one completes.
    public mutating func push(_ packet: Data) -> (nals: [Data], timestamp: UInt32)? {
        let p = [UInt8](packet)
        guard p.count > 12, p[0] >> 6 == 2 else { return nil }
        let csrc = Int(p[0] & 0x0F)
        var offset = 12 + csrc * 4
        if p[0] & 0x10 != 0 {                                    // header extension
            guard p.count >= offset + 4 else { return nil }
            offset += 4 + (Int(p[offset + 2]) << 8 | Int(p[offset + 3])) * 4
        }
        var end = p.count
        if p[0] & 0x20 != 0, let pad = p.last { end -= Int(pad) }  // padding
        guard end > offset else { return nil }
        let marker = p[1] & 0x80 != 0
        let seq = UInt16(p[2]) << 8 | UInt16(p[3])
        let ts = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])

        var finished: (nals: [Data], timestamp: UInt32)?
        if let t = timestamp, t != ts, !units.isEmpty {
            // A new frame started without a marker on the last one.
            finished = flush()
        }
        if let last = lastSeq, seq != last &+ 1 { damaged = true; fragment = nil }
        lastSeq = seq
        timestamp = ts
        let payload = Array(p[offset..<end])
        switch codec {
        case .h264: h264(payload)
        case .h265: h265(payload)
        }
        if marker { finished = flush() ?? finished }
        return finished
    }

    private mutating func flush() -> (nals: [Data], timestamp: UInt32)? {
        defer { units = []; fragment = nil; damaged = false }
        guard !units.isEmpty, !damaged, let ts = timestamp else { return nil }
        return (units, ts)
    }

    private mutating func h264(_ b: [UInt8]) {
        guard let first = b.first else { return }
        switch first & 0x1F {
        case 1...23: units.append(Data(b))
        case 24:                                                  // STAP-A
            var i = 1
            while i + 2 <= b.count {
                let n = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
                guard n > 0, i + n <= b.count else { break }
                units.append(Data(b[i..<(i + n)])); i += n
            }
        case 28:                                                  // FU-A
            guard b.count > 2 else { return }
            let start = b[1] & 0x80 != 0, stop = b[1] & 0x40 != 0
            if start { fragment = Data([(first & 0xE0) | (b[1] & 0x1F)]) }
            guard fragment != nil else { return }
            fragment!.append(contentsOf: b[2...])
            if stop { units.append(fragment!); fragment = nil }
        default: break
        }
    }

    private mutating func h265(_ b: [UInt8]) {
        guard b.count > 2 else { return }
        switch (b[0] >> 1) & 0x3F {
        case 48:                                                  // aggregation packet
            var i = 2
            while i + 2 <= b.count {
                let n = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
                guard n > 0, i + n <= b.count else { break }
                units.append(Data(b[i..<(i + n)])); i += n
            }
        case 49:                                                  // fragmentation unit
            guard b.count > 3 else { return }
            let start = b[2] & 0x80 != 0, stop = b[2] & 0x40 != 0
            if start { fragment = Data([(b[0] & 0x81) | ((b[2] & 0x3F) << 1), b[1]]) }
            guard fragment != nil else { return }
            fragment!.append(contentsOf: b[3...])
            if stop { units.append(fragment!); fragment = nil }
        case 50: break                                            // PACI: not used by cameras
        default: units.append(Data(b))
        }
    }
}
