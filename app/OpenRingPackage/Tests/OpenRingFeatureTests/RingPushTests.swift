import CryptoKit
import Foundation
import Testing
@testable import RingClient

// Tests for the native Ring push (FCM/MCS) port. Nothing here touches the network.

// MARK: - Protobuf

@Suite struct RingPushProtobufTests {
    @Test func varintEncoding() {
        #expect([UInt8](ProtoWriter.varint(0)) == [0x00])
        #expect([UInt8](ProtoWriter.varint(1)) == [0x01])
        #expect([UInt8](ProtoWriter.varint(127)) == [0x7F])
        #expect([UInt8](ProtoWriter.varint(128)) == [0x80, 0x01])
        #expect([UInt8](ProtoWriter.varint(300)) == [0xAC, 0x02])
        #expect(ProtoWriter.varint(UInt64.max).count == 10)
    }

    @Test func varintRoundTrip() throws {
        for v: UInt64 in [0, 1, 127, 128, 16_383, 16_384, 1 << 35, UInt64(Int64.max), UInt64.max] {
            let bytes = [UInt8](ProtoWriter.varint(v))
            let (decoded, len) = try ProtoReader.readVarint(bytes, at: 0)
            #expect(decoded == v)
            #expect(len == bytes.count)
        }
    }

    @Test func truncatedVarintIsReportedAsTruncated() {
        #expect(throws: ProtoError.truncated) { try ProtoReader.readVarint([0x80, 0x80], at: 0) }
        #expect(throws: ProtoError.truncated) { try ProtoReader.readVarint([], at: 0) }
    }

    @Test func negativeInt32IsSignExtended() throws {
        var w = ProtoWriter()
        w.writeInt32(1, -1)
        #expect(w.data.count == 11) // key + 10-byte varint
        let f = try ProtoReader.fields(w.data)
        #expect(f.first(1)?.int32 == -1)
    }

