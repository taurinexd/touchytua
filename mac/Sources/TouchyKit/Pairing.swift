import CryptoKit
import Foundation

/// What the QR shown by `/pair` carries.
public struct PairingPayload: Codable, Equatable, Sendable {
    public let v: Int
    /// The Mac's static X25519 public key (32 bytes).
    public let macKey: Data
    /// One-time pairing secret (32 bytes), invalidated after first use.
    public let secret: Data
    /// "lan:host:port" and/or "ts:name.ts.net:port".
    public let endpoints: [String]
    public let macName: String

    public init(v: Int, macKey: Data, secret: Data, endpoints: [String], macName: String) {
        self.v = v
        self.macKey = macKey
        self.secret = secret
        self.endpoints = endpoints
        self.macName = macName
    }

    static let prefix = "touchytua://pair?d="

    public func url() -> String {
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + Base64URL.encode(json)
    }

    public static func parse(url: String) throws -> PairingPayload {
        guard url.hasPrefix(prefix), let json = Base64URL.decode(String(url.dropFirst(prefix.count))) else {
            throw HandshakeError.malformed
        }
        return try JSONDecoder().decode(PairingPayload.self, from: json)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

public enum HandshakeError: Error, Equatable {
    case badSecret, unknownPeer, malformed
}

public struct SessionKeys: Sendable {
    public let send: SymmetricKey
    public let receive: SymmetricKey
}

/// Connection handshake (spec in docs/protocol.md):
/// ikm = DH(e_mac, e_phone) || DH(s_mac, s_phone);
/// key = HKDF-SHA256(ikm, salt: "touchytua-v1" || pairingSecret?, info: direction).
/// Static-static DH authenticates both ends; ephemerals give forward secrecy.
/// First pairing additionally proves knowledge of the QR secret.
public enum Handshake {
    struct Hello: Codable {
        let phoneKey: Data
        let ephemeral: Data
        let proof: Data?
    }

    struct Reply: Codable {
        let ephemeral: Data
    }

    static let phoneToMac = Data("phone->mac".utf8)
    static let macToPhone = Data("mac->phone".utf8)

    public static func phoneHello(
        phoneStatic: Curve25519.KeyAgreement.PrivateKey,
        ephemeral: Curve25519.KeyAgreement.PrivateKey,
        pairingSecret: Data?
    ) -> Data {
        let phoneKey = phoneStatic.publicKey.rawRepresentation
        let eph = ephemeral.publicKey.rawRepresentation
        let proof = pairingSecret.map { proofFor(secret: $0, phoneKey: phoneKey, ephemeral: eph) }
        return (try? JSONEncoder().encode(Hello(phoneKey: phoneKey, ephemeral: eph, proof: proof))) ?? Data()
    }

    public static func macAccept(
        hello: Data,
        macStatic: Curve25519.KeyAgreement.PrivateKey,
        ephemeral: Curve25519.KeyAgreement.PrivateKey,
        expectedSecret: Data?,
        knownPhoneKey: Data?
    ) throws -> (reply: Data, keys: SessionKeys, phoneKey: Data) {
        guard let h = try? JSONDecoder().decode(Hello.self, from: hello),
              let phoneStaticPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: h.phoneKey),
              let phoneEphPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: h.ephemeral) else {
            throw HandshakeError.malformed
        }
        var secretForSalt: Data?
        if let knownPhoneKey {
            guard h.phoneKey == knownPhoneKey else { throw HandshakeError.unknownPeer }
        } else {
            guard let expectedSecret, let proof = h.proof,
                  HMAC<SHA256>.isValidAuthenticationCode(
                      proof, authenticating: h.phoneKey + h.ephemeral, using: SymmetricKey(data: expectedSecret))
            else { throw HandshakeError.badSecret }
            secretForSalt = expectedSecret
        }
        let ikm = try ephemeral.sharedSecretFromKeyAgreement(with: phoneEphPub).raw
            + macStatic.sharedSecretFromKeyAgreement(with: phoneStaticPub).raw
        let keys = SessionKeys(
            send: derive(ikm, secret: secretForSalt, info: macToPhone),
            receive: derive(ikm, secret: secretForSalt, info: phoneToMac))
        let reply = try JSONEncoder().encode(Reply(ephemeral: ephemeral.publicKey.rawRepresentation))
        return (reply, keys, h.phoneKey)
    }

    public static func phoneFinish(
        reply: Data,
        phoneStatic: Curve25519.KeyAgreement.PrivateKey,
        ephemeral: Curve25519.KeyAgreement.PrivateKey,
        macKey: Data,
        pairingSecret: Data?
    ) throws -> SessionKeys {
        guard let r = try? JSONDecoder().decode(Reply.self, from: reply),
              let macEph = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: r.ephemeral),
              let macStatic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey) else {
            throw HandshakeError.malformed
        }
        let ikm = try ephemeral.sharedSecretFromKeyAgreement(with: macEph).raw
            + phoneStatic.sharedSecretFromKeyAgreement(with: macStatic).raw
        return SessionKeys(
            send: derive(ikm, secret: pairingSecret, info: phoneToMac),
            receive: derive(ikm, secret: pairingSecret, info: macToPhone))
    }

    static func proofFor(secret: Data, phoneKey: Data, ephemeral: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: phoneKey + ephemeral, using: SymmetricKey(data: secret)))
    }

    static func derive(_ ikm: Data, secret: Data?, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data("touchytua-v1".utf8) + (secret ?? Data()),
            info: info, outputByteCount: 32)
    }
}

extension SharedSecret {
    var raw: Data { withUnsafeBytes { Data($0) } }
}
