import Foundation

// The protobuf messages push-receiver uses, hand-coded field by field from its
// src/protos/mcs.proto, checkin.proto and android_checkin.proto (which are
// Chromium's google_apis/gcm/protocol/*.proto). Field numbers must match those.

// MARK: - MCS tags (push-receiver src/constants.ts, MCSProtoTag)

enum MCSTag: UInt8, Sendable {
    case heartbeatPing = 0
    case heartbeatAck = 1
    case loginRequest = 2
    case loginResponse = 3
    case close = 4
    case messageStanza = 5
    case presenceStanza = 6
    case iqStanza = 7
    case dataMessageStanza = 8
    case batchPresenceStanza = 9
    case streamErrorStanza = 10
    case httpRequest = 11
    case httpResponse = 12
    case bindAccountRequest = 13
    case bindAccountResponse = 14
    case talkMetadata = 15
}

enum MCSConstants {
    /// kMCSVersion in push-receiver src/constants.ts.
    static let version: UInt8 = 41
    /// The parser also accepts 38 (push-receiver parser.ts #handleGotVersion).
    static let legacyAcceptedVersion: UInt8 = 38
    static let host = "mtalk.google.com"
    static let port: UInt16 = 5228
}

// MARK: - Shared sub-messages

struct MCSSetting: Sendable, Equatable {
    var name: String
    var value: String

    func encode() -> Data {
        var w = ProtoWriter()
        w.writeString(1, name)
        w.writeString(2, value)
        return w.data
    }

    static func decode(_ data: Data) throws -> MCSSetting {
        let f = try ProtoReader.fields(data)
        return MCSSetting(name: try f.string(1) ?? "", value: try f.string(2) ?? "")
    }
}

struct MCSHeartbeatStat: Sendable, Equatable {
    var ip: String
    var timeout: Bool
    var intervalMs: Int32

    func encode() -> Data {
        var w = ProtoWriter()
        w.writeString(1, ip)
        w.writeBool(2, timeout)
        w.writeInt32(3, intervalMs)
        return w.data
    }
}

struct MCSErrorInfo: Sendable, Equatable {
    var code: Int32
    var message: String?
    var type: String?

    func encode() -> Data {
        var w = ProtoWriter()
        w.writeInt32(1, code)
        if let message { w.writeString(2, message) }
        if let type { w.writeString(3, type) }
        return w.data
    }

    static func decode(_ data: Data) throws -> MCSErrorInfo {
        let f = try ProtoReader.fields(data)
        return MCSErrorInfo(code: f.first(1)?.int32 ?? 0, message: try f.string(2), type: try f.string(3))
    }
}

// MARK: - LoginRequest (tag 2)

struct MCSLoginRequest: Sendable, Equatable {
    var id: String
    var domain: String
    var user: String
    var resource: String
    var authToken: String
    var deviceId: String?
    var settings: [MCSSetting] = []
    var receivedPersistentIds: [String] = []
    var adaptiveHeartbeat: Bool?
    var heartbeatStat: MCSHeartbeatStat?
    var useRmq2: Bool?
    var authService: Int32?
    var networkType: Int32?

    /// Built exactly like push-receiver client.ts #sendLogin.
    static func make(androidId: String, securityToken: String, chromeVersion: String,
                     persistentIds: [String], heartbeatIntervalMs: Int32) -> MCSLoginRequest {
        let hexAndroidId = UInt64(androidId).map { String($0, radix: 16) } ?? androidId
        return MCSLoginRequest(
            id: "chrome-\(chromeVersion)",
            domain: "mcs.android.com",
            user: androidId,
            resource: androidId,
            authToken: securityToken,
            deviceId: "android-\(hexAndroidId)",
            settings: [MCSSetting(name: "new_vc", value: "1")],
            receivedPersistentIds: persistentIds,
            adaptiveHeartbeat: false,
            heartbeatStat: heartbeatIntervalMs > 0
                ? MCSHeartbeatStat(ip: "", timeout: true, intervalMs: heartbeatIntervalMs) : nil,
            useRmq2: true,
            authService: 2, // ANDROID_ID
            networkType: 1
        )
    }

