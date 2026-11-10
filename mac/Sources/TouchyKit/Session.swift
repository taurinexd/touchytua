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
    /// Inbox socket and token from SessionStart; used to inject prompts.
    /// Never sent to the phone.
    public var inboxSocket: String?
    public var inboxToken: String?

    public init(
        id: String, title: String, cwd: String, state: SessionState,
        round: Round? = nil, lastEventAt: Date, inboxSocket: String? = nil, inboxToken: String? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.state = state
        self.round = round
        self.lastEventAt = lastEventAt
        self.inboxSocket = inboxSocket
        self.inboxToken = inboxToken
    }

    /// The copy that leaves the Mac: inbox credentials stripped.
    public var forPhone: Session {
        var copy = self
        copy.inboxSocket = nil
        copy.inboxToken = nil
        return copy
    }
}

/// What `touchytua-hook` sends to the daemon: the raw hook payload plus the
/// capture time (hooks can reach the socket out of order) and, on
/// SessionStart only, the session's inbox credentials.
public struct HookEnvelope: Codable, Sendable {
    public let v: Int
    public let capturedAt: Double
    public let event: [String: JSONValue]
    public let messagingSocket: String?
    public let messagingToken: String?

    public init(
        v: Int, capturedAt: Double, event: [String: JSONValue],
        messagingSocket: String? = nil, messagingToken: String? = nil
    ) {
        self.v = v
        self.capturedAt = capturedAt
        self.event = event
        self.messagingSocket = messagingSocket
        self.messagingToken = messagingToken
    }

    public var eventName: String? { event["hook_event_name"]?.stringValue }
    public var sessionId: String? { event["session_id"]?.stringValue }
}