    @Test func knownBytes() {
        // HeartbeatPing { last_stream_id_received: 5 } -> field 2 varint 5
        #expect([UInt8](MCSHeartbeat(lastStreamIdReceived: 5).encode()) == [0x10, 0x05])
        var w = ProtoWriter()
        w.writeString(1, "ab")
        #expect([UInt8](w.data) == [0x0A, 0x02, 0x61, 0x62])
        var f = ProtoWriter()
        f.writeFixed64(7, 0x0102030405060708)
        #expect([UInt8](f.data) == [0x39, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    }

    @Test func truncatedLengthDelimitedThrows() {
        #expect(throws: ProtoError.truncated) { try ProtoReader.fields(Data([0x0A, 0x05, 0x61])) }
    }

    @Test func loginRequestMatchesPushReceiver() throws {
        let login = MCSLoginRequest.make(androidId: "5123456789012345678", securityToken: "987654321",
                                         chromeVersion: "94.0.4606.51", persistentIds: ["0:1", "0:2"],
                                         heartbeatIntervalMs: 300_000)
        #expect(login.id == "chrome-94.0.4606.51")
        #expect(login.domain == "mcs.android.com")
        #expect(login.deviceId == "android-\(String(UInt64(5123456789012345678), radix: 16))")
        #expect(login.user == "5123456789012345678")
        #expect(login.resource == "5123456789012345678")
        #expect(login.authService == 2)
        #expect(login.settings == [MCSSetting(name: "new_vc", value: "1")])

        let decoded = try MCSLoginRequest.decode(login.encode())
        var expected = login
        expected.heartbeatStat = nil // not decoded (client-to-server only)
        #expect(decoded == expected)
        #expect(decoded.receivedPersistentIds == ["0:1", "0:2"])
    }

    @Test func loginResponseRoundTrip() throws {
        let r = MCSLoginResponse(id: "chrome-94", jid: "x@mcs", error: MCSErrorInfo(code: 3, message: "bad", type: nil),
                                 settings: [MCSSetting(name: "a", value: "b")], streamId: 1,
                                 lastStreamIdReceived: 2, heartbeatIntervalMs: 60_000, serverTimestamp: 1_700_000_000_000)
        #expect(try MCSLoginResponse.decode(r.encode()) == r)
    }

    @Test func dataMessageStanzaRoundTrip() throws {
        let s = MCSDataMessageStanza(
            id: "id1", from: "876313859327", category: "org.chromium.linux",
            appData: [MCSAppData(key: "crypto-key", value: "dh=abc"), MCSAppData(key: "encryption", value: "salt=def")],
            persistentId: "0:1700000000000%abc", ttl: 2_419_200, sent: 1_700_000_000_000,
            rawData: Data([1, 2, 3, 0xFF]), immediateAck: true)
        let d = try MCSDataMessageStanza.decode(s.encode())
        #expect(d == s)
        #expect(d.appDataValue("encryption") == "salt=def")
    }

    @Test func heartbeatRoundTrip() throws {
        let h = MCSHeartbeat(streamId: 3, lastStreamIdReceived: 9, status: 1)
        #expect(try MCSHeartbeat.decode(h.encode()) == h)
        #expect(try MCSHeartbeat.decode(Data()) == MCSHeartbeat())
    }

    @Test func checkinRequestRoundTrip() throws {
        let r = AndroidCheckinRequest(chromeVersion: "94.0.4606.51", androidId: 5_123_456_789_012_345_678,
                                      securityToken: UInt64.max - 7, timeZone: "Europe/London")
        let d = try AndroidCheckinRequest.decode(r.encode())
        #expect(d == r)
        #expect(d.deviceType == 3)     // DEVICE_CHROME_BROWSER
        #expect(d.chromePlatform == 2) // PLATFORM_MAC
        #expect(d.version == 3)
        // Without saved credentials neither id nor token is sent.
        let fresh = try ProtoReader.fields(AndroidCheckinRequest(chromeVersion: "1", timeZone: "UTC").encode())
        #expect(fresh.first(2) == nil)
        #expect(fresh.first(13) == nil)
    }

    @Test func checkinResponseDecodesFixed64Ids() throws {
        var bytes: [UInt8] = [0x08, 0x01] // stats_ok = true
        bytes += [0x39] + withUnsafeBytes(of: UInt64(4_000_000_000_123).littleEndian, Array.init) // android_id
        bytes += [0x41] + withUnsafeBytes(of: UInt64(0xFEDC_BA98_7654_3210).littleEndian, Array.init) // security_token
        let r = try AndroidCheckinResponse.decode(Data(bytes))
        #expect(r.statsOk)
        #expect(r.androidId == 4_000_000_000_123)
        #expect(r.securityToken == 0xFEDC_BA98_7654_3210)
        #expect(throws: ProtoError.missingRequiredField("stats_ok")) { try AndroidCheckinResponse.decode(Data()) }
    }
}

// MARK: - MCS framing

@Suite struct RingPushFramingTests {
    private func serverStream() -> (Data, [MCSFrame]) {
        let login = MCSLoginResponse(id: "chrome-94.0.4606.51", streamId: 1).encode()
        let stanza = MCSDataMessageStanza(from: "876313859327", category: "org.chromium.linux",
                                          persistentId: "0:1", rawData: Data(repeating: 0xAB, count: 300)).encode()
        var d = Data([41])
        d.append(MCSFrameEncoder.frame(tag: .loginResponse, payload: login))
        d.append(MCSFrameEncoder.frame(tag: .heartbeatPing, payload: Data()))
        d.append(MCSFrameEncoder.frame(tag: .dataMessageStanza, payload: stanza))
        d.append(MCSFrameEncoder.frame(tag: .close, payload: Data()))
        return (d, [MCSFrame(tag: 3, payload: login), MCSFrame(tag: 0, payload: Data()),
                    MCSFrame(tag: 8, payload: stanza), MCSFrame(tag: 4, payload: Data())])
    }

