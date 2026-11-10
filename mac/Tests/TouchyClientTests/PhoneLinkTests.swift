import CryptoKit
import Foundation
import Testing
@testable import TouchyClient
import TouchyKit
import TouchyProtocol

@Suite struct PhoneLinkTests {
    let phoneKey = Curve25519.KeyAgreement.PrivateKey()
    let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

    @Test func firstPairingThenHelloGetsSnapshot() async throws {
        var mac = FakeMac()
        mac.pendingSecret = secret
        let (phoneEnd, macEnd) = MemoryTransport.pair()
        mac.serve(macEnd)
        let link = PhoneLink(transport: phoneEnd, phoneKey: phoneKey, macKey: mac.publicKey, pairingSecret: secret)
        #expect(try await link.open() == Handshake.protocolVersion)
        await link.send(.hello(deviceName: "iPhone"))
        #expect(try await link.next() == .snapshot(sessions: [], pending: [], usage: nil))
    }

    @Test func pairedPhoneReconnectsWithoutSecret() async throws {
        var mac = FakeMac()
        mac.knownPhoneKey = phoneKey.publicKey.rawRepresentation
        let (phoneEnd, macEnd) = MemoryTransport.pair()
        mac.serve(macEnd)
        let link = PhoneLink(transport: phoneEnd, phoneKey: phoneKey, macKey: mac.publicKey, pairingSecret: nil)
        _ = try await link.open()
        await link.send(.hello(deviceName: "iPhone"))
        guard case .snapshot = try await link.next() else { Issue.record("no snapshot"); return }
    }

    /// The Mac closes on a key it does not know: that is a rejection, not a network error.
    @Test func unknownPhoneIsRejected() async {
        var mac = FakeMac()
        mac.knownPhoneKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let (phoneEnd, macEnd) = MemoryTransport.pair()
        mac.serve(macEnd)
        let link = PhoneLink(transport: phoneEnd, phoneKey: phoneKey, macKey: mac.publicKey, pairingSecret: nil)
        await #expect(throws: LinkError.rejected) { _ = try await link.open() }
    }

    @Test func tamperedFrameIsRefused() async throws {
        var mac = FakeMac()
        mac.knownPhoneKey = phoneKey.publicKey.rawRepresentation
        let (phoneEnd, macEnd) = MemoryTransport.pair()
        mac.serve(macEnd)
        let link = PhoneLink(transport: phoneEnd, phoneKey: phoneKey, macKey: mac.publicKey, pairingSecret: nil)
        _ = try await link.open()
        phoneEnd.corrupt = { frame in
            var bad = frame
            bad[bad.count - 1] ^= 0x01
            return bad
        }
        await link.send(.hello(deviceName: "iPhone"))
        await #expect(throws: ChannelError.authentication) { _ = try await link.next() }
    }

    /// End to end through the real hub: the phone's decision reaches the hook.
    @Test func approvalFromThePhoneAnswersTheHook() async throws {
        var mac = FakeMac()
        mac.knownPhoneKey = phoneKey.publicKey.rawRepresentation
        let (phoneEnd, macEnd) = MemoryTransport.pair()
        mac.serve(macEnd)
        let hub = mac.hub
        let hook = Task {
            await hub.handle(HookEnvelope(v: 1, capturedAt: 1, event: [
                "hook_event_name": .string("PermissionRequest"), "session_id": .string("s1"), "cwd": .string("/p"),
                "tool_name": .string("Bash"), "tool_input": .object(["command": .string("ls")])]))
        }
        let link = PhoneLink(transport: phoneEnd, phoneKey: phoneKey, macKey: mac.publicKey, pairingSecret: nil)
        _ = try await link.open()
        var requestId: String?
        for _ in 0..<200 where requestId == nil {
            await link.send(.hello(deviceName: "iPhone"))
            if case let .snapshot(_, pending, _) = try await link.next() { requestId = pending.first?.id }
            if requestId == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        await link.send(.decide(requestId: try #require(requestId), allow: true, message: nil))
        #expect(String(decoding: await hook.value, as: UTF8.self).contains(#""behavior":"allow""#))
    }
}
