import Foundation

/// Session state as the phone shows it.
public enum SessionState: String, Codable, Sendable {
    case ready, working, waiting, done, error
}

/// One prompt-to-stop cycle: what the "This Round" detail shows.
public struct Round: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date?
    public var tokens: Int?
    public var summary: String?
    /// What the person asked for in this round.
    public var prompt: String?
    /// What the session is doing right now, in a few words, while the
    /// round runs.
    public var activity: String?

    public init(
        startedAt: Date, endedAt: Date? = nil, tokens: Int? = nil, summary: String? = nil, prompt: String? = nil,
        activity: String? = nil
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tokens = tokens
        self.summary = summary
        self.prompt = prompt
        self.activity = activity
    }
}

public struct Session: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var cwd: String
    public var state: SessionState
    public var round: Round?
    public var lastEventAt: Date

    public init(
        id: String, title: String, cwd: String, state: SessionState,
        round: Round? = nil, lastEventAt: Date
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.state = state
        self.round = round
        self.lastEventAt = lastEventAt
    }

    /// True when the two would be shown the same: everything except the
    /// timestamp of the last event.
    public func looksTheSame(as other: Session) -> Bool {
        var a = self, b = other
        a.lastEventAt = .distantPast
        b.lastEventAt = .distantPast
        return a == b
    }

    /// True when the two differ at most in what changes many times a
    /// round: the line about what the session is doing and its running
    /// token count. Neither is worth writing to disk.
    public func isWorthKeepingTheSame(as other: Session) -> Bool {
        var a = self, b = other
        a.round?.activity = nil
        b.round?.activity = nil
        if a.round?.endedAt == nil, b.round?.endedAt == nil {
            a.round?.tokens = nil
            b.round?.tokens = nil
        }
        return a.looksTheSame(as: b)
    }
}
