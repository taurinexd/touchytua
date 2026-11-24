import CryptoKit
import Foundation
import Observation
import TouchyProtocol

public enum ConnectionStatus: Equatable, Sendable {
    case unpaired
    case connecting
    /// `via` is how the Mac was reached: "Wi-Fi" or "Tailscale".
    case connected(via: String)
    /// The link is down and the `attempt`-th round of retries is next.
    case reconnecting(attempt: Int)
    /// Retrying will not help; the text says what the user has to do.
    case failed(String)
}

/// Keeps one encrypted link to the paired Mac alive and folds what arrives
/// into `state`. The app's views observe this object and nothing else.
@Observable @MainActor
public final class ConnectionManager {
    public struct Timing: Sendable {
        /// How long one address gets to connect and finish the handshake.
        public var connectTimeout: Duration = .seconds(3)
        /// Pause after each failed round; the last value repeats.
        public var backoff: [Duration] = [1, 2, 4, 8, 15].map(Duration.seconds)
        /// How long pairing keeps trying before it reports the Mac unreachable.
        /// The first connection makes iOS ask for Local Network access, and
        /// nothing gets through until the person has answered.
        public var pairingPatience: Duration = .seconds(30)
        /// Pause between two pairing rounds.
        public var pairingRetry: Duration = .seconds(1)
        /// How long a notice stays on screen before it goes away by itself.
        public var noticeLifetime: Duration = .seconds(6)
        public var pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        public init() {}
    }

    /// Opens a connection to an address from the QR. Must give up when its
    /// task is cancelled: that is how the per-address timeout is enforced.
    public typealias Dial = @Sendable (String) async throws -> any FrameTransport

    public static let notAPairingCodeMessage = "That is not a touchytua pairing code."
    public static let qrExpiredMessage = "That QR code has expired or was already used. Run /pair again."
    public static let forgottenMessage = "Your Mac no longer recognizes this phone. Run /pair again."
    public static let promptNotDeliveredMessage = "That session can't receive prompts right now."

    public static func unreachableMessage(_ macName: String) -> String {
        "Can't reach \(macName). Join the same Wi-Fi, or turn on Tailscale on both. "
            + "In Settings, check that touchytua is allowed to use the Local Network."
    }

    public private(set) var status: ConnectionStatus
    /// The last picture received from the Mac. Kept while reconnecting.
    public private(set) var state = ClientState()
    /// The name of the Mac in use.
    public private(set) var macName: String?
    /// Every paired Mac, by name.
    public private(set) var macs: [PairedMac] = []
    /// Which of `macs` the app talks to.
    public private(set) var macInUse: PairedMac.ID?
    /// Set when the Mac in use runs an older plugin than this app knows:
    /// some of what the app shows will be missing until it is updated.
    public private(set) var macUpdate: MacUpdate?
    /// The name of the Mac being paired, while `pair` is trying to reach it.
    public private(set) var macBeingAdded: String?
    /// Why the code just scanned added no Mac, while another stays in use.
    public private(set) var pairingProblem: String?
    /// A problem worth a line on screen that is not a connection problem.
    public private(set) var notice: String?
    /// The prompts sent from here that Claude has not taken up yet.
    public private(set) var outbox = Outbox()
    /// The earlier conversation of the sessions, as far as it was asked for.
    public private(set) var earlier = Earlier()
    /// Starting a session on the Mac: where, and what went wrong.
    public private(set) var launcher = Launcher()

    @ObservationIgnored private let store: any SecretStore
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let dial: Dial
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var link: PhoneLink?
    /// Bumped by `stop`; work started before it must not touch the state.
    @ObservationIgnored private var epoch = 0
    /// True while `pair` is trying to reach the Mac.
    @ObservationIgnored private var pairing = false
    /// Counts the notices, so that the timer of an older one leaves a
    /// newer one alone.
    @ObservationIgnored private var noticesSaid = 0
    /// The release the Mac said on this link, before its snapshot.
    @ObservationIgnored private var heardRelease: String?

    public init(store: any SecretStore, deviceName: String, timing: Timing = Timing(), dial: @escaping Dial) {
        self.store = store
        self.deviceName = deviceName
        self.timing = timing
        self.dial = dial
        status = store.pairings().isEmpty ? .unpaired : .connecting
        readMacs()
    }