    func encode() -> Data {
        var w = ProtoWriter()
        w.writeString(1, id)
        w.writeString(2, domain)
        w.writeString(3, user)
        w.writeString(4, resource)
        w.writeString(5, authToken)
        if let deviceId { w.writeString(6, deviceId) }
        for s in settings { w.writeMessage(8, s.encode()) }
        for p in receivedPersistentIds { w.writeString(10, p) }
        if let adaptiveHeartbeat { w.writeBool(12, adaptiveHeartbeat) }
        if let heartbeatStat { w.writeMessage(13, heartbeatStat.encode()) }
        if let useRmq2 { w.writeBool(14, useRmq2) }
        if let authService { w.writeInt32(16, authService) }
        if let networkType { w.writeInt32(17, networkType) }
        return w.data
    }

    static func decode(_ data: Data) throws -> MCSLoginRequest {
        let f = try ProtoReader.fields(data)
        return MCSLoginRequest(
            id: try f.string(1) ?? "",
            domain: try f.string(2) ?? "",
            user: try f.string(3) ?? "",
            resource: try f.string(4) ?? "",
            authToken: try f.string(5) ?? "",
            deviceId: try f.string(6),
            settings: try f.all(8).compactMap(\.data).map(MCSSetting.decode),
            receivedPersistentIds: f.all(10).compactMap(\.string),
            adaptiveHeartbeat: f.first(12)?.bool,
            heartbeatStat: nil,
            useRmq2: f.first(14)?.bool,
            authService: f.first(16)?.int32,
            networkType: f.first(17)?.int32
        )
    }
}

// MARK: - LoginResponse (tag 3)

struct MCSLoginResponse: Sendable, Equatable {
    var id: String
    var jid: String?
    var error: MCSErrorInfo?
    var settings: [MCSSetting] = []
    var streamId: Int32?
    var lastStreamIdReceived: Int32?
    var heartbeatIntervalMs: Int32?
    var serverTimestamp: Int64?

    func encode() -> Data {
        var w = ProtoWriter()
        w.writeString(1, id)
        if let jid { w.writeString(2, jid) }
        if let error { w.writeMessage(3, error.encode()) }
        for s in settings { w.writeMessage(4, s.encode()) }
        if let streamId { w.writeInt32(5, streamId) }
        if let lastStreamIdReceived { w.writeInt32(6, lastStreamIdReceived) }
        if let heartbeatIntervalMs {
            var hb = ProtoWriter()
            hb.writeInt32(3, heartbeatIntervalMs)
            w.writeMessage(7, hb.data)
        }
        if let serverTimestamp { w.writeInt64(8, serverTimestamp) }
        return w.data
    }

    static func decode(_ data: Data) throws -> MCSLoginResponse {
        let f = try ProtoReader.fields(data)
        var interval: Int32?
        if let hb = f.first(7)?.data {
            interval = try ProtoReader.fields(hb).first(3)?.int32
        }
        return MCSLoginResponse(
            id: try f.string(1) ?? "",
            jid: try f.string(2),
            error: try f.first(3)?.data.map(MCSErrorInfo.decode),
            settings: try f.all(4).compactMap(\.data).map(MCSSetting.decode),
            streamId: f.first(5)?.int32,
            lastStreamIdReceived: f.first(6)?.int32,
            heartbeatIntervalMs: interval,
            serverTimestamp: f.first(8)?.int64
        )
    }
}

// MARK: - HeartbeatPing (tag 0) / HeartbeatAck (tag 1): same shape

struct MCSHeartbeat: Sendable, Equatable {
    var streamId: Int32?
    var lastStreamIdReceived: Int32?
    var status: Int64?

    func encode() -> Data {
        var w = ProtoWriter()
        if let streamId { w.writeInt32(1, streamId) }
        if let lastStreamIdReceived { w.writeInt32(2, lastStreamIdReceived) }
        if let status { w.writeInt64(3, status) }
        return w.data
    }

    static func decode(_ data: Data) throws -> MCSHeartbeat {
        let f = try ProtoReader.fields(data)
        return MCSHeartbeat(streamId: f.first(1)?.int32,
                            lastStreamIdReceived: f.first(2)?.int32,
                            status: f.first(3)?.int64)
    }
}

