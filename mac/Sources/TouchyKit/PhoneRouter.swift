import Foundation

/// Applies the phone's messages to the hub. Transport-free.
public struct PhoneRouter: Sendable {
    let hub: Hub
    let inject: @Sendable (InboxCredentials, String) throws -> Void
    /// Where the phone may start a session, and whether it may at all.
    let folders: @Sendable () -> (items: [StartFolder], enabled: Bool)
    /// Starts a session; returns why not when it does not.
    let start: @Sendable (_ folder: String, _ prompt: String, _ name: String?) -> SessionLaunch.Refusal?

    public init(
        hub: Hub, inject: @escaping @Sendable (InboxCredentials, String) throws -> Void,
        folders: @escaping @Sendable () -> (items: [StartFolder], enabled: Bool) = { ([], false) },
        start: @escaping @Sendable (String, String, String?) -> SessionLaunch.Refusal? = { _, _, _ in .disabled }
    ) {
        self.hub = hub
        self.inject = inject
        self.folders = folders
        self.start = start
    }

    public func snapshot() async -> MacToPhone {
        let sessions = await hub.sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
        let pending = await hub.pending.openRequests.map { $0.forPhone() }
        return .snapshot(sessions: sessions, pending: pending, usage: await hub.usage)
    }

    /// What a change in the hub looks like to the phone. Together with
    /// `snapshot`, the only place where Mac-side data becomes a message.
    public static func message(for change: Hub.Change) -> MacToPhone {
        switch change {
        case let .session(session): .session(session)
        case let .sessionRemoved(id): .sessionRemoved(id: id)
        case let .pending(.opened(request)): .request(request.forPhone())
        case let .pending(.resolved(id, by)): .requestResolved(id: id, by: by)
        case let .usage(usage): .usage(usage)
        }
    }

    /// Returns the messages to send back to this phone.
    public func handle(_ message: PhoneToMac) async -> [MacToPhone] {
        switch message {
        case .unknown:
            return [.error(code: "unsupported_message")]
        case .hello:
            return [await snapshot()]
        case let .decide(id, allow, text):
            return await hub.decide(requestId: id, allow: allow, message: text) ? [] : [.error(code: "unknown_request")]
        case let .answer(id, answers):
            return await hub.answer(requestId: id, answers: answers) ? [] : [.error(code: "unknown_request")]
        case let .prompt(sessionId, text):
            guard await hub.sessions[sessionId] != nil else { return [.error(code: "unknown_session")] }
            // A session without an inbox (messaging off) cannot be prompted.
            guard let inbox = await hub.inbox[sessionId] else { return [.error(code: "inject_failed")] }
            do {
                try inject(inbox, text)
                return []
            } catch {
                return [.error(code: "inject_failed")]
            }
        case let .history(sessionId, before):
            // The first page stops where the round on screen begins.
            guard let session = await hub.sessions[sessionId], let path = await hub.transcript(of: sessionId),
                  let page = TranscriptHistory.page(path: path, before: before, roundStart: session.round?.startedAt)
            else { return [.error(code: "history_unavailable")] }
            return [.history(sessionId: sessionId, items: page.items, next: page.next)]
        case .folders:
            let (items, enabled) = folders()
            return [.folders(items: items, enabled: enabled)]
        case let .mode(sessionId, mode):
            return await hub.chooseMode(sessionId: sessionId, mode: mode).map { [.error(code: $0.rawValue)] } ?? []
        case let .start(folder, prompt, name):
            // The new session announces itself through its own hooks.
            return start(folder, prompt, name).map { [.error(code: $0.rawValue)] } ?? []
        }
    }
}
