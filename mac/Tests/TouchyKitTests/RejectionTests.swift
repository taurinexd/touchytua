import CryptoKit
import Foundation
import Testing
@testable import TouchyProtocol

/// A refused handshake is answered, not just dropped, so the phone can tell
/// "this Mac said no" from "the network failed" or "some other Mac answered".
@Suite struct RejectionTests {
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let phone = Curve25519.KeyAgreement.PrivateKey()

    private func hello(secret: Data? = nil) -> Data {
        Handshake.phoneHello(phoneStatic: phone, ephemeral: Curve25519.KeyAgreement.PrivateKey(), pairingSecret: secret)
    }

    @Test func phoneReadsTheReasonFromItsMac() throws {
        let hello = hello()
        let reply = try #require(Handshake.macReject(hello: hello, macStatic: mac, reason: .unknownPeer))
        #expect(Handshake.rejection(in: reply, hello: hello, phoneStatic: phone,
                                    macKey: mac.publicKey.rawRepresentation) == .unknownPeer)
    }

    @Test func wrongSecretIsReported() throws {
        let hello = hello(secret: Data(repeating: 7, count: 32))
        let reply = try #require(Handshake.macReject(hello: hello, macStatic: mac, reason: .badSecret))
        #expect(Handshake.rejection(in: reply, hello: hello, phoneStatic: phone,
                                    macKey: mac.publicKey.rawRepresentation) == .badSecret)
    }

    /// Any host at that address can answer; only the paired Mac's word counts.
    @Test func rejectionFromAnotherMacIsNotBelieved() throws {
        let hello = hello()
        let other = Curve25519.KeyAgreement.PrivateKey()
        let reply = try #require(Handshake.macReject(hello: hello, macStatic: other, reason: .unknownPeer))
        #expect(Handshake.rejection(in: reply, hello: hello, phoneStatic: phone,
                                    macKey: mac.publicKey.rawRepresentation) == nil)
    }

    @Test func rejectionOfAnEarlierHelloIsNotBelieved() throws {
        let old = hello()
        let reply = try #require(Handshake.macReject(hello: old, macStatic: mac, reason: .unknownPeer))
        #expect(Handshake.rejection(in: reply, hello: hello(), phoneStatic: phone,
                                    macKey: mac.publicKey.rawRepresentation) == nil)
    }

    @Test func acceptedReplyIsNotARejection() throws {
        let hello = hello()
        let accepted = try Handshake.macAccept(
            hello: hello, macStatic: mac, ephemeral: Curve25519.KeyAgreement.PrivateKey(),
            expectedSecret: nil, knownPhoneKey: phone.publicKey.rawRepresentation)
        #expect(Handshake.rejection(in: accepted.reply, hello: hello, phoneStatic: phone,
                                    macKey: mac.publicKey.rawRepresentation) == nil)
    }

    @Test func unreadableHelloGetsNoAnswer() {
        #expect(Handshake.macReject(hello: Data("nope".utf8), macStatic: mac, reason: .malformed) == nil)
    }
}
