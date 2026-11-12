import Foundation

/// Applies the phone's messages to the hub. Transport-free.
public struct PhoneRouter: Sendable {
    let hub: Hub
    let inject: @Sendable (InboxCredentials, String) throws -> Void

    public init(hub: Hub, inject: @escaping @Sendable (InboxCredentials, String) throws -> Void) {
        self.hub = hub
        self.inject = inject
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
        }
    }
}