    @Test func loginPacketStartsWithVersionAndTag() throws {
        let login = MCSLoginRequest.make(androidId: "1", securityToken: "2", chromeVersion: "94.0.4606.51",
                                         persistentIds: [], heartbeatIntervalMs: 300_000)
        let packet = [UInt8](MCSFrameEncoder.loginPacket(login))
        #expect(packet[0] == 41)
        #expect(packet[1] == 2)
        let (size, n) = try ProtoReader.readVarint(packet, at: 2)
        #expect(Int(size) == packet.count - 2 - n)
    }

    @Test func parsesWholeStream() throws {
        let (stream, expected) = serverStream()
        var p = MCSFrameParser()
        #expect(try p.feed(stream) == expected)
        #expect(p.serverVersion == 41)
        #expect(p.bufferedByteCount == 0)
    }

    @Test func parsesByteByByte() throws {
        let (stream, expected) = serverStream()
        var p = MCSFrameParser()
        var got: [MCSFrame] = []
        for b in stream { got += try p.feed(Data([b])) }
        #expect(got == expected)
    }

    @Test func parsesAtEverySplitPoint() throws {
        let (stream, expected) = serverStream()
        for cut in 1..<stream.count {
            var p = MCSFrameParser()
            var got = try p.feed(stream.prefix(cut))
            got += try p.feed(stream.suffix(from: cut))
            #expect(got == expected, "split at \(cut)")
        }
    }

    @Test func acceptsLegacyVersion38AndRejectsOld() throws {
        var ok = MCSFrameParser()
        #expect(try ok.feed(Data([38, 1, 0])) == [MCSFrame(tag: 1, payload: Data())])
        var bad = MCSFrameParser()
        #expect(throws: MCSFramingError.badVersion(40)) { try bad.feed(Data([40, 1, 0])) }
    }

    @Test func rejectsHugeFrames() {
        var p = MCSFrameParser(expectingVersion: false)
        var d = Data([8])
        d.append(ProtoWriter.varint(UInt64(MCSFrameParser.maxFrameSize + 1)))
        #expect(throws: MCSFramingError.self) { try p.feed(d) }
    }
}

// MARK: - Web push decryption (aesgcm)

/// Vectors produced by an independent sender written against Node's built-in
/// crypto (ECDH prime256v1, hkdfSync, aes-128-gcm), following http_ece's aesgcm.
private enum NodeVectors {
    struct V { let receiverPrivate, receiverPublic, auth, senderPublic, salt, ciphertext: String; let plaintextLength: Int }
    static let small = V(receiverPrivate: "gvPpxpXca40bEYGNVwGRniht6NR_fD6zEAxIX3nleCg", receiverPublic: "BD3QXdBH69H0I8HwSpC1jhQH92irPgFEMk8OGZfAgPw-3LStnU0QIyRgm_2uKrxU8-_2tFq1NEqMgA4ZUTgOQC8", auth: "hUykOMkKxAUyTh58ud7D2A",
                         senderPublic: "BN7-wMCuy33z6TYj1mhsDy5lT7FnT-Kw9mqBVAnxv3jCHfEt-zQoKjz3O8fnqnBy7FCfYIjPhf1IapDUd4FF4wQ", salt: "vAVa8t2edNhUVF95wmX7Sg", ciphertext: "ZmH1L8Icy8IufjLBjEj60T5/0p/7emfTm0Ro8jEDBl1l0RlNZGwDygt3FfI2vhFguDnNW8i6GauiLty4vOgTJD6H3pO5", plaintextLength: 48)
    static let smallPlaintext = #"{"data":{"hello":"world"},"from":"876313859327"}"#
    static let big = V(receiverPrivate: "23f9Aa-VciGkmJtks3cKg6PFYGhAW58OlAj-rlf9F-Q", receiverPublic: "BL5Z_1L70HaLFq3mel_HB9u2_782ct9JwbNx4Ug5zOwb5Ir-g0Wl7HiLGB34N0PtBJDoqnQZucHKSP0StVYx-YE", auth: "PXeZZ9PQthXZBL_tu7bONg",
                       senderPublic: "BAUTu9i1O8UMEQLGTsevu9tXrmAEIT5Blm8OvmNvm1R6KWez4ZAxJiaqaMBzFXXGXWOTkLWRf93UOiWEFldbwTk", salt: "ILwUeZB7tVo53QnK9qMGtg", ciphertext: "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", plaintextLength: 5000)