// MARK: - DataMessageStanza (tag 8)

struct MCSAppData: Sendable, Equatable {
    var key: String
    var value: String
}

struct MCSDataMessageStanza: Sendable, Equatable {
    var id: String?
    var from: String
    var to: String?
    var category: String
    var token: String?
    var appData: [MCSAppData] = []
    var fromTrustedServer: Bool?
    var persistentId: String?
    var streamId: Int32?
    var lastStreamIdReceived: Int32?
    var regId: String?
    var deviceUserId: Int64?
    var ttl: Int32?
    var sent: Int64?
    var queued: Int32?
    var status: Int64?
    var rawData: Data?
    var immediateAck: Bool?

    func appDataValue(_ key: String) -> String? {
        appData.first { $0.key == key }?.value
    }

    func encode() -> Data {
        var w = ProtoWriter()
        if let id { w.writeString(2, id) }
        w.writeString(3, from)
        if let to { w.writeString(4, to) }
        w.writeString(5, category)
        if let token { w.writeString(6, token) }
        for a in appData {
            var aw = ProtoWriter()
            aw.writeString(1, a.key)
            aw.writeString(2, a.value)
            w.writeMessage(7, aw.data)
        }
        if let fromTrustedServer { w.writeBool(8, fromTrustedServer) }
        if let persistentId { w.writeString(9, persistentId) }
        if let streamId { w.writeInt32(10, streamId) }
        if let lastStreamIdReceived { w.writeInt32(11, lastStreamIdReceived) }
        if let regId { w.writeString(13, regId) }
        if let deviceUserId { w.writeInt64(16, deviceUserId) }
        if let ttl { w.writeInt32(17, ttl) }
        if let sent { w.writeInt64(18, sent) }
        if let queued { w.writeInt32(19, queued) }
        if let status { w.writeInt64(20, status) }
        if let rawData { w.writeBytes(21, rawData) }
        if let immediateAck { w.writeBool(24, immediateAck) }
        return w.data
    }

    static func decode(_ data: Data) throws -> MCSDataMessageStanza {
        let f = try ProtoReader.fields(data)
        let appData: [MCSAppData] = try f.all(7).compactMap(\.data).map { d in
            let af = try ProtoReader.fields(d)
            return MCSAppData(key: try af.string(1) ?? "", value: try af.string(2) ?? "")
        }
        return MCSDataMessageStanza(
            id: try f.string(2),
            from: try f.string(3) ?? "",
            to: try f.string(4),
            category: try f.string(5) ?? "",
            token: try f.string(6),
            appData: appData,
            fromTrustedServer: f.first(8)?.bool,
            persistentId: try f.string(9),
            streamId: f.first(10)?.int32,
            lastStreamIdReceived: f.first(11)?.int32,
            regId: try f.string(13),
            deviceUserId: f.first(16)?.int64,
            ttl: f.first(17)?.int32,
            sent: f.first(18)?.int64,
            queued: f.first(19)?.int32,
            status: f.first(20)?.int64,
            rawData: f.first(21)?.data,
            immediateAck: f.first(24)?.bool
        )
    }
}

// MARK: - Close (tag 4), StreamErrorStanza (tag 10), IqStanza (tag 7)

struct MCSStreamError: Sendable, Equatable {
    var type: String
    var text: String?

    static func decode(_ data: Data) throws -> MCSStreamError {
        let f = try ProtoReader.fields(data)
        return MCSStreamError(type: try f.string(1) ?? "", text: try f.string(2))
    }
}

/// push-receiver only logs IqStanzas; we decode the bits worth logging.
struct MCSIqStanza: Sendable, Equatable {
    var type: Int32
    var id: String
    var extensionId: Int32?

    static func decode(_ data: Data) throws -> MCSIqStanza {
        let f = try ProtoReader.fields(data)
        var extId: Int32?
        if let ext = f.first(7)?.data { extId = try ProtoReader.fields(ext).first(1)?.int32 }
        return MCSIqStanza(type: f.first(2)?.int32 ?? 0, id: try f.string(3) ?? "", extensionId: extId)
    }
}

