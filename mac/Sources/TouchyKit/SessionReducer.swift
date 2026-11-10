import Foundation

/// Folds Claude Code hook events into session state.
public enum SessionReducer {
    static let knownEvents: Set<String> = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Notification",
        "Stop", "StopFailure", "SessionEnd",
    ]

    /// Notification types that mean "the session waits for the user".
    static let waitingNotifications: Set<String> = [
        "permission_prompt", "elicitation_dialog", "agent_needs_input",
    ]

    public static func apply(_ envelope: HookEnvelope, to sessions: inout [String: Session]) {
        guard let name = envelope.eventName, knownEvents.contains(name),
              let id = envelope.sessionId else { return }
        let at = Date(timeIntervalSince1970: envelope.capturedAt)

        if name == "SessionEnd" {
            sessions[id] = nil
            return
        }

        var session = sessions[id] ?? {
            let cwd = envelope.event["cwd"]?.stringValue ?? ""
            return Session(
                id: id, title: (cwd as NSString).lastPathComponent, cwd: cwd,
                state: .ready, lastEventAt: at
            )
        }()
        // Hooks of one lifecycle may arrive out of order: a late, older
        // event must not undo a newer transition.
        if sessions[id] != nil, at < session.lastEventAt { return }
        session.lastEventAt = at
        // Every event carries the inbox credentials: a daemon restarted
        // mid-session never sees that session's SessionStart again.
        if let socket = envelope.messagingSocket { session.inboxSocket = socket }
        if let token = envelope.messagingToken { session.inboxToken = token }

        switch name {
        case "UserPromptSubmit":
            session.state = .working
            session.round = Round(startedAt: at)
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            session.state = .working
        case "PermissionRequest":
            session.state = .waiting
        case "Notification":
            if let type = envelope.event["notification_type"]?.stringValue,
               waitingNotifications.contains(type) {
                session.state = .waiting
            }
        case "Stop", "StopFailure":
            session.state = name == "Stop" ? .done : .error
            var round = session.round ?? Round(startedAt: at)
            round.endedAt = at
            if let summary = envelope.event["last_assistant_message"]?.stringValue {
                round.summary = summary
            }
            session.round = round
        default:
            break
        }
        sessions[id] = session
    }
}