    static func keys(_ v: V) -> WebPushKeys {
        WebPushKeys(privateKey: Base64URL.decode(v.receiverPrivate)!, publicKey: Base64URL.decode(v.receiverPublic)!,
                    authSecret: Base64URL.decode(v.auth)!)
    }
}

@Suite struct RingPushCryptoTests {
    @Test func decryptsIndependentVectorWithPadding() throws {
        let v = NodeVectors.small
        let plain = try WebPushAESGCM.decrypt(ciphertext: Data(base64Encoded: v.ciphertext)!,
                                              senderPublicKey: Base64URL.decode(v.senderPublic)!,
                                              salt: Base64URL.decode(v.salt)!, keys: NodeVectors.keys(v))
        #expect(String(decoding: plain, as: UTF8.self) == NodeVectors.smallPlaintext)
    }

    @Test func decryptsMultiRecordVector() throws {
        let v = NodeVectors.big
        let plain = try WebPushAESGCM.decrypt(ciphertext: Data(base64Encoded: v.ciphertext)!,
                                              senderPublicKey: Base64URL.decode(v.senderPublic)!,
                                              salt: Base64URL.decode(v.salt)!, keys: NodeVectors.keys(v))
        #expect(plain == Data(repeating: UInt8(ascii: "x"), count: v.plaintextLength))
    }

    @Test func decryptsFromStanzaHeaders() throws {
        let v = NodeVectors.small
        let stanza = MCSDataMessageStanza(
            from: "876313859327", category: "org.chromium.linux",
            appData: [MCSAppData(key: "crypto-key", value: "dh=\(v.senderPublic); p256ecdsa=ignored"),
                      MCSAppData(key: "encryption", value: "salt=\(v.salt)")],
            rawData: Data(base64Encoded: v.ciphertext)!)
        let plain = try WebPushAESGCM.decrypt(stanza: stanza, keys: NodeVectors.keys(v))
        #expect(String(decoding: plain, as: UTF8.self) == NodeVectors.smallPlaintext)
    }

    @Test func tamperingIsDetected() throws {
        let v = NodeVectors.small
        var ct = Data(base64Encoded: v.ciphertext)!
        ct[5] ^= 0x01
        #expect(throws: WebPushError.authenticationFailed) {
            try WebPushAESGCM.decrypt(ciphertext: ct, senderPublicKey: Base64URL.decode(v.senderPublic)!,
                                      salt: Base64URL.decode(v.salt)!, keys: NodeVectors.keys(v))
        }
    }

    @Test func missingHeadersAreReported() {
        let keys = WebPushKeys.generate()
        let none = MCSDataMessageStanza(from: "x", category: "y", rawData: Data([1]))
        #expect(throws: WebPushError.missingCryptoKey) { try WebPushAESGCM.decrypt(stanza: none, keys: keys) }
        let noSalt = MCSDataMessageStanza(from: "x", category: "y",
                                          appData: [MCSAppData(key: "crypto-key", value: "dh=AAAA")], rawData: Data([1]))
        #expect(throws: WebPushError.missingSalt) { try WebPushAESGCM.decrypt(stanza: noSalt, keys: keys) }
    }