// MARK: - Android checkin (checkin.proto / android_checkin.proto)

struct AndroidCheckinRequest: Sendable, Equatable {
    // ChromeBuildProto.Platform: PLATFORM_MAC = 2. Channel: CHANNEL_STABLE = 1.
    // DeviceType: DEVICE_CHROME_BROWSER = 3.
    var chromePlatform: Int32 = 2
    var chromeVersion: String
    var chromeChannel: Int32 = 1
    var deviceType: Int32 = 3
    var androidId: UInt64?
    var securityToken: UInt64?
    var timeZone: String
    var version: Int32 = 3

    /// Mirrors push-receiver gcm.ts prepareCheckinBuffer, including the empty
    /// "optional" strings and zeros it sets (protobufjs writes every set field).
    func encode() -> Data {
        var build = ProtoWriter()
        build.writeInt32(1, chromePlatform)
        build.writeString(2, chromeVersion)
        build.writeInt32(3, chromeChannel)

        var checkin = ProtoWriter()
        checkin.writeInt64(2, 0)        // last_checkin_msec
        checkin.writeString(6, "")      // cell_operator
        checkin.writeString(7, "")      // sim_operator
        checkin.writeString(8, "")      // roaming
        checkin.writeInt32(9, 0)        // user_number
        checkin.writeInt32(12, deviceType)
        checkin.writeMessage(13, build.data)

        var w = ProtoWriter()
        if let androidId { w.writeInt64(2, Int64(bitPattern: androidId)) }
        w.writeString(3, "")            // digest
        w.writeMessage(4, checkin.data)
        w.writeString(5, "")            // desired_build
        w.writeString(6, "")            // locale
        w.writeInt64(7, 0)              // logging_id
        w.writeString(8, "")            // market_checkin
        w.writeString(12, timeZone)
        if let securityToken { w.writeFixed64(13, securityToken) }
        w.writeInt32(14, version)
        w.writeInt32(20, 0)             // fragment
        w.writeString(21, "")           // user_name
        w.writeInt32(22, 0)             // user_serial_number
        return w.data
    }

    static func decode(_ data: Data) throws -> AndroidCheckinRequest {
        let f = try ProtoReader.fields(data)
        var platform: Int32 = 0, version = "", channel: Int32 = 0, type: Int32 = 0
        if let checkin = f.first(4)?.data {
            let cf = try ProtoReader.fields(checkin)
            type = cf.first(12)?.int32 ?? 0
            if let b = cf.first(13)?.data {
                let bf = try ProtoReader.fields(b)
                platform = bf.first(1)?.int32 ?? 0
                version = try bf.string(2) ?? ""
                channel = bf.first(3)?.int32 ?? 0
            }
        }
        return AndroidCheckinRequest(
            chromePlatform: platform, chromeVersion: version, chromeChannel: channel,
            deviceType: type, androidId: f.first(2)?.uint64, securityToken: f.first(13)?.uint64,
            timeZone: try f.string(12) ?? "", version: f.first(14)?.int32 ?? 0
        )
    }
}

struct AndroidCheckinResponse: Sendable, Equatable {
    var statsOk: Bool
    var timeMsec: Int64?
    var androidId: UInt64?
    var securityToken: UInt64?
    var versionInfo: String?

    func encode() -> Data {
        var w = ProtoWriter()
        w.writeBool(1, statsOk)
        if let timeMsec { w.writeInt64(3, timeMsec) }
        if let androidId { w.writeFixed64(7, androidId) }
        if let securityToken { w.writeFixed64(8, securityToken) }
        if let versionInfo { w.writeString(11, versionInfo) }
        return w.data
    }

    static func decode(_ data: Data) throws -> AndroidCheckinResponse {
        let f = try ProtoReader.fields(data)
        guard let ok = f.first(1)?.bool else { throw ProtoError.missingRequiredField("stats_ok") }
        return AndroidCheckinResponse(statsOk: ok, timeMsec: f.first(3)?.int64,
                                      androidId: f.first(7)?.uint64, securityToken: f.first(8)?.uint64,
                                      versionInfo: try f.string(11))
    }
}
