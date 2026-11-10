import CryptoKit
import Foundation
import TouchyProtocol

/// The phone's end of one connection: handshake, then encrypted messages.
public actor PhoneLink {
    private let transport: FrameTransport
    private let phoneKey: Curve25519.KeyAgreement.PrivateKey  // gitleaks:allow (a type name, not a key)
    private let macKey: Data
    private let pairingSecret: Data?
    private var channel: SecureChannel?

    /// `pairingSecret` is the QR secret on the first connection, nil afterwards.
    public init(
        transport: FrameTransport, phoneKey: Curve25519.KeyAgreement.PrivateKey,
        macKey: Data, pairingSecret: Data?
    ) {
        self.transport = transport
        self.phoneKey = phoneKey
        self.macKey = macKey
        self.pairingSecret = pairingSecret
    }

    /// Runs the handshake. Returns the protocol version the Mac speaks.
    public func open() async throws -> Int {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        transport.send(Handshake.phoneHello(phoneStatic: phoneKey, ephemeral: ephemeral, pairingSecret: pairingSecret))
        let reply: Data
        do {
            reply = try await transport.receive()
        } catch {
            // The Mac answers a hello it does not accept by closing.
            throw LinkError.rejected
        }
        let keys = try Handshake.phoneFinish(
            reply: reply, phoneStatic: phoneKey, ephemeral: ephemeral, macKey: macKey, pairingSecret: pairingSecret)
        channel = SecureChannel(keys: keys)
        return Handshake.peerVersion(in: reply)
    }

    public func send(_ message: PhoneToMac) {
        guard var channel, let json = try? JSONEncoder().encode(message),
              let frame = try? channel.seal(json) else { return }
        self.channel = channel
        transport.send(frame)
    }

    /// The next message from the Mac. A type this build does not know comes
    /// back as `.unknown`; a frame that fails authentication throws.
    public func next() async throws -> MacToPhone {
        let frame = try await transport.receive()
        guard var channel else { throw LinkError.closed }
        let plain = try channel.open(frame)
        self.channel = channel
        return (try? JSONDecoder().decode(MacToPhone.self, from: plain)) ?? .unknown("undecodable")
    }

    public func close() {
        transport.close()
    }
}