    @Test func encryptDecryptRoundTrip() throws {
        let keys = WebPushKeys.generate()
        #expect(keys.privateKey.count == 32)
        #expect(keys.publicKey.count == 65)
        #expect(keys.authSecret.count == 16)
        let sender = P256.KeyAgreement.PrivateKey()
        let salt = Data((0..<16).map { UInt8($0) })
        let msg = Data(#"{"data":{"x":"1"}}"#.utf8)
        let ct = try WebPushAESGCM.encrypt(plaintext: msg, receiverPublicKey: keys.publicKey,
                                           authSecret: keys.authSecret, senderPrivateKey: sender, salt: salt)
        let pt = try WebPushAESGCM.decrypt(ciphertext: ct, senderPublicKey: sender.publicKey.x963Representation,
                                           salt: salt, keys: keys)
        #expect(pt == msg)
    }

    @Test func recordNonceXorsCounter() {
        let base = Data(repeating: 0, count: 12)
        #expect([UInt8](WebPushAESGCM.recordNonce(base, 0x0102)) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2])
    }

    @Test func headerParams() {
        #expect(WebPushAESGCM.parseHeaderParams("dh=abc=; p256ecdsa=def") == ["dh": "abc=", "p256ecdsa": "def"])
    }

    @Test func base64url() {
        let d = Data([0xFB, 0xFF, 0xFE])
        #expect(Base64URL.encode(d) == "-__-")
        #expect(Base64URL.decode("-__-") == d)
        #expect(Base64URL.decode("+//+") == d)
    }
}

// MARK: - Registration request builders

@Suite struct RingPushRegistrationTests {
    @Test func register3Body() throws {
        let r = FCMRegistrar.register3Request(androidId: "123", securityToken: "456", appId: "wp:receiver.push.com#abc-def")
        #expect(r.url?.absoluteString == "https://android.clients.google.com/c2dm/register3")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "AidLogin 123:456")
        let body = String(decoding: r.httpBody!, as: UTF8.self)
        #expect(body == "app=org.chromium.linux&X-subtype=wp%3Areceiver.push.com%23abc-def&device=123&sender="
                + RingPushConstants.defaultChromeSender)
    }

