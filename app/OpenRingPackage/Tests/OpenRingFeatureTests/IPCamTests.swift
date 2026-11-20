import Testing
import Foundation
import Network
import CryptoKit
import CoreVideo
@testable import IPCam

/// A tiny RTSP camera for tests: serves an Annex-B file (made by ffmpeg) over RTSP with
/// RTP interleaved on TCP, Digest sign-in required. Real enough to prove the whole path.
final class FakeCamera: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "fake-camera")
    let frames: [[Data]]              // access units, NALs without start codes
    let codec: RTSPClient.Codec
    let user = "admin", password = "secret", realm = "FakeCam", nonce = "abc123"
    var requireAuth = true
    var paced = false
    var port: UInt16 { listener.port!.rawValue }

    init(file: URL, codec: RTSPClient.Codec, port: UInt16? = nil) throws {
        self.codec = codec
        frames = Self.accessUnits(try Data(contentsOf: file), codec: codec)
        listener = try NWListener(using: .tcp, on: port.map { NWEndpoint.Port(rawValue: $0)! } ?? .any)
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel() }

    static func nalType(_ d: Data, _ codec: RTSPClient.Codec) -> Int {
        codec == .h264 ? Int(d.first! & 0x1F) : Int((d.first! >> 1) & 0x3F)
    }

    /// Split on start codes, group into access units at each delimiter NAL.
    static func accessUnits(_ data: Data, codec: RTSPClient.Codec) -> [[Data]] {
        let b = [UInt8](data)
        var nals: [Data] = []
        var i = 0, start = -1
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, (b[i + 2] == 1 || (i + 3 < b.count && b[i + 2] == 0 && b[i + 3] == 1)) {
                let skip = b[i + 2] == 1 ? 3 : 4
                if start >= 0 { var e = i; while e > start, b[e - 1] == 0 { e -= 1 }; nals.append(Data(b[start..<e])) }
                start = i + skip; i += skip
            } else { i += 1 }
        }
        if start >= 0, start < b.count { nals.append(Data(b[start...])) }
        let aud = codec == .h264 ? 9 : 35
        var units: [[Data]] = [], current: [Data] = []
        for n in nals where !n.isEmpty {
            if nalType(n, codec) == aud { if !current.isEmpty { units.append(current) }; current = [] }
            current.append(n)
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        var buffer = Data()
        func next() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
                if let data { buffer.append(data) }
                while let r = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let req = String(decoding: buffer[..<r.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(..<r.upperBound)
                    self.respond(req, on: c)
                }
                if !done { next() }
            }
        }
        next()
    }

    private func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func respond(_ req: String, on c: NWConnection) {
        let lines = req.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        let method = String(parts[0]), uri = String(parts[1])
        let seq = lines.first { $0.lowercased().hasPrefix("cseq:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) } ?? "0"
        func send(_ status: String, _ headers: [String] = [], body: String = "") {
            var t = "RTSP/1.0 \(status)\r\nCSeq: \(seq)\r\n"
            for h in headers { t += h + "\r\n" }
            if !body.isEmpty { t += "Content-Length: \(body.utf8.count)\r\n" }
            c.send(content: Data((t + "\r\n" + body).utf8), completion: .idempotent)
        }
        if method != "OPTIONS", requireAuth {
            guard let a = lines.first(where: { $0.lowercased().hasPrefix("authorization: digest") }),
                  a.contains("response=\"\(md5("\(md5("\(user):\(realm):\(password)")):\(nonce):\(md5("\(method):\(uri)"))"))\"") else {
                send("401 Unauthorized", ["WWW-Authenticate: Digest realm=\"\(realm)\", nonce=\"\(nonce)\""]); return
            }
        }
        switch method {
        case "OPTIONS": send("200 OK", ["Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER"])
        case "DESCRIBE":
            let sets = frames.first!.filter { [7, 8, 32, 33, 34].contains(Self.nalType($0, codec)) }
            let fmtp = codec == .h264
                ? "packetization-mode=1;sprop-parameter-sets=" + sets.map { $0.base64EncodedString() }.joined(separator: ",")
                : sets.map { n -> String in
                    let k = ["32": "sprop-vps", "33": "sprop-sps", "34": "sprop-pps"]["\(Self.nalType(n, codec))"]!
                    return "\(k)=\(n.base64EncodedString())" }.joined(separator: ";")
            let sdp = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=Fake\r\nt=0 0\r\nm=audio 0 RTP/AVP 0\r\na=control:trackID=2\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 \(codec == .h264 ? "H264" : "H265")/90000\r\na=fmtp:96 \(fmtp)\r\na=control:trackID=1\r\n"
            send("200 OK", ["Content-Type: application/sdp", "Content-Base: \(uri)/"], body: sdp)
        case "SETUP": send("200 OK", ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1", "Session: 12345678;timeout=60"])
        case "PLAY":
            send("200 OK", ["Session: 12345678"])
            queue.asyncAfter(deadline: .now() + 0.05) { self.stream(on: c) }
        default: send("200 OK", ["Session: 12345678"])
        }
    }

    private func stream(on c: NWConnection) {
        if paced { pacedStream(on: c, index: 0, seq: 1); return }
        var seq: UInt16 = 1
        for (i, au) in frames.enumerated() { seq = send(au, ts: UInt32(i * 3000), seq: seq, on: c) }
    }

    /// 30 frames a second, looping, until the connection goes.
    private func pacedStream(on c: NWConnection, index: Int, seq: UInt16) {
        guard c.state == .ready else { return }
        let next = send(frames[index % frames.count], ts: UInt32(truncatingIfNeeded: index * 3000), seq: seq, on: c)
        queue.asyncAfter(deadline: .now() + 1.0 / 30) { self.pacedStream(on: c, index: index + 1, seq: next) }
    }

    @discardableResult
    private func send(_ au: [Data], ts: UInt32, seq start: UInt16, on c: NWConnection) -> UInt16 {
        var seq = start
        do {
            let nals = au.filter { ![9, 35].contains(Self.nalType($0, codec)) }
            for (j, nal) in nals.enumerated() {
                for (k, payload) in packetize(nal).enumerated() {
                    let last = j == nals.count - 1 && k == packetize(nal).count - 1
                    var rtp = Data([0x80, (last ? 0x80 : 0) | 96, UInt8(seq >> 8), UInt8(seq & 0xFF),
                                    UInt8(ts >> 24), UInt8((ts >> 16) & 0xFF), UInt8((ts >> 8) & 0xFF), UInt8(ts & 0xFF), 0, 0, 0, 1])
                    rtp.append(payload)
                    seq &+= 1
                    var frame = Data([0x24, 0, UInt8(rtp.count >> 8), UInt8(rtp.count & 0xFF)])
                    frame.append(rtp)
                    c.send(content: frame, completion: .idempotent)
                }
            }
        }
        return seq
    }

    private func packetize(_ nal: Data) -> [Data] {
        let max = 1200
        guard nal.count > max else { return [nal] }
        var out: [Data] = []
        let b = [UInt8](nal)
        if codec == .h264 {
            let header = b[0]
            var i = 1
            while i < b.count {
                let n = min(max, b.count - i)
                var p = Data([(header & 0xE0) | 28, (i == 1 ? 0x80 : 0) | (i + n == b.count ? 0x40 : 0) | (header & 0x1F)])
                p.append(contentsOf: b[i..<(i + n)]); out.append(p); i += n
            }
        } else {
            let type = (b[0] >> 1) & 0x3F
            var i = 2
            while i < b.count {
                let n = min(max, b.count - i)
                var p = Data([(b[0] & 0x81) | (49 << 1), b[1], (i == 2 ? 0x80 : 0) | (i + n == b.count ? 0x40 : 0) | type])
                p.append(contentsOf: b[i..<(i + n)]); out.append(p); i += n
            }
        }
        return out
    }
}

@Suite(.serialized) struct IPCamTests {
    static func makeClip(_ codec: RTSPClient.Codec) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("doorstep-test-\(codec.rawValue).\(codec == .h264 ? "h264" : "h265")")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let enc = codec == .h264 ? ["-c:v", "libx264", "-x264-params", "aud=1:keyint=30", "-bsf:v", "h264_mp4toannexb", "-f", "h264"]
                                 : ["-c:v", "libx265", "-x265-params", "aud=1:keyint=30:log-level=error", "-f", "hevc"]
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30", "-t", "2", "-pix_fmt", "yuv420p"] + enc + [out.path]
        try p.run(); p.waitUntilExit()
        return out
    }

    func play(_ codec: RTSPClient.Codec, password: String = "secret") async throws -> (frames: Int, size: CGSize) {
        let cam = try FakeCamera(file: try Self.makeClip(codec), codec: codec)
        defer { cam.stop() }
        let stream = try #require(IPStream(url: URL(string: "rtsp://admin:\(password)@127.0.0.1:\(cam.port)/live")!))
        final class Box: @unchecked Sendable { var size = CGSize.zero }
        let box = Box()
        stream.onFrame = { img in box.size = CGSize(width: CVPixelBufferGetWidth(img), height: CVPixelBufferGetHeight(img)) }
        try await stream.start()
        for _ in 0..<40 where stream.frames < 55 { try await Task.sleep(for: .milliseconds(100)) }
        stream.stop()
        return (stream.frames, box.size)
    }

    @Test func h264ThroughRTSPWithDigest() async throws {
        let r = try await play(.h264)
        #expect(r.frames >= 50, "decoded \(r.frames) of 60 frames")
        #expect(r.size == CGSize(width: 320, height: 240))
    }

    @Test func h265ThroughRTSP() async throws {
        let r = try await play(.h265)
        #expect(r.frames >= 50, "decoded \(r.frames) of 60 frames")
        #expect(r.size == CGSize(width: 320, height: 240))
    }

    @Test func wrongPasswordSaysSo() async throws {
        await #expect(throws: RTSPClient.Failure.signIn) { _ = try await play(.h264, password: "nope") }
    }

    @Test func sdpPicksTheVideoTrack() throws {
        let sdp = "m=audio 0 RTP/AVP 8\r\na=control:track2\r\nm=video 0 RTP/AVP 98\r\na=rtpmap:98 H265/90000\r\na=fmtp:98 sprop-vps=QAEMAf//;sprop-sps=QgEB;sprop-pps=RAHA\r\na=control:track1\r\n"
        let t = try RTSPClient.videoTrack(sdp: sdp, base: "rtsp://cam/stream")
        #expect(t.codec == .h265 && t.payloadType == 98 && t.control == "rtsp://cam/stream/track1" && t.parameterSets.count == 3)
        #expect(throws: RTSPClient.Failure.unsupported("MP2T")) {
            _ = try RTSPClient.videoTrack(sdp: "m=video 0 RTP/AVP 33\r\na=rtpmap:33 MP2T/90000\r\n", base: "rtsp://x")
        }
    }
}

