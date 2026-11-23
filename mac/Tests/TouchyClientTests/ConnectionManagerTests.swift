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

/// Holds callers until it is opened.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
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
    private func pairedMac(_ name: String = "Studio", endpoints: [String]) -> FakeMac {
        var mac = FakeMac()
        mac.knownPhoneKey = store.key.publicKey.rawRepresentation
        store.save(PairingRecord(macName: name, macKey: mac.publicKey, endpoints: endpoints))
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

    // MARK: addresses

    @Test func theMacsCurrentAddressesReplaceTheOnesFromTheQR() async {
        var mac = pairedMac(endpoints: [lan])
        mac.addresses = ["lan:192.168.1.77:47311", ts]
        network.set(lan, .mac(mac))
        let manager = manager()
        defer { manager.stop() }

        manager.start()

        #expect(await eventually { store.pairings().first?.endpoints == ["lan:192.168.1.77:47311", ts] })
        #expect(store.pairings().first?.macName == "Studio")
    }

    @Test func aMacFoundAwayFromHomeThroughAnAddressItSentLater() async {
        var mac = pairedMac(endpoints: [lan])
        mac.addresses = [lan, ts]
        network.set(lan, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { store.pairings().first?.endpoints == [lan, ts] })

        // Away from home: the Wi-Fi address leads nowhere, Tailscale answers.
        network.set(lan, .down)
        network.set(ts, .mac(mac))
        network.dropAll()

        #expect(await eventually { manager.status == .connected(via: "Tailscale") })
    }

    @Test func addressesThatAreNotAddressesAreIgnored() {
        let record = PairingRecord(macName: "Studio", macKey: Data([1]), endpoints: [lan])
        #expect(record.refreshed(with: ["bonjour:abc", "http://x", "", "ts:"]) == record)
        #expect(record.refreshed(with: []) == record)
        #expect(record.refreshed(with: [ts, ts, "nonsense"]).endpoints == [ts, lan])
        #expect(record.refreshed(with: (1...20).map { "lan:10.0.0.\($0):47311" }).endpoints.count == 6)
    }

    @Test func aKindOfAddressTheMacLeavesOutIsKept() {
        // Tailscale switched off for a moment at home must not lose the way in from outside.
        let record = PairingRecord(macName: "Studio", macKey: Data([1]), endpoints: [lan, ts])
        #expect(record.refreshed(with: ["lan:192.168.1.77:47311"]).endpoints == ["lan:192.168.1.77:47311", ts])
        #expect(record.refreshed(with: ["ts:other.ts.net:47311"]).endpoints == ["ts:other.ts.net:47311", lan])
        #expect(record.refreshed(with: [lan, ts]).endpoints == [lan, ts])
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

    /// The first connection makes iOS ask for Local Network access; until the
    /// person answers, nothing reaches the Mac.
    @Test func pairingKeepsTryingUntilTheNetworkLetsItThrough() async {
        var mac = FakeMac()
        mac.pendingSecret = secret
        let payload = PairingPayload(v: 1, macKey: mac.publicKey, secret: secret, endpoints: [lan], macName: "Studio")
        var timing = ConnectionManager.Timing.fast
        timing.pairingPatience = .seconds(5)
        timing.pause = { [network, lan, mac] _ in network.set(lan, .mac(mac)) }
        let manager = manager(timing)
        defer { manager.stop() }

        await manager.pair(url: payload.url())

        #expect(manager.status == .connected(via: "Wi-Fi"))
        #expect(network.dialed == [lan, lan])
    }

    /// Answering a system alert makes the app active again, which calls `start`.
    @Test func comingBackToTheAppDoesNotInterruptPairing() async {
        var mac = FakeMac()
        mac.pendingSecret = secret
        let payload = PairingPayload(v: 1, macKey: mac.publicKey, secret: secret, endpoints: [lan], macName: "Studio")
        let gate = Gate()
        var timing = ConnectionManager.Timing.fast
        timing.pairingPatience = .seconds(5)
        timing.pause = { [network, lan, mac] _ in
            await gate.wait()
            network.set(lan, .mac(mac))
        }
        let manager = manager(timing)
        defer { manager.stop() }
        let pairing = Task { await manager.pair(url: payload.url()) }
        #expect(await eventually { network.dialed.count == 1 })

        manager.start()
        #expect(manager.status == .connecting)

        await gate.open()
        await pairing.value
        #expect(manager.status == .connected(via: "Wi-Fi"))
    }

    @Test func comingBackToTheAppKeepsThePairingErrorOnScreen() async {
        let payload = PairingPayload(v: 1, macKey: FakeMac().publicKey, secret: secret, endpoints: [lan], macName: "Studio")
        let manager = manager()
        await manager.pair(url: payload.url())

        manager.start()

        #expect(manager.status == .failed(ConnectionManager.unreachableMessage("Studio")))
    }

    @Test func leavingTheAppStopsPairing() async {
        let payload = PairingPayload(v: 1, macKey: FakeMac().publicKey, secret: secret, endpoints: [lan], macName: "Studio")
        let gate = Gate()
        var timing = ConnectionManager.Timing.fast
        timing.pairingPatience = .seconds(5)
        timing.pause = { _ in await gate.wait() }
        let manager = manager(timing)
        let pairing = Task { await manager.pair(url: payload.url()) }
        #expect(await eventually { network.dialed.count == 1 })

        manager.stop()
        await gate.open()
        await pairing.value

        #expect(network.dialed == [lan])
        #expect(manager.status == .unpaired)
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

    /// Away from home the Wi-Fi address goes nowhere: Tailscale must not wait for it.
    @Test func aSilentAddressDoesNotHoldUpTheOthers() async {
        let mac = pairedMac(endpoints: [lan, ts])
        network.set(lan, .silent)
        network.set(ts, .mac(mac))
        var timing = ConnectionManager.Timing.fast
        timing.connectTimeout = .seconds(5)
        let manager = manager(timing)
        defer { manager.stop() }
        manager.start()
        #expect(await eventually(within: .seconds(1)) { manager.status == .connected(via: "Tailscale") })
        #expect(Set(network.dialed) == [Endpoint.bonjour(forMacKey: mac.publicKey).text, lan, ts])
    }

    /// The router gave the Mac a new address since the QR was scanned.
    @Test func theMacIsFoundOnTheLocalNetworkAfterItsAddressChanged() async {
        let mac = pairedMac(endpoints: [lan])
        network.set(Endpoint.bonjour(forMacKey: mac.publicKey).text, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.status == .connected(via: "Wi-Fi") })
    }

    /// The QR secret works once: two hellos at the same time would make the
    /// Mac refuse the second, so pairing goes one address at a time.
    @Test func pairingGivesUpOnASilentAddressAndTriesTheNext() async {
        var mac = FakeMac()
        mac.pendingSecret = secret
        network.set(lan, .silent)
        network.set(ts, .mac(mac))
        let payload = PairingPayload(v: 1, macKey: mac.publicKey, secret: secret, endpoints: [lan, ts], macName: "Studio")
        let manager = manager()
        defer { manager.stop() }
        await manager.pair(url: payload.url())
        #expect(manager.status == .connected(via: "Tailscale"))
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
        #expect(manager.outbox.waiting(in: "s1").isEmpty)
    }

    @Test func aSentPromptStaysOnScreenUntilClaudeTakesIt() async {
        let mac = pairedMac(endpoints: [lan])
        await openSession("s1", on: mac)
        network.set(lan, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.sessions.count == 1 })

        await manager.prompt(sessionId: "s1", text: "run the tests")
        #expect(manager.outbox.waiting(in: "s1").map(\.text) == ["run the tests"])

        _ = await mac.hub.handle(HookEnvelope(v: 1, capturedAt: 5, event: [
            "hook_event_name": .string("UserPromptSubmit"), "session_id": .string("s1"), "cwd": .string("/p"),
            "prompt": .string("run the tests")]))
        #expect(await eventually { manager.outbox.waiting(in: "s1").isEmpty })
    }

    @Test func earlierMessagesAreLoadedWhenAskedFor() async throws {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-11-12T10:00:01.000Z","message":{"role":"user","content":"Fix the cart"}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-11-12T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Fixed."}]}}"#,
        ]
        let path = NSTemporaryDirectory() + "tt-earlier-" + UUID().uuidString + ".jsonl"
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
        let mac = pairedMac(endpoints: [lan])
        _ = await mac.hub.handle(HookEnvelope(
            v: 1, capturedAt: ISO8601DateFormatter().date(from: "2026-11-12T10:00:10Z")!.timeIntervalSince1970,
            event: ["hook_event_name": .string("UserPromptSubmit"), "session_id": .string("s1"), "cwd": .string("/p"),
                    "prompt": .string("Now the tests"), "transcript_path": .string(path)]))
        network.set(lan, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.sessions.count == 1 })
        #expect(manager.earlier.page(of: "s1").items.isEmpty)

        await manager.loadEarlier(sessionId: "s1")

        #expect(await eventually { manager.earlier.page(of: "s1").items.map(\.text) == ["Fix the cart", "Fixed."] })
        #expect(!manager.earlier.page(of: "s1").canLoadMore)
    }

    @Test func aSessionWithoutATranscriptSaysItsHistoryIsUnavailable() async {
        let mac = pairedMac(endpoints: [lan])
        await openSession("s1", on: mac)
        network.set(lan, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.sessions.count == 1 })

        await manager.loadEarlier(sessionId: "s1")

        #expect(await eventually { manager.earlier.page(of: "s1").isUnavailable })
    }

    private final class Spawned: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [SessionLaunch.Request] = []
        var requests: [SessionLaunch.Request] { lock.withLock { all } }
        func add(_ request: SessionLaunch.Request) { lock.withLock { all.append(request) } }
    }

    private func desk(_ spawned: Spawned) -> LaunchDesk {
        let desk = LaunchDesk(path: NSTemporaryDirectory() + "tt-desk-" + UUID().uuidString + ".json",
                              exists: { _ in true }) { spawned.add($0) }
        desk.note(cwd: "/p/shop")
        return desk
    }

    @Test func aSessionIsStartedOnTheMacFromThePhone() async {
        let spawned = Spawned()
        var mac = pairedMac(endpoints: [lan])
        mac.desk = desk(spawned)
        network.set(lan, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { if case .connected = manager.status { true } else { false } })

        await manager.loadFolders()
        #expect(await eventually { manager.launcher.folders.map(\.path) == ["/p/shop"] })

        await manager.startSession(folder: "/p/shop", prompt: "Fix the cart", name: "cart")
        #expect(await eventually { spawned.requests == [.init(folder: "/p/shop", prompt: "Fix the cart", name: "cart")] })
        #expect(manager.launcher.problem == nil)
    }

    @Test func aStartTheMacRefusesIsExplained() async {
        let spawned = Spawned()
        var mac = pairedMac(endpoints: [lan])
        mac.desk = desk(spawned)
        network.set(lan, .mac(mac))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { if case .connected = manager.status { true } else { false } })

        await manager.startSession(folder: "/somewhere/else", prompt: "Fix the cart", name: nil)

        #expect(await eventually { manager.launcher.problem == "That folder isn't available any more." })
        #expect(spawned.requests.isEmpty)
    }

    // MARK: more than one Mac

    /// Two paired Macs, each with one session: the laptop paired first, so
    /// the studio is the one in use.
    private func twoMacs() async -> (studio: FakeMac, laptop: FakeMac) {
        let laptop = pairedMac("Laptop", endpoints: [ts])
        let studio = pairedMac("Studio", endpoints: [lan])
        await openSession("on-laptop", on: laptop)
        await openSession("on-studio", on: studio)
        network.set(ts, .mac(laptop))
        network.set(lan, .mac(studio))
        return (studio, laptop)
    }

    @Test func pairingASecondMacKeepsTheFirst() async {
        let studio = pairedMac(endpoints: [lan])
        network.set(lan, .mac(studio))
        var laptop = FakeMac()
        laptop.pendingSecret = secret
        await openSession("on-laptop", on: laptop)
        network.set(ts, .mac(laptop))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.status == .connected(via: "Wi-Fi") })

        await manager.pair(url: PairingPayload(
            v: 1, macKey: laptop.publicKey, secret: secret, endpoints: [ts], macName: "Laptop").url())

        #expect(store.pairings().map(\.macName) == ["Laptop", "Studio"])
        #expect(manager.macs.map(\.name) == ["Laptop", "Studio"])
        #expect(manager.macInUse == laptop.publicKey)
        #expect(manager.macName == "Laptop")
        #expect(await eventually { manager.state.sessions.map(\.id) == ["on-laptop"] })
    }

    @Test func movingToAnotherMacShowsItsSessions() async {
        let (studio, laptop) = await twoMacs()
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.sessions.map(\.id) == ["on-studio"] })
        #expect(manager.macInUse == studio.publicKey)

        manager.use(laptop.publicKey)

        // Nothing of the Mac just left stays on screen while the other answers.
        #expect(manager.state == ClientState())
        #expect(manager.macName == "Laptop")
        #expect(await eventually { manager.state.sessions.map(\.id) == ["on-laptop"] })
        #expect(manager.status == .connected(via: "Tailscale"))
        #expect(manager.macs.map(\.name) == ["Laptop", "Studio"])
    }

    @Test func theMacInUseIsStillTheOneAfterARelaunch() async {
        let (_, laptop) = await twoMacs()
        let first = manager()
        first.use(laptop.publicKey)
        first.stop()

        let relaunched = manager()
        defer { relaunched.stop() }
        #expect(relaunched.macName == "Laptop")
        relaunched.start()
        #expect(await eventually { relaunched.state.sessions.map(\.id) == ["on-laptop"] })
    }

    @Test func movingToAMacThatIsNotPairedDoesNothing() async {
        let (studio, _) = await twoMacs()
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.sessions.map(\.id) == ["on-studio"] })

        manager.use(FakeMac().publicKey)
        manager.use(studio.publicKey)

        #expect(manager.state.sessions.map(\.id) == ["on-studio"])
        #expect(manager.status == .connected(via: "Wi-Fi"))
    }

    @Test func unpairingTheMacInUseMovesToTheOther() async {
        let (_, laptop) = await twoMacs()
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.sessions.map(\.id) == ["on-studio"] })

        manager.unpair()

        #expect(store.pairings().map(\.macName) == ["Laptop"])
        #expect(manager.macs == [PairedMac(id: laptop.publicKey, name: "Laptop")])
        #expect(manager.macName == "Laptop")
        #expect(await eventually { manager.state.sessions.map(\.id) == ["on-laptop"] })
    }

    @Test func aSecondMacThatCannotBeReachedLeavesTheFirstInUse() async {
        let studio = pairedMac(endpoints: [lan])
        await openSession("on-studio", on: studio)
        network.set(lan, .mac(studio))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.state.sessions.map(\.id) == ["on-studio"] })

        await manager.pair(url: PairingPayload(
            v: 1, macKey: FakeMac().publicKey, secret: secret, endpoints: [ts], macName: "Laptop").url())

        #expect(manager.pairingProblem == ConnectionManager.unreachableMessage("Laptop"))
        #expect(store.pairings().map(\.macName) == ["Studio"])
        #expect(manager.macName == "Studio")
        #expect(await eventually { manager.status == .connected(via: "Wi-Fi") })
        #expect(manager.state.sessions.map(\.id) == ["on-studio"])

        manager.clearPairingProblem()
        #expect(manager.pairingProblem == nil)
    }

    @Test func whileAMacIsBeingAddedItsNameIsKnown() async {
        let studio = pairedMac(endpoints: [lan])
        network.set(lan, .mac(studio))
        network.set(ts, .silent)
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.status == .connected(via: "Wi-Fi") })

        let adding = Task { await manager.pair(url: PairingPayload(
            v: 1, macKey: FakeMac().publicKey, secret: secret, endpoints: [ts], macName: "Laptop").url()) }
        #expect(await eventually { manager.macBeingAdded == "Laptop" })
        #expect(manager.macName == "Studio")
        await adding.value

        #expect(manager.macBeingAdded == nil)
        #expect(await eventually { manager.status == .connected(via: "Wi-Fi") })
    }

    @Test func textThatIsNotAPairingCodeLeavesTheMacInUseConnected() async {
        let studio = pairedMac(endpoints: [lan])
        network.set(lan, .mac(studio))
        let manager = manager()
        defer { manager.stop() }
        manager.start()
        #expect(await eventually { manager.status == .connected(via: "Wi-Fi") })

        await manager.pair(url: "https://example.com")

        #expect(manager.pairingProblem == ConnectionManager.notAPairingCodeMessage)
        #expect(manager.status == .connected(via: "Wi-Fi"))
    }

    @Test func addressesFromTheMacInUseLeaveTheOtherMacAlone() async {
        var (studio, laptop) = await twoMacs()
        studio.addresses = ["lan:192.168.1.99:47311"]
        network.set(lan, .mac(studio))
        let manager = manager()
        defer { manager.stop() }
        manager.start()

        #expect(await eventually { store.pairings().first?.endpoints == ["lan:192.168.1.99:47311"] })
        #expect(store.pairings().map(\.macName) == ["Studio", "Laptop"])
        #expect(store.pairings().last == PairingRecord(macName: "Laptop", macKey: laptop.publicKey, endpoints: [ts]))
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
        timing.pairingPatience = .zero
        return timing
    }
}