    @Test func register3Responses() throws {
        #expect(try FCMRegistrar.parseRegister3("token=abc:DEF\n") == "abc:DEF")
        #expect(throws: PushRegistrationError.registerFailed("PHONE_REGISTRATION_ERROR")) {
            try FCMRegistrar.parseRegister3("Error=PHONE_REGISTRATION_ERROR")
        }
    }

    @Test func checkinRequestCarriesSavedIds() throws {
        let gcm = PushCredentials.GCM(androidId: "42", securityToken: "18446744073709551615", token: "t", appId: "a")
        let r = FCMRegistrar.checkinRequest(existing: gcm, timeZone: "Europe/London")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/x-protobuf")
        let decoded = try AndroidCheckinRequest.decode(r.httpBody!)
        #expect(decoded.androidId == 42)
        #expect(decoded.securityToken == UInt64.max)
        #expect(decoded.chromeVersion == "94.0.4606.51")
    }

    @Test func fidShape() {
        let fid = FCMRegistrar.generateFID(randomBytes: [UInt8](repeating: 0xFF, count: 17))
        #expect(fid.count == 22)
        #expect(fid.hasPrefix("f"))
        for _ in 0..<50 {
            let f = FCMRegistrar.generateFID()
            #expect(f.count == 22)
            #expect("cdef".contains(f.first!))
            #expect(f.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
    }

    @Test func installationRequest() throws {
        let r = FCMRegistrar.installationRequest(fid: "fAAAAAAAAAAAAAAAAAAAAA")
        #expect(r.url?.absoluteString == "https://firebaseinstallations.googleapis.com/v1/projects/ring-17770/installations")
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaSyCv-hdFBmmdBBJadNy-TFwB-xN_H5m3Bk8")
        #expect(r.value(forHTTPHeaderField: "x-firebase-client") == "eyJoZWFydGJlYXRzIjpbXSwidmVyc2lvbiI6Mn0=")
        let json = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: String]
        #expect(json == ["appId": "1:876313859327:android:e10ec6ddb3c81f39", "authVersion": "FIS_v2",
                         "fid": "fAAAAAAAAAAAAAAAAAAAAA", "sdkVersion": "w:0.6.6"])
    }

    @Test func installationRefreshRequest() {
        let inst = PushCredentials.Installation(token: "t", createdAt: Date(), expiresIn: 604_800,
                                                refreshToken: "rt", fid: "c-_x")
        let r = FCMRegistrar.installationRefreshRequest(inst)
        #expect(r.url?.absoluteString
                == "https://firebaseinstallations.googleapis.com/v1/projects/ring-17770/installations/c-_x/authTokens:generate")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "FIS_v2 rt")
        #expect(FCMRegistrar.parseDuration("604800s") == 604_800)
    }

    @Test func fcmRegistrationRequest() throws {
        let keys = WebPushKeys.generate()
        let r = FCMRegistrar.fcmRegistrationRequest(gcmToken: "GCMTOKEN", installationToken: "FIS", keys: keys)
        #expect(r.url?.absoluteString == "https://fcmregistrations.googleapis.com/v1/projects/ring-17770/registrations")
        #expect(r.value(forHTTPHeaderField: "x-goog-firebase-installations-auth") == "FIS")
        let json = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: [String: String]]
        let web = json["web"]!
        #expect(web["endpoint"] == "https://fcm.googleapis.com/fcm/send/GCMTOKEN")
        #expect(web["applicationPubKey"] == nil)
        #expect(Base64URL.decode(web["p256dh"]!) == keys.publicKey)
        #expect(Base64URL.decode(web["auth"]!) == keys.authSecret)
    }

    @Test func ringDeviceBodyMatchesDgreif() throws {
        let json = try JSONSerialization.jsonObject(with: RingPush.ringDeviceBody(token: "FCMTOKEN")) as! [String: Any]
        let device = json["device"] as! [String: Any]
        #expect(device["os"] as? String == "android")
        #expect(device["push_notification_token"] as? String == "FCMTOKEN")
        let meta = device["metadata"] as! [String: Any]
        #expect(meta["pn_service"] as? String == "fcm")
        #expect(meta["pn_dict_version"] as? String == "2.0.0")
        #expect(meta["api_version"] as? Int == 11)
    }

    @Test func credentialsCodableAndValidity() throws {
        let inst = PushCredentials.Installation(token: "t", createdAt: Date(timeIntervalSince1970: 0), expiresIn: 604_800,
                                                refreshToken: "r", fid: "f")
        let c = PushCredentials(gcm: .init(androidId: "1", securityToken: "2", token: "g", appId: "a"),
                                fcm: .init(token: "fcm", installation: inst),
                                keys: .init(WebPushKeys.generate()), config: .current, tokenRegisteredWithRing: nil)
        let back = try JSONDecoder().decode(PushCredentials.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        #expect(back.isUsable)
        #expect(back.keys.webPushKeys?.publicKey.count == 65)
        #expect(inst.isExpired())
        #expect(!inst.isExpired(now: Date(timeIntervalSince1970: 1000)))
        var other = c
        other.config.projectId = "something-else"
        #expect(!other.isUsable)
    }

    @Test func persistentIds() {
        var s = PersistentIdState()
        s.record("a"); s.record("b"); s.record("a")
        #expect(s.pendingAck == ["a", "b"])
        #expect(s.hasSeen("a"))
        s.record("c")
        s.loginAcknowledged(sent: ["a", "b"])
        #expect(s.pendingAck == ["c"])
        #expect(s.hasSeen("b"))
        for i in 0..<500 { s.record("x\(i)") }
        #expect(s.recent.count == PersistentIdState.recentLimit)
        #expect(!s.hasSeen("a"))
    }
}

// MARK: - Ring payloads

