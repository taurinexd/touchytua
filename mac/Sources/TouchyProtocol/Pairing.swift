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

public enum HandshakeError: String, Error, Equatable, Sendable {
    case badSecret = "bad_secret"
    case unknownPeer = "unknown_peer"
    case malformed
}

public struct SessionKeys: Sendable {
    public let send: SymmetricKey
    public let receive: SymmetricKey
}

/// Connection handshake (spec in docs/protocol.md):
/// ikm = DH(e_mac, e_phone) || DH(s_mac, s_phone);
/// key = HKDF-SHA256(ikm, salt: "touchytua-v1" || pairingSecret?,
///                    info: direction || the four public keys).
/// Static-static DH authenticates both ends; ephemerals give forward secrecy.
/// First pairing additionally proves knowledge of the QR secret.
public enum Handshake {
    /// Sent in clear by both sides before any key exists, so that either
    /// can tell the other is older or newer. Absent means 1.
    public static let protocolVersion = 1

    struct Hello: Codable {
        let phoneKey: Data
        let ephemeral: Data
        let proof: Data?
        var v: Int? = Handshake.protocolVersion
    }

    struct Reply: Codable {
        let ephemeral: Data
        var v: Int? = Handshake.protocolVersion
    }

    private struct Versioned: Decodable { let v: Int? }

    /// The protocol version announced in a hello or a reply.
    public static func peerVersion(in message: Data) -> Int {
        (try? JSONDecoder().decode(Versioned.self, from: message))?.v ?? 1
    }

    /// The four public keys of a handshake, in a fixed order; mixed into
    /// the key derivation so the keys are bound to this exact exchange.
    static func transcript(macStatic: Data, phoneStatic: Data, macEphemeral: Data, phoneEphemeral: Data) -> Data {
        macStatic + phoneStatic + macEphemeral + phoneEphemeral
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
    ) throws -> (reply: Data, keys: SessionKeys, phoneKey: Data, isNewPairing: Bool) {
        guard let h = try? JSONDecoder().decode(Hello.self, from: hello),
              let phoneStaticPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: h.phoneKey),
              let phoneEphPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: h.ephemeral) else {
            throw HandshakeError.malformed
        }
        // A hello with a proof is a first pairing and needs the pending QR
        // secret; one without is a reconnection and needs the paired key.
        // Deciding on the hello keeps the paired phone working while a QR
        // waits to be scanned.
        var secretForSalt: Data?
        if let proof = h.proof {
            guard let expectedSecret,
                  HMAC<SHA256>.isValidAuthenticationCode(
                      proof, authenticating: h.phoneKey + h.ephemeral, using: SymmetricKey(data: expectedSecret))
            else { throw HandshakeError.badSecret }
            secretForSalt = expectedSecret
        } else {
            guard let knownPhoneKey else {
                throw expectedSecret == nil ? HandshakeError.unknownPeer : HandshakeError.badSecret
            }
            guard h.phoneKey == knownPhoneKey else { throw HandshakeError.unknownPeer }
        }
        let ikm = try ephemeral.sharedSecretFromKeyAgreement(with: phoneEphPub).raw
            + macStatic.sharedSecretFromKeyAgreement(with: phoneStaticPub).raw
        let bound = transcript(
            macStatic: macStatic.publicKey.rawRepresentation, phoneStatic: h.phoneKey,
            macEphemeral: ephemeral.publicKey.rawRepresentation, phoneEphemeral: h.ephemeral)
        let keys = SessionKeys(
            send: derive(ikm, secret: secretForSalt, info: macToPhone, transcript: bound),
            receive: derive(ikm, secret: secretForSalt, info: phoneToMac, transcript: bound))
        let reply = try JSONEncoder().encode(Reply(ephemeral: ephemeral.publicKey.rawRepresentation))
        return (reply, keys, h.phoneKey, secretForSalt != nil)
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
        let bound = transcript(
            macStatic: macKey, phoneStatic: phoneStatic.publicKey.rawRepresentation,
            macEphemeral: r.ephemeral, phoneEphemeral: ephemeral.publicKey.rawRepresentation)
        return SessionKeys(
            send: derive(ikm, secret: pairingSecret, info: phoneToMac, transcript: bound),
            receive: derive(ikm, secret: pairingSecret, info: macToPhone, transcript: bound))
    }

    struct Rejection: Codable {
        let error: String
        /// HMAC over the hello, keyed from DH(s_mac, s_phone).
        let mac: Data
        var v: Int? = Handshake.protocolVersion
    }

    /// The Mac's answer to a hello it refuses. Authenticated with the static
    /// keys, so the phone believes it only from the Mac it paired with, and
    /// only for the hello it just sent. Nil when the hello carries no usable
    /// phone key: then there is nobody to answer.
    public static func macReject(
        hello: Data, macStatic: Curve25519.KeyAgreement.PrivateKey, reason: HandshakeError
    ) -> Data? {
        guard let h = try? JSONDecoder().decode(Hello.self, from: hello),
              let phone = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: h.phoneKey),
              let shared = try? macStatic.sharedSecretFromKeyAgreement(with: phone) else { return nil }
        let mac = Data(HMAC<SHA256>.authenticationCode(for: hello, using: rejectionKey(shared.raw)))
        return try? JSONEncoder().encode(Rejection(error: reason.rawValue, mac: mac))
    }

    /// Why the paired Mac refused `hello`, or nil if `reply` is not a
    /// rejection that Mac wrote for this hello.
    public static func rejection(
        in reply: Data, hello: Data, phoneStatic: Curve25519.KeyAgreement.PrivateKey, macKey: Data
    ) -> HandshakeError? {
        guard let r = try? JSONDecoder().decode(Rejection.self, from: reply),
              let reason = HandshakeError(rawValue: r.error),
              let mac = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey),
              let shared = try? phoneStatic.sharedSecretFromKeyAgreement(with: mac),
              HMAC<SHA256>.isValidAuthenticationCode(r.mac, authenticating: hello, using: rejectionKey(shared.raw))
        else { return nil }
        return reason
    }

    static func rejectionKey(_ staticShared: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: staticShared),
            salt: Data("touchytua-v1".utf8), info: Data("reject".utf8), outputByteCount: 32)
    }

    static func proofFor(secret: Data, phoneKey: Data, ephemeral: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: phoneKey + ephemeral, using: SymmetricKey(data: secret)))
    }

    static func derive(_ ikm: Data, secret: Data?, info: Data, transcript: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data("touchytua-v1".utf8) + (secret ?? Data()),
            info: info + transcript, outputByteCount: 32)
    }
}

extension SharedSecret {
    var raw: Data { withUnsafeBytes { Data($0) } }
}
