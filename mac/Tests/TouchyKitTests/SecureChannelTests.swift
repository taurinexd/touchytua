import CryptoKit
import Foundation
import Testing
@testable import TouchyKit

private struct Pair {
    let macStatic = Curve25519.KeyAgreement.PrivateKey()
    let phoneStatic = Curve25519.KeyAgreement.PrivateKey()
    let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

    /// Runs a full handshake; returns (phone channel, mac channel).
    func connect(phoneSecret: Data?, macSecret: Data?, knownPhoneKey: Data?) throws -> (SecureChannel, SecureChannel) {
        let pe = Curve25519.KeyAgreement.PrivateKey(), me = Curve25519.KeyAgreement.PrivateKey()
        let hello = Handshake.phoneHello(phoneStatic: phoneStatic, ephemeral: pe, pairingSecret: phoneSecret)
        let accepted = try Handshake.macAccept(hello: hello, macStatic: macStatic, ephemeral: me,
                                               expectedSecret: macSecret, knownPhoneKey: knownPhoneKey)
        #expect(accepted.phoneKey == phoneStatic.publicKey.rawRepresentation)
        let phoneKeys = try Handshake.phoneFinish(reply: accepted.reply, phoneStatic: phoneStatic, ephemeral: pe,
                                                  macKey: macStatic.publicKey.rawRepresentation, pairingSecret: phoneSecret)
        return (SecureChannel(keys: phoneKeys), SecureChannel(keys: accepted.keys))
    }
}

@Suite struct SecureChannelTests {
    @Test func roundTrip() throws {
        let p = Pair()
        var (phone, mac) = try p.connect(phoneSecret: p.secret, macSecret: p.secret, knownPhoneKey: nil)
        #expect(try mac.open(phone.seal(Data("ciao mac".utf8))) == Data("ciao mac".utf8))
        #expect(try phone.open(mac.seal(Data("ciao phone".utf8))) == Data("ciao phone".utf8))
        // Reconnect after pairing: no secret, known phone key.
        var (phone2, mac2) = try p.connect(phoneSecret: nil, macSecret: nil,
                                           knownPhoneKey: p.phoneStatic.publicKey.rawRepresentation)
        #expect(try mac2.open(phone2.seal(Data("di nuovo".utf8))) == Data("di nuovo".utf8))
    }

    @Test func wrongSecretRejected() {
        let p = Pair()
        #expect(throws: HandshakeError.badSecret) {
            _ = try p.connect(phoneSecret: Data(repeating: 1, count: 32), macSecret: p.secret, knownPhoneKey: nil)
        }
    }

    @Test func missingSecretRejectedOnFirstPairing() {
        let p = Pair()
        #expect(throws: HandshakeError.badSecret) {
            _ = try p.connect(phoneSecret: nil, macSecret: p.secret, knownPhoneKey: nil)
        }
    }

    /// A QR waiting to be scanned must not lock out the phone already paired,
    /// and a new phone with a valid proof must be able to replace it.
    @Test func pairedPhoneReconnectsWhilePairingIsPending() throws {
        let p = Pair()
        _ = try p.connect(phoneSecret: nil, macSecret: p.secret, knownPhoneKey: p.phoneStatic.publicKey.rawRepresentation)
    }

    @Test func newPhoneWithProofAcceptedWhileAnotherIsPaired() throws {
        let p = Pair()
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        _ = try p.connect(phoneSecret: p.secret, macSecret: p.secret, knownPhoneKey: other)
    }

    /// Session keys are bound to the four public keys of the handshake.
    @Test func keysDependOnTheHandshakeTranscript() {
        let ikm = Data(repeating: 7, count: 64)
        let a = Handshake.derive(ikm, secret: nil, info: Handshake.phoneToMac, transcript: Data([1, 2, 3]))
        let b = Handshake.derive(ikm, secret: nil, info: Handshake.phoneToMac, transcript: Data([1, 2, 4]))
        #expect(a.withUnsafeBytes { Data($0) } != b.withUnsafeBytes { Data($0) })
    }

    /// Both sides announce their protocol version before any key exists.
    @Test func helloAndReplyCarryProtocolVersion() throws {
        let p = Pair()
        let pe = Curve25519.KeyAgreement.PrivateKey(), me = Curve25519.KeyAgreement.PrivateKey()
        let hello = Handshake.phoneHello(phoneStatic: p.phoneStatic, ephemeral: pe, pairingSecret: p.secret)
        #expect(Handshake.peerVersion(in: hello) == Handshake.protocolVersion)
        let accepted = try Handshake.macAccept(hello: hello, macStatic: p.macStatic, ephemeral: me,
                                               expectedSecret: p.secret, knownPhoneKey: nil)
        #expect(Handshake.peerVersion(in: accepted.reply) == Handshake.protocolVersion)
        #expect(Handshake.peerVersion(in: Data(#"{"phoneKey":"","ephemeral":""}"#.utf8)) == 1)
    }

    @Test func unknownPhoneRejected() {
        let p = Pair()
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        #expect(throws: HandshakeError.unknownPeer) {
            _ = try p.connect(phoneSecret: nil, macSecret: nil, knownPhoneKey: other)
        }
    }

    @Test func replayRejected() throws {
        let p = Pair()
        var (phone, mac) = try p.connect(phoneSecret: p.secret, macSecret: p.secret, knownPhoneKey: nil)
        let frame = try phone.seal(Data("una volta".utf8))
        _ = try mac.open(frame)
        #expect(throws: ChannelError.replay) { _ = try mac.open(frame) }
    }

    @Test func tamperRejected() throws {
        let p = Pair()
        var (phone, mac) = try p.connect(phoneSecret: p.secret, macSecret: p.secret, knownPhoneKey: nil)
        var frame = try phone.seal(Data("integro".utf8))
        frame[frame.count - 1] ^= 0x01
        #expect(throws: ChannelError.self) { _ = try mac.open(frame) }
    }

    @Test func qrRoundTrip() throws {
        let payload = PairingPayload(v: 1, macKey: Data(repeating: 7, count: 32), secret: Data(repeating: 9, count: 32),
                                     endpoints: ["lan:192.168.1.10:47311", "ts:mac.tail1234.ts.net:47311"], macName: "Mac")
        let url = payload.url()
        #expect(url.hasPrefix("touchytua://pair?d="))
        let encoded = String(url.dropFirst("touchytua://pair?d=".count))
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="), "base64url without padding")
        #expect(try PairingPayload.parse(url: url) == payload)
    }
}