@Suite struct RingPushPayloadTests {
    /// Wraps a Ring notification the way FCM delivers it: each top-level key's
    /// value is a JSON *string* inside `data` (dgreif parses each one).
    private func fcmMessage(_ notification: [String: Any]) throws -> Data {
        var data: [String: String] = [:]
        for (k, v) in notification {
            if let s = v as? String { data[k] = s; continue }
            data[k] = String(decoding: try JSONSerialization.data(withJSONObject: v), as: UTF8.self)
        }
        return try JSONSerialization.data(withJSONObject: ["data": data, "from": "876313859327",
                                                           "priority": "high", "fcmMessageId": "m1"])
    }

    /// Shaped like dgreif/ring test/live-updates.spec.ts processPushNotification fixture.
    private func v2(category: String, subtype: String, detection: String?, dingId: Any = "ding-uuid-1") -> [String: Any] {
        var ding: [String: Any] = ["id": dingId, "created_at": "2024-01-01T00:00:00Z", "subtype": subtype]
        if let detection { ding["detection_type"] = detection }
        return [
            "version": "2.0.0",
            "android_config": ["category": category, "body": "Motion detected at Front Door"],
            "analytics": ["server_correlation_id": "c1", "server_id": "com.ring.pns", "subcategory": subtype,
                          "triggered_at": 0, "sent_at": 0, "referring_item_type": "device", "referring_item_id": "1001"],
            "data": [
                "device": ["e2ee_enabled": false, "id": 1001, "kind": "lpd_v1", "name": "Front Door"],
                "event": [
                    "ding": ding,
                    "eventito": ["type": detection ?? subtype, "timestamp": 0],
                    "riid": "r1", "is_sidewalk": false,
                    "live_session": ["streaming_data_hash": "h", "active_streaming_profile": "rms",
                                     "default_audio_route": "speaker", "max_duration": 60],
                ],
                "location": ["id": "loc-1"],
            ],
        ]
    }

    private func event(_ n: [String: Any]) throws -> RingPushEvent? {
        if case .event(let e) = RingPushParser.parse(decryptedMessage: try fcmMessage(n)) { return e }
        return nil
    }

    @Test func v2Motion() throws {
        let e = try #require(try event(v2(category: "com.ring.pn.live-event.motion", subtype: "motion", detection: "motion")))
        #expect(e.kind == .motion)
        #expect(e.deviceId == 1001)
        #expect(e.deviceName == "Front Door")
        #expect(e.eventId == "ding-uuid-1")
        #expect(e.createdAt == ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z"))
        #expect(e.personDetected == false)
        #expect(e.category == "com.ring.pn.live-event.motion")
    }

    @Test func v2HumanMotion() throws {
        let e = try #require(try event(v2(category: "com.ring.pn.live-event.motion", subtype: "human", detection: "human")))
        #expect(e.kind == .motion)
        #expect(e.personDetected == true)
    }

    @Test func v2Ding() throws {
        let e = try #require(try event(v2(category: "com.ring.pn.live-event.ding", subtype: "ding", detection: nil)))
        #expect(e.kind == .ding)
        #expect(e.personDetected == nil)
    }

    @Test func intercomDingIsADing() throws {
        let e = try #require(try event(v2(category: "com.ring.pn.live-event.intercom", subtype: "ding", detection: nil)))
        #expect(e.kind == .ding)
    }