    /// The first saved pairing is the Mac in use.
    private func readMacs() {
        let records = store.pairings()
        macName = records.first?.macName
        macInUse = records.first?.macKey
        macs = records.map { PairedMac(id: $0.macKey, name: $0.macName) }.sorted {
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.id.lexicographicallyPrecedes($1.id)
            }
        }
    }

    /// Puts a notice on screen for a while: it says what just happened,
    /// and a moment later that is no longer news.
    private func say(_ text: String) {
        notice = text
        noticesSaid += 1
        let (mine, pause, lifetime) = (noticesSaid, timing.pause, timing.noticeLifetime)
        Task { [weak self] in
            try? await pause(lifetime)
            guard let self, self.noticesSaid == mine else { return }
            self.notice = nil
        }
    }

    /// Nothing of a Mac stays on screen once the app talks to another.
    private func forgetThePicture() {
        macUpdate = nil
        state = ClientState()
        notice = nil
        outbox = Outbox()
        earlier = Earlier()
        launcher = Launcher()
    }

    // MARK: lifecycle

    /// Connects to the paired Mac and keeps reconnecting until `stop`.
    public func start() {
        guard runner == nil, !pairing else { return }
        guard let record = store.pairings().first else {
            // A pairing error stays on screen until the next attempt.
            if case .failed = status { return }
            status = .unpaired
            return
        }
        macName = record.macName
        status = .connecting
        runner = Task { [weak self] in await self?.run(record, established: nil) }
    }

    /// Hangs up. `start` connects again.
    public func stop() {
        epoch += 1
        pairing = false
        macBeingAdded = nil
        runner?.cancel()
        runner = nil
        if let link {
            self.link = nil
            Task { await link.close() }
        }
        if case .failed = status { return }
        status = store.pairings().isEmpty ? .unpaired : .connecting
    }

    /// Pairs with the Mac whose QR says `url` and moves to it; the Macs
    /// already paired stay. Returns with the outcome known: `connected`, or
    /// what went wrong in `status` (no Mac to go back to) or in
    /// `pairingProblem` (back on the Mac in use).
    public func pair(url: String) async {
        pairingProblem = nil
        guard let payload = try? PairingPayload.parse(url: url) else {
            if macInUse == nil { status = .failed(Self.notAPairingCodeMessage) } else {
                pairingProblem = Self.notAPairingCodeMessage
            }
            return
        }
        stop()
        let mine = epoch
        status = .connecting
        pairing = true
        macBeingAdded = payload.macName
        defer {
            if mine == epoch {
                pairing = false
                macBeingAdded = nil
            }
        }
        let record = PairingRecord(macName: payload.macName, macKey: payload.macKey, endpoints: payload.endpoints)
        // An address that does not answer leaves the QR secret unused, so
        // trying again is safe.
        let deadline = ContinuousClock.now + timing.pairingPatience
        var outcome = await reach(record, secret: payload.secret)
        while case .unreachable = outcome, mine == epoch, ContinuousClock.now < deadline {
            try? await timing.pause(timing.pairingRetry)
            guard mine == epoch else { break }
            outcome = await reach(record, secret: payload.secret)
        }
        guard mine == epoch else {
            if case let .connected(link, _) = outcome { await link.close() }
            return
        }
        switch outcome {
        case let .connected(link, endpoint):
            store.save(record)
            readMacs()
            forgetThePicture()
            // Set here too, so that `pair` returns with its outcome known.
            status = .connected(via: Endpoint(endpoint)?.label ?? endpoint)
            runner = Task { [weak self] in await self?.run(record, established: (link, endpoint)) }
        case .rejected:
            couldNotPair(Self.qrExpiredMessage)
        case .unreachable:
            couldNotPair(Self.unreachableMessage(payload.macName))
        }
    }

    private func couldNotPair(_ problem: String) {
        guard macInUse != nil else {
            status = .failed(problem)
            return
        }
        pairingProblem = problem
        pairing = false
        macBeingAdded = nil
        start()
    }

    public func clearPairingProblem() {
        pairingProblem = nil
    }

    /// Moves to another paired Mac. It stays the one in use across launches.
    public func use(_ mac: PairedMac.ID) {
        guard mac != macInUse, let record = store.pairings().first(where: { $0.macKey == mac }) else { return }
        stop()
        store.save(record)
        move()
    }

    /// Forgets the Mac in use and moves to another paired one, if any.
    public func unpair() {
        stop()
        if let macInUse { store.remove(macKey: macInUse) }
        move()
    }

    /// Starts over with whichever Mac the store now has first.
    private func move() {
        readMacs()
        forgetThePicture()
        pairingProblem = nil
        status = macInUse == nil ? .unpaired : .connecting
        start()
    }

    // MARK: actions

    public func decide(_ requestId: String, allow: Bool, message: String? = nil) async {
        await act(on: requestId, .decide(requestId: requestId, allow: allow, message: message))
    }

    public func answer(_ requestId: String, answers: [String: String]) async {
        await act(on: requestId, .answer(requestId: requestId, answers: answers))
    }

    public func prompt(sessionId: String, text: String) async {
        guard let link, case .connected = status else { return }
        notice = nil
        outbox.sent(text, to: state.sessions.first { $0.id == sessionId })
        await link.send(.prompt(sessionId: sessionId, text: text))
    }

    /// Asks the Mac for the messages before the ones on screen.
    public func loadEarlier(sessionId: String) async {
        guard let link, case .connected = status,
              let session = state.sessions.first(where: { $0.id == sessionId }),
              let cursor = earlier.ask(session) else { return }
        await link.send(.history(sessionId: sessionId, before: cursor))
    }

    /// Puts a session in another permission mode. The Mac answers with
    /// the session, the mode marked as on its way.
    public func setMode(sessionId: String, mode: PermissionMode) async {
        guard let link, case .connected = status else { return }
        notice = nil
        // Known here already: say it without a round trip.
        if let session = state.sessions.first(where: { $0.id == sessionId }), let lock = session.modeLock,
           mode.wire != session.mode {
            say(lock)
            return
        }
        await link.send(.mode(sessionId: sessionId, mode: mode.wire))
    }

    /// Asks the Mac where a session can be started.
    public func loadFolders() async {
        guard let link, case .connected = status else { return }
        launcher.asked()
        await link.send(.folders)
    }

    /// Starts a session on the Mac. It shows up in the list by itself,
    /// once its first hook reaches the daemon.
    public func startSession(folder: String, prompt: String, name: String?) async {
        guard let link, case .connected = status else { return }
        launcher.starting()
        await link.send(.start(folder: folder, prompt: prompt, name: name))
    }

    /// Leaving a session lets go of its earlier conversation.
    public func forgetEarlier(sessionId: String) {
        earlier.forget(sessionId)
    }

    /// The card goes away at once: the Mac either settles the request or says
    /// it was settled already, and both mean there is nothing left to tap.
    /// If the message is lost with the link, the next snapshot brings it back.
    private func act(on requestId: String, _ message: PhoneToMac) async {
        guard let link, case .connected = status else { return }
        state.forget(requestId: requestId)
        await link.send(message)
    }

    // MARK: the link

    private enum Outcome: Sendable {
        case connected(PhoneLink, endpoint: String)
        /// The paired Mac itself said no.
        case rejected
        case unreachable
    }

    /// One attempt to reach the Mac.
    ///
    /// Pairing goes through the QR's addresses one at a time: the secret
    /// works once, so of two hellos sent together the Mac would refuse one.
    /// Reconnecting tries every address at once, plus the local network,
    /// and keeps the first that answers: an address that leads nowhere
    /// (the home Wi-Fi one, when away) then costs nothing.
    private func reach(_ record: PairingRecord, secret: Data?) async -> Outcome {
        guard let phoneKey = try? store.phoneKey() else { return .unreachable }
        let (dial, macKey, timeout) = (dial, record.macKey, timing.connectTimeout)
        guard secret == nil else {
            for endpoint in record.endpoints {
                if Task.isCancelled { break }
                let attempt = await Self.attempt(
                    endpoint, dial: dial, phoneKey: phoneKey, macKey: macKey, secret: secret, timeout: timeout)
                if case .unreachable = attempt { continue }
                return attempt
            }
            return .unreachable
        }
        let candidates = [Endpoint.bonjour(forMacKey: macKey).text] + record.endpoints
        return await withTaskGroup(of: Outcome.self) { group in
            for endpoint in candidates {
                group.addTask {
                    await Self.attempt(
                        endpoint, dial: dial, phoneKey: phoneKey, macKey: macKey, secret: nil, timeout: timeout)
                }
            }
            var outcome = Outcome.unreachable
            for await attempt in group {
                switch (attempt, outcome) {
                case (.connected, .unreachable), (.rejected, .unreachable):
                    outcome = attempt
                    group.cancelAll()
                case let (.connected(late, _), _):
                    await late.close()
                default:
                    break
                }
            }
            return outcome
        }
    }

    private nonisolated static func attempt(
        _ endpoint: String, dial: @escaping Dial, phoneKey: Curve25519.KeyAgreement.PrivateKey,
        macKey: Data, secret: Data?, timeout: Duration
    ) async -> Outcome {
        do {
            let link = try await open(
                endpoint, dial: dial, phoneKey: phoneKey, macKey: macKey, secret: secret, timeout: timeout)
            return .connected(link, endpoint: endpoint)
        } catch LinkError.rejected {
            return .rejected
        } catch {
            return .unreachable
        }
    }

    private struct TimedOut: Error {}

    /// Connects and completes the handshake, or throws within `timeout`.
    private nonisolated static func open(
        _ endpoint: String, dial: @escaping Dial, phoneKey: Curve25519.KeyAgreement.PrivateKey,
        macKey: Data, secret: Data?, timeout: Duration
    ) async throws -> PhoneLink {
        try await withThrowingTaskGroup(of: PhoneLink?.self) { group in
            group.addTask {
                let link = PhoneLink(
                    transport: try await dial(endpoint), phoneKey: phoneKey, macKey: macKey, pairingSecret: secret)
                do {
                    _ = try await link.open()
                    try Task.checkCancellation()
                    return link
                } catch {
                    await link.close()
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let link = first else { throw TimedOut() }
            return link
        }
    }

    private func run(_ record: PairingRecord, established: (PhoneLink, String)?) async {
        var established = established
        var failures = 0
        var record = record
        while !Task.isCancelled {
            if established == nil {
                // The Mac may have sent newer addresses while connected.
                if let saved = store.pairings().first(where: { $0.macKey == record.macKey }) { record = saved }
                switch await reach(record, secret: nil) {
                case let .connected(link, endpoint):
                    established = (link, endpoint)
                case .rejected:
                    if !Task.isCancelled { status = .failed(Self.forgottenMessage) }
                    return
                case .unreachable:
                    break
                }
            }
            if let (link, endpoint) = established {
                established = nil
                guard !Task.isCancelled else {
                    await link.close()
                    return
                }
                self.link = link
                status = .connected(via: Endpoint(endpoint)?.label ?? endpoint)
                heardRelease = nil
                await link.send(.hello(deviceName: deviceName))
                while let message = try? await link.next(), !Task.isCancelled {
                    // A link counts as good once the Mac has actually spoken.
                    failures = 0
                    receive(message)
                }
                await link.close()
                earlier.interrupted()
                launcher.interrupted()
                guard !Task.isCancelled else { return }
                self.link = nil
            }
            failures += 1
            status = .reconnecting(attempt: failures)
            do {
                let pauses = timing.backoff.isEmpty ? Timing().backoff : timing.backoff
                try await timing.pause(pauses[min(failures, pauses.count) - 1])
            } catch {
                return
            }
        }
    }

    private func receive(_ message: MacToPhone) {
        if case let .history(sessionId, items, next) = message {
            earlier.received(sessionId: sessionId, items: items, next: next)
            return
        }
        if case let .folders(items, enabled) = message {
            launcher.received(folders: items, enabled: enabled)
            return
        }
        if case let .about(version) = message {
            heardRelease = version
            return
        }
        if case .snapshot = message {
            // The release comes before the snapshot: none by now means a
            // Mac too old to say.
            macUpdate = Release.isOlder(heardRelease, than: Release.plugin)
                ? MacUpdate(installed: heardRelease, wanted: Release.plugin) : nil
        }
        if case let .addresses(addresses) = message {
            // Kept for the next time the Mac has to be found; this link stays.
            if let known = store.pairings().first(where: { $0.macKey == macInUse }) {
                let fresh = known.refreshed(with: addresses)
                if fresh != known { store.save(fresh) }
            }
            return
        }
        guard case let .error(code) = message else {
            state.apply(message)
            outbox.settle(with: state.sessions)
            earlier.settle(with: state.sessions)
            return
        }
        // `unknown_request` needs nothing: the card was removed on the tap.
        switch code {
        case "inject_failed", "unknown_session":
            say(Self.promptNotDeliveredMessage)
            outbox.dropLast()
        case "history_unavailable":
            earlier.failed()
        case "mode_needs_mac":
            say("This session never asks for permission, so its mode changes only on your Mac, with Shift+Tab.")
        case "unsupported_message":
            // A Mac whose plugin is older than this app: it was asked
            // either for the folders or for a session's history.
            if !launcher.failed(code: code) { earlier.failed() }
        default:
            _ = launcher.failed(code: code)
        }
    }
}
