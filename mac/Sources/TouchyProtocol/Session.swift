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

    public init(startedAt: Date, endedAt: Date? = nil, tokens: Int? = nil, summary: String? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tokens = tokens
        self.summary = summary
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
}
