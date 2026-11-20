import Foundation
import Network
import CryptoKit

/// A small RTSP client for IP cameras: DESCRIBE, SETUP over TCP (RTP interleaved in the same
/// connection, so it works through any home network), PLAY, keep-alive. Basic and Digest
/// sign-in. Hands every RTP video packet to `onPacket`. One instance per camera.
public final class RTSPClient: @unchecked Sendable {
    public enum Codec: String, Sendable { case h264 = "H264", h265 = "H265" }
    public struct Track: Sendable {
        public var codec: Codec
        public var payloadType: Int
        public var control: String
        /// Parameter sets from the SDP (SPS/PPS, plus VPS for H.265), without start codes.
        public var parameterSets: [Data]
    }
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badURL, connection(String), status(Int, String), noVideo(String), unsupported(String), signIn
        public var description: String {
            switch self {
            case .badURL: return "That isn't a valid rtsp:// address."
            case .connection(let s): return "Couldn't connect (\(s))."
            case .status(let c, let s): return "The camera said \(c) \(s)."
            case .noVideo(let s): return "The camera didn't offer a video stream (\(s))."
            case .unsupported(let s): return "The camera's video is \(s), which Doorstep can't show yet."
            case .signIn: return "The camera didn't accept the user name or password."
            }
        }
    }

    public let url: URL
    private let user: String?
    private let password: String?
    private let queue = DispatchQueue(label: "doorstep.rtsp")
    private var connection: NWConnection?
    private var buffer = Data()
    private var cseq = 0
    private var session: String?
    private var auth: (scheme: String, realm: String, nonce: String, qop: String?, opaque: String?)?
    private var waiting: [Int: CheckedContinuation<Response, Error>] = [:]
    private var keepAlive: DispatchSourceTimer?
    private var videoChannel: UInt8 = 0
    private var stopped = false
    public private(set) var track: Track?

    /// Each RTP packet of the video track.
    public var onPacket: (@Sendable (Data) -> Void)?
    /// The connection ended (camera went away, network dropped). Not called after `stop()`.
    public var onClose: (@Sendable (Error?) -> Void)?

    struct Response { var status: Int; var reason: String; var headers: [String: String]; var body: Data }

    /// `url` may carry the sign-in (`rtsp://user:pass@host/path`); explicit values win.
    public init?(url: URL, user: String? = nil, password: String? = nil) {
        guard url.scheme?.lowercased() == "rtsp", url.host != nil else { return nil }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        self.user = user ?? c.user?.removingPercentEncoding
        self.password = password ?? c.password?.removingPercentEncoding
        c.user = nil; c.password = nil
        self.url = c.url!
    }

    // MARK: Session

    /// Connects, negotiates and starts playing. Returns the video track it chose.
    @discardableResult
    public func start() async throws -> Track {
        try await connect()
        _ = try await request("OPTIONS", url.absoluteString)
        let described = try await request("DESCRIBE", url.absoluteString, headers: ["Accept": "application/sdp"])
        let base = described.headers["content-base"] ?? described.headers["content-location"] ?? url.absoluteString
        let sdp = String(decoding: described.body, as: UTF8.self)
        let t = try Self.videoTrack(sdp: sdp, base: base)
        track = t
        let setup = try await request("SETUP", t.control, headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"])
        guard let s = setup.headers["session"] else { throw Failure.status(setup.status, "no session") }
        let parts = s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        session = parts[0]
        if let transport = setup.headers["transport"], let r = transport.range(of: "interleaved=") {
            videoChannel = UInt8(transport[r.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        let timeout = parts.first { $0.lowercased().hasPrefix("timeout=") }.flatMap { Int($0.dropFirst(8)) } ?? 60
        _ = try await request("PLAY", base.hasSuffix("/") ? base : url.absoluteString, headers: ["Range": "npt=0.000-"])
        startKeepAlive(every: max(10, Double(timeout) / 2))
        return t
    }

    public func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.keepAlive?.cancel()
            if let session = self.session {
                self.cseq += 1
                let text = "TEARDOWN \(self.url.absoluteString) RTSP/1.0\r\nCSeq: \(self.cseq)\r\nSession: \(session)\r\n\(self.authHeader("TEARDOWN", self.url.absoluteString))\r\n"
                self.connection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in self.connection?.cancel() })
            } else {
                self.connection?.cancel()
            }
            for (_, c) in self.waiting { c.resume(throwing: Failure.connection("stopped")) }
            self.waiting = [:]
        }
    }

    private func connect() async throws {
        let host = NWEndpoint.Host(url.host!)
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 554))!
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.noDelay = true
        let conn = NWConnection(host: host, port: port, using: NWParameters(tls: nil, tcp: tcp))
        connection = conn
        final class Once: @unchecked Sendable { var done = false }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !once.done { once.done = true; c.resume() }
                    self?.receive()
                case .failed(let e), .waiting(let e):
                    if !once.done { once.done = true; c.resume(throwing: Failure.connection(e.localizedDescription)); conn.cancel() }
                    else { self?.closed(e) }
                case .cancelled:
                    if !once.done { once.done = true; c.resume(throwing: Failure.connection("cancelled")) }
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func closed(_ error: Error?) {
        guard !stopped else { return }
        stopped = true
        keepAlive?.cancel()
        for (_, c) in waiting { c.resume(throwing: Failure.connection("closed")) }
        waiting = [:]
        onClose?(error)
    }

    private func startKeepAlive(every seconds: Double) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds, repeating: seconds)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task { _ = try? await self.request("GET_PARAMETER", self.url.absoluteString) }
        }
        t.resume()
        keepAlive = t
    }

    // MARK: Requests

    private func request(_ method: String, _ uri: String, headers: [String: String] = [:], retried: Bool = false) async throws -> Response {
        let response: Response = try await withCheckedThrowingContinuation { c in
            queue.async {
                guard let conn = self.connection, !self.stopped else { c.resume(throwing: Failure.connection("closed")); return }
                self.cseq += 1
                let seq = self.cseq
                var text = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(seq)\r\nUser-Agent: Doorstep\r\n"
                if let s = self.session { text += "Session: \(s)\r\n" }
                for (k, v) in headers { text += "\(k): \(v)\r\n" }
                text += self.authHeader(method, uri)
                text += "\r\n"
                self.waiting[seq] = c
                conn.send(content: Data(text.utf8), completion: .contentProcessed { error in
                    if let error { self.queue.async { self.waiting.removeValue(forKey: seq)?.resume(throwing: Failure.connection(error.localizedDescription)) } }
                })
            }
        }
        if response.status == 401 {
            guard !retried, user != nil, let challenge = response.headers["www-authenticate"] else { throw Failure.signIn }
            queue.sync { auth = Self.parseChallenge(challenge) }
            return try await request(method, uri, headers: headers, retried: true)
        }
        guard (200..<300).contains(response.status) else { throw Failure.status(response.status, response.reason) }
        return response
    }

    private func authHeader(_ method: String, _ uri: String) -> String {
        guard let auth, let user, let password else { return "" }
        if auth.scheme == "basic" {
            return "Authorization: Basic \(Data("\(user):\(password)".utf8).base64EncodedString())\r\n"
        }
        func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        let ha1 = md5("\(user):\(auth.realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        var h = "Authorization: Digest username=\"\(user)\", realm=\"\(auth.realm)\", nonce=\"\(auth.nonce)\", uri=\"\(uri)\""
        if let qop = auth.qop, qop.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("auth") {
            let cnonce = UUID().uuidString.prefix(16).lowercased()
            let nc = String(format: "%08x", cseq)
            h += ", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\", response=\"\(md5("\(ha1):\(auth.nonce):\(nc):\(cnonce):auth:\(ha2)"))\""
        } else {
            h += ", response=\"\(md5("\(ha1):\(auth.nonce):\(ha2)"))\""
        }
        if let opaque = auth.opaque { h += ", opaque=\"\(opaque)\"" }
        return h + "\r\n"
    }

    static func parseChallenge(_ header: String) -> (scheme: String, realm: String, nonce: String, qop: String?, opaque: String?) {
        let scheme = header.lowercased().hasPrefix("basic") ? "basic" : "digest"
        func value(_ key: String) -> String? {
            guard let r = header.range(of: key + "=", options: .caseInsensitive) else { return nil }
            var rest = header[r.upperBound...]
            if rest.first == "\"" { rest = rest.dropFirst(); return String(rest.prefix { $0 != "\"" }) }
            return String(rest.prefix { $0 != "," }).trimmingCharacters(in: .whitespaces)
        }
        return (scheme, value("realm") ?? "", value("nonce") ?? "", value("qop"), value("opaque"))
    }

    // MARK: Reading

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if complete || error != nil { self.closed(error); return }
            if !self.stopped { self.receive() }
        }
    }

    /// Splits the stream into RTSP responses and `$`-framed interleaved packets.
    private func drain() {
        while !buffer.isEmpty {
            if buffer[buffer.startIndex] == 0x24 {           // '$' channel length payload
                guard buffer.count >= 4 else { return }
                let b = buffer.startIndex
                let channel = buffer[b + 1]
                let length = Int(buffer[b + 2]) << 8 | Int(buffer[b + 3])
                guard buffer.count >= 4 + length else { return }
                let packet = buffer.subdata(in: (b + 4)..<(b + 4 + length))
                buffer.removeSubrange(b..<(b + 4 + length))
                if channel == videoChannel { onPacket?(packet) }
                continue
            }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst()
            guard statusLine.hasPrefix("RTSP/") else {
                // Out of step: skip a byte and look again.
                buffer.removeFirst()
                continue
            }
            var headers: [String: String] = [:]
            for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let bodyStart = end.upperBound
            guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
            buffer.removeSubrange(buffer.startIndex..<(bodyStart + length))
            let parts = statusLine.split(separator: " ", maxSplits: 2)
            let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let reason = parts.count > 2 ? String(parts[2]) : ""
            if let seq = Int(headers["cseq"] ?? ""), let c = waiting.removeValue(forKey: seq) {
                c.resume(returning: Response(status: status, reason: reason, headers: headers, body: body))
            }
        }
    }

    // MARK: SDP

    static func videoTrack(sdp: String, base: String) throws -> Track {
        var inVideo = false
        var payloads: [Int] = []
        var codec: Codec?
        var payloadType = 96
        var control = ""
        var sets: [Data] = []
        var seenOther: String?
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if inVideo, codec != nil { break }
                inVideo = line.hasPrefix("m=video")
                if inVideo { payloads = line.split(separator: " ").dropFirst(3).compactMap { Int($0) } }
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=rtpmap:") {
                let rest = line.dropFirst(9)
                let pt = Int(rest.prefix { $0.isNumber }) ?? -1
                let name = rest.drop { $0.isNumber }.trimmingCharacters(in: .whitespaces).split(separator: "/").first.map(String.init)?.uppercased() ?? ""
                if codec == nil, payloads.contains(pt) {
                    if let c = Codec(rawValue: name == "HEVC" ? "H265" : name) { codec = c; payloadType = pt } else { seenOther = name }
                }
            } else if line.hasPrefix("a=fmtp:") {
                for param in line.split(separator: " ").dropFirst().joined(separator: " ").split(separator: ";") {
                    let kv = param.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2 else { continue }
                    switch kv[0].lowercased() {
                    case "sprop-parameter-sets": sets += kv[1].split(separator: ",").compactMap { Data(base64Encoded: String($0)) }
                    case "sprop-vps", "sprop-sps", "sprop-pps": sets += kv[1].split(separator: ",").compactMap { Data(base64Encoded: String($0)) }
                    default: break
                    }
                }
            } else if line.hasPrefix("a=control:") {
                control = String(line.dropFirst(10))
            }
        }
        guard let codec else {
            if let other = seenOther { throw Failure.unsupported(other) }
            throw Failure.noVideo("no H.264 or H.265 track")
        }
        let url: String
        if control.lowercased().hasPrefix("rtsp://") { url = control }
        else if control.isEmpty || control == "*" { url = base }
        else { url = base + (base.hasSuffix("/") ? "" : "/") + control }
        return Track(codec: codec, payloadType: payloadType, control: url, parameterSets: sets)
    }
}
