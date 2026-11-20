import Foundation
import CryptoKit

/// ONVIF, the standard most IP cameras speak: find them on the network, then ask one for
/// its RTSP address so nobody has to look it up.
public enum ONVIF {
    public struct Found: Sendable, Hashable, Identifiable {
        public var id: String { service.absoluteString }
        public var name: String
        public var service: URL         // device service address
        public var host: String { service.host ?? "" }
    }
    public enum Failure: Error, CustomStringConvertible {
        case signIn, noMedia, noProfiles, noStream, http(Int)
        public var description: String {
            switch self {
            case .signIn: return "The camera didn't accept the user name or password."
            case .noMedia: return "The camera didn't say where its video is."
            case .noProfiles: return "The camera has no video profiles."
            case .noStream: return "The camera didn't give a stream address."
            case .http(let c): return "The camera replied with an error (\(c))."
            }
        }
    }

    // MARK: Discovery (WS-Discovery, UDP multicast on this network only)

    public static func discover(seconds: Double = 3) async -> [Found] {
        await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning: probe(seconds: seconds)) }
        }
    }

    static func probe(seconds: Double) -> [Found] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var to = sockaddr_in()
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = in_port_t(3702).bigEndian
        to.sin_addr.s_addr = inet_addr("239.255.255.250")
        let message = Data(probeXML(UUID()).utf8)
        let sent = message.withUnsafeBytes { buf in
            withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard sent > 0 else { return [] }
        var found: [String: Found] = [:]
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue }
            for f in parseProbeMatches(String(decoding: buffer[0..<n], as: UTF8.self)) where found[f.host] == nil { found[f.host] = f }
        }
        return found.values.sorted { $0.host < $1.host }
    }

    static func probeXML(_ id: UUID) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" \
        xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:\(id.uuidString.lowercased())</w:MessageID>\
        <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>\
        <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>\
        <e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>
        """
    }

    static func parseProbeMatches(_ xml: String) -> [Found] {
        let addrs = values("XAddrs", in: xml)
        let scopes = values("Scopes", in: xml).joined(separator: " ")
        var name = "Camera"
        for s in scopes.split(separator: " ") {
            for key in ["onvif://www.onvif.org/name/", "onvif://www.onvif.org/hardware/"] where s.hasPrefix(key) && name == "Camera" {
                name = String(s.dropFirst(key.count)).removingPercentEncoding?.replacingOccurrences(of: "_", with: " ") ?? name
            }
        }
        return addrs.flatMap { $0.split(separator: " ") }.compactMap { URL(string: String($0)) }
            .filter { $0.host.map { !$0.contains(":") } ?? false }     // skip IPv6 addresses
            .prefix(1).map { Found(name: name, service: $0) }
    }

    /// Text inside every `<anyprefix:Tag>` element.
    static func values(_ tag: String, in xml: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<(?:[A-Za-z0-9_]+:)?\(tag)(?:\\s[^>]*)?>([^<]*)</(?:[A-Za-z0-9_]+:)?\(tag)>") else { return [] }
        return re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap {
            Range($0.range(at: 1), in: xml).map { String(xml[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    // MARK: Asking a camera for its stream

    public struct Stream: Sendable { public var rtsp: URL; public var profiles: Int }

    /// `smaller`: pick the camera's last profile, usually its lighter sub-stream.
    public static func stream(service: URL, user: String, password: String, smaller: Bool = false) async throws -> Stream {
        let offset = await clockOffset(service)
        let caps = try await call(service, body: "<GetCapabilities xmlns=\"http://www.onvif.org/ver10/device/wsdl\"><Category>Media</Category></GetCapabilities>",
                                  user: user, password: password, offset: offset)
        guard let mediaRange = caps.range(of: "Media", options: .caseInsensitive),
              let mediaURL = values("XAddr", in: String(caps[mediaRange.lowerBound...])).first.flatMap(URL.init(string:)) else { throw Failure.noMedia }
        let media = sameHost(mediaURL, as: service)
        let profiles = try await call(media, body: "<GetProfiles xmlns=\"http://www.onvif.org/ver10/media/wsdl\"/>",
                                      user: user, password: password, offset: offset)
        let tokens = profileTokens(profiles)
        guard let token = smaller ? tokens.last : tokens.first else { throw Failure.noProfiles }
        let reply = try await call(media, body: """
            <GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl"><StreamSetup>\
            <Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream>\
            <Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport></StreamSetup>\
            <ProfileToken>\(token)</ProfileToken></GetStreamUri>
            """, user: user, password: password, offset: offset)
        guard let raw = values("Uri", in: reply).first?.replacingOccurrences(of: "&amp;", with: "&"),
              let uri = URL(string: raw) else { throw Failure.noStream }
        return Stream(rtsp: sameHost(uri, as: service), profiles: tokens.count)
    }

    static func profileTokens(_ xml: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<(?:[A-Za-z0-9_]+:)?Profiles[^>]*\\stoken=\"([^\"]+)\"") else { return [] }
        return re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { Range($0.range(at: 1), in: xml).map { String(xml[$0]) } }
    }

    /// Cameras behind a router sometimes report an address the Mac can't reach; keep the one we used.
    static func sameHost(_ url: URL, as service: URL) -> URL {
        guard let host = service.host, var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.host != host else { return url }
        if let h = c.host, h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("172.") { return url }
        c.host = host
        return c.url ?? url
    }

    /// The camera's clock minus ours, so the sign-in timestamp is in its time.
    static func clockOffset(_ service: URL) async -> TimeInterval {
        guard let xml = try? await call(service, body: "<GetSystemDateAndTime xmlns=\"http://www.onvif.org/ver10/device/wsdl\"/>", user: nil, password: nil, offset: 0),
              let utc = xml.range(of: "UTCDateTime") else { return 0 }
        let part = String(xml[utc.lowerBound...])
        func n(_ tag: String) -> Int? { values(tag, in: part).first.flatMap { Int($0) } }
        guard let y = n("Year"), let mo = n("Month"), let d = n("Day"), let h = n("Hour"), let mi = n("Minute"), let s = n("Second") else { return 0 }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let camera = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)) else { return 0 }
        return camera.timeIntervalSinceNow
    }

    static func passwordDigest(nonce: Data, created: String, password: String) -> String {
        Data(Insecure.SHA1.hash(data: nonce + Data(created.utf8) + Data(password.utf8))).base64EncodedString()
    }

    static func call(_ url: URL, body: String, user: String?, password: String?, offset: TimeInterval) async throws -> String {
        var header = ""
        if let user, let password {
            var nonce = Data(count: 16)
            _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
            let created = f.string(from: Date().addingTimeInterval(offset))
            header = """
            <s:Header><Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">\
            <UsernameToken><Username>\(xmlEscape(user))</Username>\
            <Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(passwordDigest(nonce: nonce, created: created, password: password))</Password>\
            <Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</Nonce>\
            <Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\(created)</Created>\
            </UsernameToken></Security></s:Header>
            """
        }
        var r = URLRequest(url: url, timeoutInterval: 8)
        r.httpMethod = "POST"
        r.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\">\(header)<s:Body>\(body)</s:Body></s:Envelope>".utf8)
        let (data, response) = try await URLSession.shared.data(for: r)
        let text = String(decoding: data, as: UTF8.self)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || text.contains("NotAuthorized") || text.contains("FailedAuthentication") { throw Failure.signIn }
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        return text
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
