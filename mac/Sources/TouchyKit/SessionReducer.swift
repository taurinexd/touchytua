import Foundation

/// Folds Claude Code hook events into session state.
public enum SessionReducer {
    static let knownEvents: Set<String> = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Notification",
        "Stop", "StopFailure", "SessionEnd",
    ]

    /// What Claude Code submits by itself, as a prompt, when a background
    /// command ends or it has a reminder for Claude: markup nobody wrote.
    static let machinePrompts = ["<task-notification>", "<system-reminder>"]

    /// The words of a prompt a person wrote, without the phone prefix. Nil
    /// for the prompts Claude Code writes itself.
    static func written(_ prompt: String?) -> String? {
        guard var text = prompt else { return nil }
        if text.hasPrefix(PhoneRouter.promptPrefix) { text.removeFirst(PhoneRouter.promptPrefix.count) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return machinePrompts.contains(where: text.hasPrefix) ? nil : text
    }

    /// The first line of a prompt, without the phone prefix, at most 120
    /// characters. Nil when nothing readable is left.
    static func title(fromPrompt prompt: String?) -> String? {
        guard let text = written(prompt) else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map { clipped($0, to: 120) }
    }

    /// A prompt as the phone shows it above the reply: without the phone
    /// prefix, at most 600 characters. Nil when nothing readable is left.
    static func roundPrompt(from prompt: String?) -> String? {
        guard let text = written(prompt) else { return nil }
        return text.isEmpty ? nil : clipped(text, to: 600)
    }

    /// `text` in at most `limit` characters: cut at the last space when there
    /// is one near the end, and marked with an ellipsis.
    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        var kept = text.prefix(limit - 1)
        if let space = kept.lastIndex(of: " "), kept.distance(from: space, to: kept.endIndex) <= 24 {
            kept = kept[..<space]
        }
        while let last = kept.last, last == " " || last.isPunctuation { kept.removeLast() }
        return kept + "…"
    }

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

        switch name {
        case "UserPromptSubmit":
            session.state = .working
            session.round = Round(
                startedAt: at, prompt: Self.roundPrompt(from: envelope.event["prompt"]?.stringValue))
            // A provisional title until the transcript gives a better one
            // at the end of the round: the folder name alone cannot tell
            // two sessions of one project apart.
            if session.title == (session.cwd as NSString).lastPathComponent,
               let title = Self.title(fromPrompt: envelope.event["prompt"]?.stringValue) {
                session.title = title
            }
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
                // The prefix is for Claude: when a reply quotes a phone
                // prompt, the phone shows the words without it.
                round.summary = summary.replacingOccurrences(of: PhoneRouter.promptPrefix, with: "")
            }
            session.round = round
        default:
            break
        }
        sessions[id] = session
    }
}