@Suite struct EndpointTests {
    @Test func readsTheAddressesWrittenInTheQR() {
        #expect(Endpoint("lan:192.168.1.20:47311") == .lan(host: "192.168.1.20", port: 47311))
        #expect(Endpoint("ts:mac.tail1234.ts.net:47311") == .tailscale(host: "mac.tail1234.ts.net", port: 47311))
        #expect(Endpoint("lan:192.168.1.20:47311")?.label == "Wi-Fi")
        #expect(Endpoint("ts:mac.tail1234.ts.net:47311")?.label == "Tailscale")
    }

    @Test func keepsTheColonsOfAnIPv6Address() {
        #expect(Endpoint("lan:fe80::1:47311") == .lan(host: "fe80::1", port: 47311))
    }

    /// Not in the QR: the phone derives it from the Mac's key.
    @Test func bonjourNamesTheMacByItsKeyNotItsAddress() {
        let key = Data(repeating: 3, count: 32)
        let endpoint = Endpoint.bonjour(forMacKey: key)
        #expect(endpoint == .bonjour(id: Discovery.id(forMacKey: key)))
        #expect(Endpoint(endpoint.text) == endpoint)
        #expect(endpoint.label == "Wi-Fi")
    }

    @Test func writesBackWhatItRead() {
        for text in ["lan:192.168.1.20:47311", "ts:mac.tail1234.ts.net:47311", "lan:fe80::1:47311"] {
            #expect(Endpoint(text)?.text == text)
        }
    }

    @Test func refusesWhatItCannotRead() {
        #expect(Endpoint("lan:host") == nil)
        #expect(Endpoint("carrier-pigeon:host:1") == nil)
        #expect(Endpoint("lan:host:notaport") == nil)
        #expect(Endpoint("lan::47311") == nil)
        #expect(Endpoint("bonjour:") == nil)
    }
}