    @Test func numericDingIdKeepsAllDigits() throws {
        let e = try #require(try event(v2(category: "com.ring.pn.live-event.motion", subtype: "motion",
                                          detection: nil, dingId: Int64(7_345_678_901_234_567_891))))
        #expect(e.eventId == "7345678901234567891")
    }

    @Test func fractionalCreatedAt() throws {
        var n = v2(category: "com.ring.pn.live-event.ding", subtype: "ding", detection: nil)
        var data = n["data"] as! [String: Any]
        var ev = data["event"] as! [String: Any]
        var ding = ev["ding"] as! [String: Any]
        ding["created_at"] = "2024-05-06T07:08:09.123Z"
        ev["ding"] = ding; data["event"] = ev; n["data"] = data
        let e = try #require(try event(n))
        #expect(abs(e.createdAt.timeIntervalSince1970 - 1_714_979_289.123) < 0.001)
    }

    @Test func unknownCategoryFallsBackToSubtype() throws {
        let e = try #require(try event(v2(category: "com.ring.pn.something-new", subtype: "other_motion", detection: nil)))
        #expect(e.kind == .motion)
    }

    @Test func alarmGcmData() throws {
        let n: [String: Any] = ["data": ["gcmData": [
            "aps": ["alert": "Alarm mode changed"],
            "action": "com.ring.push.HANDLE_NEW_SECURITY_PANEL_MODE_NONE_NOTICE",
            "alarm_meta": ["device_zid": 555, "location_id": "loc-1"],
        ]]]
        let e = try #require(try event(n))
        #expect(e.kind == .other)
        #expect(e.deviceId == 555)
        #expect(e.category == "com.ring.push.HANDLE_NEW_SECURITY_PANEL_MODE_NONE_NOTICE")
    }

    @Test func legacyDing() throws {
        let n: [String: Any] = [
            "action": "com.ring.push.HANDLE_NEW_DING",
            "ding": ["id": Int64(6_000_000_000_000_000_001), "created_at": "2020-01-01T00:00:00.000Z",
                     "doorbot_id": 99, "doorbot_description": "Back Door"],
        ]
        let e = try #require(try event(n))
        #expect(e.kind == .ding)
        #expect(e.deviceId == 99)
        #expect(e.deviceName == "Back Door")
        #expect(e.eventId == "6000000000000000001")
    }

    @Test func unknownFormatsAreIgnored() throws {
        if case .event = RingPushParser.parse(decryptedMessage: try fcmMessage(["foo": "bar"])) { Issue.record("parsed") }
        if case .event = RingPushParser.parse(decryptedMessage: Data("not json".utf8)) { Issue.record("parsed") }
        if case .event = RingPushParser.parse(decryptedMessage: Data("{}".utf8)) { Issue.record("parsed") }
    }

    /// The whole path: encrypt a Ring v2 message as a web push, decrypt it from an MCS stanza, parse it.
    @Test func endToEndFromStanza() throws {
        let keys = WebPushKeys.generate()
        let sender = P256.KeyAgreement.PrivateKey()
        let salt = Data((0..<16).map { UInt8($0 * 3) })
        let plaintext = try fcmMessage(v2(category: "com.ring.pn.live-event.ding", subtype: "ding", detection: nil))
        let ct = try WebPushAESGCM.encrypt(plaintext: plaintext, receiverPublicKey: keys.publicKey,
                                           authSecret: keys.authSecret, senderPrivateKey: sender, salt: salt)
        let stanza = MCSDataMessageStanza(
            from: "876313859327", category: "org.chromium.linux",
            appData: [MCSAppData(key: "crypto-key", value: "dh=" + Base64URL.encode(sender.publicKey.x963Representation)),
                      MCSAppData(key: "encryption", value: "salt=" + Base64URL.encode(salt))],
            persistentId: "0:1", rawData: ct)
        var parser = MCSFrameParser()
        var wire = Data([41])
        wire.append(MCSFrameEncoder.frame(tag: .dataMessageStanza, payload: stanza.encode()))
        let frame = try #require(try parser.feed(wire).first)
        let decoded = try MCSDataMessageStanza.decode(frame.payload)
        let plain = try WebPushAESGCM.decrypt(stanza: decoded, keys: keys)
        guard case .event(let e) = RingPushParser.parse(decryptedMessage: plain) else {
            Issue.record("not parsed"); return
        }
        #expect(e.kind == .ding)
        #expect(e.deviceId == 1001)
    }
}