@Suite struct ONVIFTests {
    @Test func probeMatchParsing() {
        let xml = """
        <SOAP-ENV:Envelope><SOAP-ENV:Body><d:ProbeMatches><d:ProbeMatch><d:Scopes>onvif://www.onvif.org/type/video_encoder \
        onvif://www.onvif.org/name/Back%20Garden onvif://www.onvif.org/hardware/RLC-510A</d:Scopes>\
        <d:XAddrs>http://192.168.1.40:8000/onvif/device_service http://[fe80::1]/onvif/device_service</d:XAddrs></d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>
        """
        let f = ONVIF.parseProbeMatches(xml)
        #expect(f.count == 1 && f[0].name == "Back Garden" && f[0].host == "192.168.1.40")
    }

    @Test func profilesAndStreamUri() {
        let profiles = "<trt:GetProfilesResponse><trt:Profiles fixed=\"true\" token=\"Profile_1\"><tt:Name>main</tt:Name></trt:Profiles><trt:Profiles token=\"Profile_2\"></trt:Profiles></trt:GetProfilesResponse>"
        #expect(ONVIF.profileTokens(profiles) == ["Profile_1", "Profile_2"])
        #expect(ONVIF.values("Uri", in: "<trt:MediaUri><tt:Uri>rtsp://192.168.1.40:554/h264Preview_01_main</tt:Uri></trt:MediaUri>")
            == ["rtsp://192.168.1.40:554/h264Preview_01_main"])
    }

    /// The WS-Security example from the ONVIF core spec's appendix.
    @Test func passwordDigestMatchesSpec() {
        let nonce = Data(base64Encoded: "LKqI6G/AikKCQrN0zqZFlg==")!
        #expect(ONVIF.passwordDigest(nonce: nonce, created: "2010-09-16T07:50:45Z", password: "userpassword") == "tuOSpGlFlIXsozq4HFNeeGeFLEI=")
    }
}

/// Not a real test: `DOORSTEP_FAKECAM_SECONDS=60 swift test --filter serveFakeCamera` keeps a
/// looping, no-password camera on rtsp://127.0.0.1:8554/live for checking the app by hand.
@Suite struct FakeCameraServer {
    @Test func serveFakeCamera() async throws {
        guard let s = ProcessInfo.processInfo.environment["DOORSTEP_FAKECAM_SECONDS"], let seconds = Double(s) else { return }
        let cam = try FakeCamera(file: try IPCamTests.makeClip(.h264), codec: .h264, port: 8554)
        cam.requireAuth = false
        cam.paced = true
        try await Task.sleep(for: .seconds(seconds))
        cam.stop()
    }
}
