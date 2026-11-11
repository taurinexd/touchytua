import CryptoKit
import Foundation
import Testing
@testable import TouchyClient
import TouchyKit
import TouchyProtocol

/// Waits for something that happens on another task.
@MainActor func eventually(within timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

/// Collects the pauses the manager asks for between attempts.
final class Pauses: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [Duration] = []
    var all: [Duration] { lock.withLock { asked } }
    func add(_ pause: Duration) { lock.withLock { asked.append(pause) } }
}

@MainActor @Suite struct ConnectionManagerTests {
    let lan = "lan:192.168.1.20:47311"
    let ts = "ts:mac.tail1234.ts.net:47311"
    let network = FakeNetwork()
    let store = MemorySecretStore()
    let secret = Data(repeating: 9, count: 32)

    private func manager(_ timing: ConnectionManager.Timing = .fast) -> ConnectionManager {
        ConnectionManager(store: store, deviceName: "iPhone", timing: timing) { [network] in try await network.dial($0) }
    }

    /// A Mac this phone is already paired with.
    private func pairedMac(endpoints: [String]) -> FakeMac {
        var mac = FakeMac()
        mac.knownPhoneKey = store.key.publicKey.rawRepresentation
        store.save(PairingRecord(macName: "Studio", macKey: mac.publicKey, endpoints: endpoints))
        return mac
    }

    private func openSession(_ id: String, on mac: FakeMac) async {
        _ = await mac.hub.handle(HookEnvelope(v: 1, capturedAt: 1, event: [
            "hook_event_name": .string("SessionStart"), "session_id": .string(id), "cwd": .string("/p")]))
    }

    /// Starts a hook that waits for a decision; returns its eventual reply.
    private func askPermission(session: String, on mac: FakeMac) -> Task<Data, Never> {
        let hub = mac.hub
        return Task {
            await hub.handle(HookEnvelope(v: 1, capturedAt: 2, event: [
                "hook_event_name": .string("PermissionRequest"), "session_id": .string(session), "cwd": .string("/p"),
                "tool_name": .string("Bash"), "tool_input": .object(["command": .string("ls")])]))
        }
    }

    // MARK: pairing

    @Test func pairingSavesTheMacAndConnects() async {
        var mac = FakeMac()
        mac.pendingSecret = secret
        await openSession("s1", on: mac)
        network.set(lan, .mac(mac))
        let payload = PairingPayload(v: 1, macKey: mac.publicKey, secret: secret, endpoints: [lan], macName: "Studio")
        let manager = manager()
        defer { manager.stop() }
        #expect(manager.status == .unpaired)

        await manager.pair(url: payload.url())

        #expect(store.pairings() == [PairingRecord(macName: "Studio", macKey: mac.publicKey, endpoints: [lan])])
        #expect(manager.macName == "Studio")
        #expect(await eventually { manager.state.sessions.map(\.id) == ["s1"] })
        #expect(manager.status == .connected(via: "Wi-Fi"))
    }

    @Test func expiredQRIsExplained() async {
        let mac = FakeMac()  // no pending secret: the QR is no longer valid
        network.set(lan, .mac(mac))
        let payload = PairingPayload(v: 1, macKey: mac.publicKey, secret: secret, endpoints: [lan], macName: "Studio")
        let manager = manager()
        await manager.pair(url: payload.url())
        #expect(manager.status == .failed(ConnectionManager.qrExpiredMessage))
        #expect(store.pairings().isEmpty)
    }

    @Test func unreachableMacWhilePairingIsExplained() async {
        let payload = PairingPayload(v: 1, macKey: FakeMac().publicKey, secret: secret, endpoints: [lan, ts], macName: "Studio")
        let manager = manager()
        await manager.pair(url: payload.url())
        #expect(manager.status == .failed(ConnectionManager.unreachableMessage("Studio")))
        #expect(network.dialed == [lan, ts])
        #expect(store.pairings().isEmpty)
    }

