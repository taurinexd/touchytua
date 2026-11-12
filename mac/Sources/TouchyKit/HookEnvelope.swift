import Foundation

/// What `touchytua-hook` sends to the daemon: the raw hook payload plus the
/// capture time (hooks can reach the socket out of order) and the session's
/// inbox credentials.
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

    /// The session's inbox, when the hook saw both halves of it.
    public var inbox: InboxCredentials? {
        guard let messagingSocket, let messagingToken else { return nil }
        return InboxCredentials(socket: messagingSocket, token: messagingToken)
    }
}

/// How to post a prompt into a session: its inbox socket and token.
/// Mac-only on purpose: the types sent to the phone cannot carry it.
public struct InboxCredentials: Codable, Equatable, Sendable {
    public let socket: String
    public let token: String

    public init(socket: String, token: String) {
        self.socket = socket
        self.token = token
    }
}

/// One entry of the registry on disk.
public struct StoredSession: Codable, Equatable, Sendable {
    public let session: Session
    public let inbox: InboxCredentials?
    /// Where the session's transcript is: its earlier conversation.
    public let transcript: String?

    public init(session: Session, inbox: InboxCredentials?, transcript: String? = nil) {
        self.session = session
        self.inbox = inbox
        self.transcript = transcript
    }
}
