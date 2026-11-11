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
        "Can't reach \(macName). Join the same Wi-Fi, or turn on Tailscale on both."
    }

    public private(set) var status: ConnectionStatus
    /// The last picture received from the Mac. Kept while reconnecting.
    public private(set) var state = ClientState()
    public private(set) var macName: String?
    /// A problem worth a line on screen that is not a connection problem.
    public private(set) var notice: String?

    @ObservationIgnored private let store: any SecretStore
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let dial: Dial
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var link: PhoneLink?
    /// Bumped by `stop`; work started before it must not touch the state.
    @ObservationIgnored private var epoch = 0

    public init(store: any SecretStore, deviceName: String, timing: Timing = Timing(), dial: @escaping Dial) {
        self.store = store
        self.deviceName = deviceName
        self.timing = timing
        self.dial = dial
        let paired = store.pairings().first
        macName = paired?.macName
        status = paired == nil ? .unpaired : .connecting
    }

    // MARK: lifecycle

    /// Connects to the paired Mac and keeps reconnecting until `stop`.
    public func start() {
        guard runner == nil else { return }
        guard let record = store.pairings().first else {
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
        runner?.cancel()
        runner = nil
        if let link {
            self.link = nil
            Task { await link.close() }
        }
        if case .failed = status { return }
        status = store.pairings().isEmpty ? .unpaired : .connecting
    }

    /// Pairs with the Mac whose QR says `url`, replacing the current one.
    public func pair(url: String) async {
        guard let payload = try? PairingPayload.parse(url: url) else {
            status = .failed(Self.notAPairingCodeMessage)
            return
        }
        stop()
        let mine = epoch
        status = .connecting
        let record = PairingRecord(macName: payload.macName, macKey: payload.macKey, endpoints: payload.endpoints)
        let outcome = await reach(record, secret: payload.secret)
        guard mine == epoch else {
            if case let .connected(link, _) = outcome { await link.close() }
            return
        }
        switch outcome {
        case let .connected(link, endpoint):
            for old in store.pairings() { store.remove(macKey: old.macKey) }
            store.save(record)
            macName = record.macName
            state = ClientState()
            runner = Task { [weak self] in await self?.run(record, established: (link, endpoint)) }
        case .rejected:
            status = .failed(Self.qrExpiredMessage)
        case .unreachable:
            status = .failed(Self.unreachableMessage(payload.macName))
        }
    }

    public func unpair() {
        stop()
        for record in store.pairings() { store.remove(macKey: record.macKey) }
        state = ClientState()
        macName = nil
        notice = nil
        status = .unpaired
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
        await link.send(.prompt(sessionId: sessionId, text: text))
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

    private enum Outcome {
        case connected(PhoneLink, endpoint: String)
        /// The paired Mac itself said no.
        case rejected
        case unreachable
    }

    /// One round over the Mac's addresses, in order.
    private func reach(_ record: PairingRecord, secret: Data?) async -> Outcome {
        guard let phoneKey = try? store.phoneKey() else { return .unreachable }
        for endpoint in record.endpoints {
            if Task.isCancelled { break }
            do {
                let link = try await Self.open(
                    endpoint, dial: dial, phoneKey: phoneKey, macKey: record.macKey,
                    secret: secret, timeout: timing.connectTimeout)
                return .connected(link, endpoint: endpoint)
            } catch LinkError.rejected {
                return .rejected
            } catch {
                continue
            }
        }
        return .unreachable
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
        while !Task.isCancelled {
            if established == nil {
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
                await link.send(.hello(deviceName: deviceName))
                while let message = try? await link.next(), !Task.isCancelled {
                    // A link counts as good once the Mac has actually spoken.
                    failures = 0
                    receive(message)
                }
                await link.close()
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
        guard case let .error(code) = message else {
            state.apply(message)
            return
        }
        // `unknown_request` needs nothing: the card was removed on the tap.
        if code == "inject_failed" || code == "unknown_session" {
            notice = Self.promptNotDeliveredMessage
        }
    }
}