    @Test func textThatIsNotAPairingCodeIsExplained() async {
        let manager = manager()
        await manager.pair(url: "https://example.com")
        #expect(manager.status == .failed(ConnectionManager.notAPairingCodeMessage))
        #expect(network.dialed.isEmpty)
    }

    // MARK: reaching the Mac

    @Test func waitsThreeSecondsPerAddressByDefault() {
        #expect(ConnectionManager.Timing().connectTimeout == .seconds(3))
        #expect(ConnectionManager.Timing().backoff == [1, 2, 4, 8, 15].map(Duration.seconds))
    }

    @Test func addressesAreTriedInOrderAndASilentOneIsGivenUp() async {
        let mac = pairedMac(endpoints: [lan, ts])
        network.set(lan, .silent)
        network.set(ts, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.status == .connected(via: "Tailscale") })
        #expect(network.dialed == [lan, ts])
    }

    @Test func retriesWaitLongerEachTimeUpToFifteenSeconds() async {
        _ = pairedMac(endpoints: [lan])  // and nothing answers there
        let pauses = Pauses()
        var timing = ConnectionManager.Timing.fast
        timing.backoff = ConnectionManager.Timing().backoff
        timing.pause = { pause in
            pauses.add(pause)
            if pauses.all.count == 7 { throw CancellationError() }
        }
        let manager = manager(timing)
        manager.start()
        #expect(await eventually { pauses.all.count == 7 })
        #expect(pauses.all == [1, 2, 4, 8, 15, 15, 15].map(Duration.seconds))
        #expect(manager.status == .reconnecting(attempt: 7))
    }

    /// Another Mac running touchytua at the old address must not end the pairing.
    @Test func aStrangerAtTheAddressIsSkipped() async {
        let mac = pairedMac(endpoints: [lan, ts])
        network.set(lan, .mac(FakeMac()))
        network.set(ts, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.status == .connected(via: "Tailscale") })
    }

    @Test func aMacThatForgotThisPhoneAsksToPairAgain() async {
        var mac = pairedMac(endpoints: [lan])
        mac.knownPhoneKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        network.set(lan, .mac(mac))
        let manager = manager()
        manager.start()
        #expect(await eventually { manager.status == .failed(ConnectionManager.forgottenMessage) })
    }

    // MARK: staying in sync

    @Test func afterADropEverythingComesFromTheNewSnapshot() async {
        let mac = pairedMac(endpoints: [lan])
        await openSession("s1", on: mac)
        await openSession("s2", on: mac)
        network.set(lan, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.sessions.count == 2 })

        network.set(lan, .down)
        network.dropAll()
        #expect(await eventually { if case .reconnecting = manager.status { true } else { false } })
        #expect(manager.state.sessions.count == 2)  // the last known picture stays on screen

        // s1 ends while the phone is away: no message tells it so.
        _ = await mac.hub.handle(HookEnvelope(v: 1, capturedAt: 3, event: [
            "hook_event_name": .string("SessionEnd"), "session_id": .string("s1"), "cwd": .string("/p")]))
        network.set(lan, .mac(mac))
        #expect(await eventually { manager.state.sessions.map(\.id) == ["s2"] })
        #expect(manager.status == .connected(via: "Wi-Fi"))
    }

    @Test func approvingAnswersTheHookAndClearsTheCardAtOnce() async throws {
        let mac = pairedMac(endpoints: [lan])
        network.set(lan, .mac(mac))
        let hook = askPermission(session: "s1", on: mac)
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.pending.count == 1 })
        let id = try #require(manager.state.pending.first?.id)

        await manager.decide(id, allow: true)

        #expect(manager.state.pending.isEmpty)
        #expect(String(decoding: await hook.value, as: UTF8.self).contains(#""behavior":"allow""#))
    }

    /// The request was settled in the terminal a moment before the tap.
    @Test func tappingARequestAlreadySettledIsHarmless() async throws {
        let mac = pairedMac(endpoints: [lan])
        network.set(lan, .mac(mac))
        let hook = askPermission(session: "s1", on: mac)
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.pending.count == 1 })
        let id = try #require(manager.state.pending.first?.id)
        #expect(await mac.hub.decide(requestId: id, allow: false, message: nil))
        _ = await hook.value

        await manager.decide(id, allow: true)
        await openSession("s9", on: mac)  // something later on the same link

        #expect(manager.state.pending.isEmpty)
        #expect(manager.notice == nil)
        #expect(manager.status == .connected(via: "Wi-Fi"))
    }

    @Test func decidingWhileOfflineKeepsTheCard() async throws {
        let mac = pairedMac(endpoints: [lan])
        network.set(lan, .mac(mac))
        let hook = askPermission(session: "s1", on: mac)
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.pending.count == 1 })
        let id = try #require(manager.state.pending.first?.id)
        network.set(lan, .down)
        network.dropAll()
        #expect(await eventually { if case .reconnecting = manager.status { true } else { false } })

        await manager.decide(id, allow: true)

        #expect(manager.state.pending.map(\.id) == [id])
        #expect(await mac.hub.decide(requestId: id, allow: false, message: nil))
        _ = await hook.value
    }

    @Test func aPromptThatCannotBeDeliveredIsReported() async {
        let mac = pairedMac(endpoints: [lan])
        await openSession("s1", on: mac)  // a session without an inbox
        network.set(lan, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.sessions.count == 1 })

        await manager.prompt(sessionId: "s1", text: "run the tests")

        #expect(await eventually { manager.notice == ConnectionManager.promptNotDeliveredMessage })
    }

    // MARK: lifecycle

    @Test func stopHangsUpAndStartComesBack() async {
        let mac = pairedMac(endpoints: [lan])
        network.set(lan, .mac(mac))
        let manager = manager()
        manager.start()
        #expect(await eventually { manager.status == .connected(via: "Wi-Fi") })

        manager.stop()
        let dials = network.dialed.count
        try? await Task.sleep(for: .milliseconds(50))
        #expect(network.dialed.count == dials)
        #expect(manager.status != .connected(via: "Wi-Fi"))

        manager.start()
        #expect(await eventually { manager.status == .connected(via: "Wi-Fi") })
        manager.stop()
    }

    @Test func unpairForgetsTheMac() async {
        let mac = pairedMac(endpoints: [lan])
        await openSession("s1", on: mac)
        network.set(lan, .mac(mac))
        let manager = manager()
        manager.start()
        #expect(await eventually { manager.state.sessions.count == 1 })

        manager.unpair()

        #expect(manager.status == .unpaired)
        #expect(manager.state == ClientState())
        #expect(store.pairings().isEmpty)
    }
}

