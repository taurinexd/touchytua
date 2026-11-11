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
    var macStatic = Curve25519.KeyAgreement.PrivateKey()
    let hub = Hub()
    var pendingSecret: Data?
    var knownPhoneKey: Data?
    /// The connection dies before the Mac answers the hello.
    var dropsHandshake = false

    var publicKey: Data { macStatic.publicKey.rawRepresentation }

    /// Serves one connection until the transport closes.
    func serve(_ transport: MemoryTransport) {
        let router = PhoneRouter(hub: hub) { _, _ in }
        let mac = self
        Task {
            guard let hello = try? await transport.receive(), !mac.dropsHandshake else {
                transport.close()
                return
            }
            var channel: SecureChannel
            do {
                let accepted = try Handshake.macAccept(
                    hello: hello, macStatic: mac.macStatic, ephemeral: Curve25519.KeyAgreement.PrivateKey(),
                    expectedSecret: mac.pendingSecret, knownPhoneKey: mac.knownPhoneKey)
                channel = SecureChannel(keys: accepted.keys)
                transport.send(accepted.reply)
            } catch {
                if let reason = error as? HandshakeError,
                   let no = Handshake.macReject(hello: hello, macStatic: mac.macStatic, reason: reason) {
                    transport.send(no)
                }
                transport.close()
                return
            }
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

/// Addresses the phone can dial, each answered by a fake Mac, by nobody, or
/// by a host that accepts the connection and then says nothing.
final class FakeNetwork: @unchecked Sendable {
    enum Host { case mac(FakeMac), down, silent }

    private let lock = NSLock()
    private var hosts: [String: Host] = [:]
    private var dialedEndpoints: [String] = []
    private var open: [MemoryTransport] = []

    var dialed: [String] { lock.withLock { dialedEndpoints } }

    func set(_ endpoint: String, _ host: Host) {
        lock.withLock { hosts[endpoint] = host }
    }

    func dial(_ endpoint: String) async throws -> any FrameTransport {
        let host = lock.withLock {
            dialedEndpoints.append(endpoint)
            return hosts[endpoint] ?? .down
        }
        if case .down = host { throw LinkError.closed }
        let (phoneEnd, macEnd) = MemoryTransport.pair()
        lock.withLock { open += [phoneEnd, macEnd] }
        if case let .mac(mac) = host { mac.serve(macEnd) }
        return phoneEnd
    }

    /// Cuts every open connection, as losing the network does.
    func dropAll() {
        let all = lock.withLock {
            defer { open = [] }
            return open
        }
        all.forEach { $0.close() }
    }
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    let key = Curve25519.KeyAgreement.PrivateKey()
    private let lock = NSLock()
    private var records: [PairingRecord] = []

    func phoneKey() throws -> Curve25519.KeyAgreement.PrivateKey { key }
    func pairings() -> [PairingRecord] { lock.withLock { records } }

    func save(_ record: PairingRecord) {
        lock.withLock {
            records.removeAll { $0.macKey == record.macKey }
            records.insert(record, at: 0)
        }
    }

    func remove(macKey: Data) {
        lock.withLock { records.removeAll { $0.macKey == macKey } }
    }
}
