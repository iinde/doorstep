import CryptoKit
import Foundation

// push-receiver registers as a Chrome *web push* client, so FCM delivers each
// message encrypted with the legacy "aesgcm" content encoding
// (draft-ietf-webpush-encryption-03 / draft-ietf-httpbis-encryption-encoding-03).
// This is a port of push-receiver src/utils/decrypt.ts plus the parts of the
// `http_ece` npm module it calls (version 'aesgcm', keylabel 'P-256', rs 4096).

enum WebPushError: Error, Equatable, Sendable {
    case missingCryptoKey
    case missingSalt
    case missingDH
    case badBase64(String)
    case badKey
    case truncatedPayload
    case recordTooSmall
    case badPadding
    case authenticationFailed
}

/// The receiver's keys, generated once and persisted with the credentials.
/// Same shape as push-receiver src/keys.ts (prime256v1 ECDH + 16 random bytes).
struct WebPushKeys: Sendable, Equatable {
    let privateKey: Data   // 32-byte raw P-256 scalar
    let publicKey: Data    // 65-byte uncompressed point (0x04 || X || Y)
    let authSecret: Data   // 16 random bytes

    static func generate() -> WebPushKeys {
        let key = P256.KeyAgreement.PrivateKey()
        var secret = Data(count: 16)
        secret.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return WebPushKeys(privateKey: key.rawRepresentation, publicKey: key.publicKey.x963Representation,
                           authSecret: secret)
    }
}

