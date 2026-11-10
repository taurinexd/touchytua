import Foundation

/// Applies the phone's messages to the hub. Transport-free.
public struct PhoneRouter: Sendable {
    /// Claude Code labels inbox messages as coming from another session
    /// (phase-0 T1); the prefix tells Claude who actually wrote them.
    public static let promptPrefix = "[Sent by the user from their phone via touchytua] "

    let hub: Hub
    let inject: @Sendable (InboxCredentials, String) throws -> Void

    public init(hub: Hub, inject: @escaping @Sendable (InboxCredentials, String) throws -> Void) {
        self.hub = hub
        self.inject = inject
    }

    public func snapshot() async -> MacToPhone {
        let sessions = await hub.sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
        return .snapshot(sessions: sessions, pending: await hub.pending.openRequests, usage: await hub.usage)
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
                try inject(inbox, Self.promptPrefix + text)
                return []
            } catch {
                return [.error(code: "inject_failed")]
            }
        }
    }
}
