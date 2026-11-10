import CryptoKit
import Foundation
@testable import TouchyClient
import TouchyKit
import TouchyProtocol

/// Two connected in-memory ends.
final class MemoryTransport: FrameTransport, @unchecked Sendable {
    private let incoming: AsyncStream<Data>
    private let feed: AsyncStream<Data>.Continuation
    private(set) weak var peer: MemoryTransport?
    /// Applied to every frame this end receives (to simulate tampering).
    var corrupt: (@Sendable (Data) -> Data)?

    private init() {
        (incoming, feed) = AsyncStream<Data>.makeStream()
    }

    static func pair() -> (MemoryTransport, MemoryTransport) {
        let a = MemoryTransport(), b = MemoryTransport()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func send(_ frame: Data) { peer?.feed.yield(frame) }

    func receive() async throws -> Data {
        for await frame in incoming { return corrupt?(frame) ?? frame }
        throw LinkError.closed
    }

    func close() {
        feed.finish()
        peer?.feed.finish()
    }
}

/// The Mac end of a connection, built from the real handshake, router and hub.
struct FakeMac {
    let macStatic = Curve25519.KeyAgreement.PrivateKey()
    let hub = Hub()
    var pendingSecret: Data?
    var knownPhoneKey: Data?

    var publicKey: Data { macStatic.publicKey.rawRepresentation }

    /// Serves one connection until the transport closes.
    func serve(_ transport: MemoryTransport) {
        let router = PhoneRouter(hub: hub) { _, _ in }
        let (macStatic, secret, known) = (macStatic, pendingSecret, knownPhoneKey)
        Task {
            guard let hello = try? await transport.receive(),
                  let accepted = try? Handshake.macAccept(
                      hello: hello, macStatic: macStatic, ephemeral: Curve25519.KeyAgreement.PrivateKey(),
                      expectedSecret: secret, knownPhoneKey: known) else {
                transport.close()
                return
            }
            var channel = SecureChannel(keys: accepted.keys)
            transport.send(accepted.reply)
            while let frame = try? await transport.receive() {
                guard let plain = try? channel.open(frame),
                      let message = try? JSONDecoder().decode(PhoneToMac.self, from: plain) else {
                    transport.close()
                    return
                }
                for reply in await router.handle(message) {
                    guard let sealed = try? channel.seal(JSONEncoder().encode(reply)) else { continue }
                    transport.send(sealed)
                }
            }
        }
    }
}