enum Base64URL {
    /// push-receiver's escape(): standard base64 with '=' dropped, '+' -> '-', '/' -> '_'.
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// Accepts base64url or standard base64, padded or not.
    static func decode(_ string: String) -> Data? {
        var s = string.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

enum WebPushAESGCM {
    static let tagLength = 16
    static let defaultRecordSize = 4096
    static let padSize = 2

    /// "dh=abc; p256ecdsa=def" -> ["dh": "abc", "p256ecdsa": "def"] (decrypt.ts parseHeaderParams).
    static func parseHeaderParams(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = pieces[0].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            out[key] = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : ""
        }
        return out
    }

    /// Decrypts a DataMessageStanza's raw_data using its `crypto-key` and
    /// `encryption` app_data headers. Returns the plaintext (a JSON document).
    static func decrypt(stanza: MCSDataMessageStanza, keys: WebPushKeys) throws -> Data {
        guard let cryptoKey = stanza.appDataValue("crypto-key") else { throw WebPushError.missingCryptoKey }
        guard let encryption = stanza.appDataValue("encryption") else { throw WebPushError.missingSalt }
        let ckParams = parseHeaderParams(cryptoKey)
        let encParams = parseHeaderParams(encryption)
        guard let dhString = ckParams["dh"], !dhString.isEmpty else { throw WebPushError.missingDH }
        guard let saltString = encParams["salt"], !saltString.isEmpty else { throw WebPushError.missingSalt }
        guard let dh = Base64URL.decode(dhString) else { throw WebPushError.badBase64("dh") }
        guard let salt = Base64URL.decode(saltString) else { throw WebPushError.badBase64("salt") }
        let rs = encParams["rs"].flatMap(Int.init) ?? defaultRecordSize
        return try decrypt(ciphertext: stanza.rawData ?? Data(), senderPublicKey: dh, salt: salt,
                           recordSize: rs, keys: keys)
    }

    static func decrypt(ciphertext: Data, senderPublicKey: Data, salt: Data,
                        recordSize: Int = defaultRecordSize, keys: WebPushKeys) throws -> Data {
        let (key, nonce) = try deriveKeyAndNonce(senderPublicKey: senderPublicKey,
                                                 receiverPublicKey: keys.publicKey,
                                                 agreementPrivateKey: keys.privateKey,
                                                 agreementPeerKey: senderPublicKey,
                                                 authSecret: keys.authSecret, salt: salt)
        let bytes = [UInt8](ciphertext)
        let chunkSize = recordSize + tagLength
        var result = Data()
        var start = 0
        var counter: UInt64 = 0
        while start < bytes.count {
            var end = start + chunkSize
            // aesgcm needs a final short record; a full-size last record means truncation.
            if end == bytes.count { throw WebPushError.truncatedPayload }
            end = min(end, bytes.count)
            if end - start <= tagLength { throw WebPushError.recordTooSmall }
            let record = Data(bytes[start..<end])
            result.append(try decryptRecord(record, key: key, nonce: recordNonce(nonce, counter)))
            start = end
            counter += 1
        }
        return result
    }

    /// Encrypts like a web push sender would. Only used by tests to produce
    /// realistic fixtures; the app never sends pushes.
    static func encrypt(plaintext: Data, receiverPublicKey: Data, authSecret: Data,
                        senderPrivateKey: P256.KeyAgreement.PrivateKey, salt: Data) throws -> Data {
        let senderPub = senderPrivateKey.publicKey.x963Representation
        let (key, nonce) = try deriveKeyAndNonce(senderPublicKey: senderPub, receiverPublicKey: receiverPublicKey,
                                                 agreementPrivateKey: senderPrivateKey.rawRepresentation,
                                                 agreementPeerKey: receiverPublicKey,
                                                 authSecret: authSecret, salt: salt)
        var padded = Data([0, 0])
        padded.append(plaintext)
        let sealed = try AES.GCM.seal(padded, using: key, nonce: AES.GCM.Nonce(data: recordNonce(nonce, 0)))
        return sealed.ciphertext + sealed.tag
    }

    // MARK: - Internals

    private static func info(_ base: String, _ context: Data) -> Data {
        var d = Data("Content-Encoding: \(base)".utf8)
        d.append(0)
        d.append(context)
        return d
    }

    private static func lengthPrefixed(_ d: Data) -> Data {
        var out = Data([UInt8(d.count >> 8 & 0xFF), UInt8(d.count & 0xFF)])
        out.append(d)
        return out
    }

    private static func hkdf(salt: Data, ikm: Data, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                                         info: info, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    private static func deriveKeyAndNonce(senderPublicKey: Data, receiverPublicKey: Data,
                                          agreementPrivateKey: Data, agreementPeerKey: Data,
                                          authSecret: Data, salt: Data) throws -> (SymmetricKey, Data) {
        let priv: P256.KeyAgreement.PrivateKey
        let peer: P256.KeyAgreement.PublicKey
        do {
            priv = try P256.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKey)
            peer = try P256.KeyAgreement.PublicKey(x963Representation: agreementPeerKey)
        } catch {
            throw WebPushError.badKey
        }
        let shared = try priv.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }

        // http_ece extractDH: context = "P-256\0" || len(receiver) || receiver || len(sender) || sender
        var context = Data("P-256".utf8)
        context.append(0)
        context.append(lengthPrefixed(receiverPublicKey))
        context.append(lengthPrefixed(senderPublicKey))

        // authSecret mixes in first: HKDF(salt: auth, ikm: ecdh, info: "Content-Encoding: auth\0", 32)
        let secret = hkdf(salt: authSecret, ikm: shared, info: info("auth", Data()), length: 32)
        let key = hkdf(salt: salt, ikm: secret, info: info("aesgcm", context), length: 16)
        let nonce = hkdf(salt: salt, ikm: secret, info: info("nonce", context), length: 12)
        return (SymmetricKey(data: key), nonce)
    }

    /// XOR the record counter into the last 6 bytes of the base nonce (http_ece generateNonce).
    static func recordNonce(_ base: Data, _ counter: UInt64) -> Data {
        var n = [UInt8](base)
        for i in 0..<6 {
            n[n.count - 1 - i] ^= UInt8(truncatingIfNeeded: counter >> (8 * UInt64(i)))
        }
        return Data(n)
    }

    private static func decryptRecord(_ record: Data, key: SymmetricKey, nonce: Data) throws -> Data {
        let body = record.prefix(record.count - tagLength)
        let tag = record.suffix(tagLength)
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: body, tag: tag)
            plain = try AES.GCM.open(box, using: key)
        } catch {
            throw WebPushError.authenticationFailed
        }
        // aesgcm padding: 2-byte big-endian pad length, then that many zero bytes.
        let p = [UInt8](plain)
        guard p.count >= padSize else { throw WebPushError.badPadding }
        let pad = Int(p[0]) << 8 | Int(p[1])
        guard pad + padSize <= p.count else { throw WebPushError.badPadding }
        guard p[padSize..<(padSize + pad)].allSatisfy({ $0 == 0 }) else { throw WebPushError.badPadding }
        return Data(p[(padSize + pad)...])
    }
}