extension ConnectionManager.Timing {
    /// Real pauses, but short enough for tests.
    static var fast: ConnectionManager.Timing {
        var timing = ConnectionManager.Timing()
        timing.connectTimeout = .milliseconds(100)
        timing.backoff = [.milliseconds(5)]
        return timing
    }
}

@Suite struct EndpointTests {
    @Test func readsTheAddressesWrittenInTheQR() throws {
        let lan = try #require(Endpoint("lan:192.168.1.20:47311"))
        #expect(lan.route == .lan)
        #expect(lan.host == "192.168.1.20")
        #expect(lan.port == 47311)
        #expect(lan.label == "Wi-Fi")
        let ts = try #require(Endpoint("ts:mac.tail1234.ts.net:47311"))
        #expect(ts.route == .tailscale)
        #expect(ts.host == "mac.tail1234.ts.net")
        #expect(ts.label == "Tailscale")
    }

    @Test func keepsTheColonsOfAnIPv6Address() throws {
        let v6 = try #require(Endpoint("lan:fe80::1:47311"))
        #expect(v6.host == "fe80::1")
        #expect(v6.port == 47311)
    }

    @Test func refusesWhatItCannotRead() {
        #expect(Endpoint("lan:host") == nil)
        #expect(Endpoint("carrier-pigeon:host:1") == nil)
        #expect(Endpoint("lan:host:notaport") == nil)
        #expect(Endpoint("lan::47311") == nil)
    }
}
