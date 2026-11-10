import Foundation

/// Header numbers: API cost and plan rate-limit windows.
public struct Usage: Codable, Equatable, Sendable {
    public var totalCostUSD: Double?
    public var fiveHourPct: Double?
    public var sevenDayPct: Double?

    public init(totalCostUSD: Double? = nil, fiveHourPct: Double? = nil, sevenDayPct: Double? = nil) {
        self.totalCostUSD = totalCostUSD
        self.fiveHourPct = fiveHourPct
        self.sevenDayPct = sevenDayPct
    }
}

/// Phone → Mac, inside the secure channel. JSON discriminated by `"t"`.
public enum PhoneToMac: Codable, Equatable, Sendable {
    case hello(deviceName: String)
    case decide(requestId: String, allow: Bool, message: String?)
    case answer(requestId: String, answers: [String: String])
    case prompt(sessionId: String, text: String)
    /// A type this build does not know (a newer app): ignored, never fatal.
    case unknown(String)

    private enum Keys: String, CodingKey { case t, deviceName, requestId, allow, message, answers, sessionId, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "hello": self = .hello(deviceName: try c.decode(String.self, forKey: .deviceName))
        case "decide": self = .decide(requestId: try c.decode(String.self, forKey: .requestId),
                                      allow: try c.decode(Bool.self, forKey: .allow),
                                      message: try c.decodeIfPresent(String.self, forKey: .message))
        case "answer": self = .answer(requestId: try c.decode(String.self, forKey: .requestId),
                                      answers: try c.decode([String: String].self, forKey: .answers))
        case "prompt": self = .prompt(sessionId: try c.decode(String.self, forKey: .sessionId),
                                      text: try c.decode(String.self, forKey: .text))
        case let t: self = .unknown(t)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .unknown(t): try c.encode(t, forKey: .t)
        case let .hello(name):
            try c.encode("hello", forKey: .t); try c.encode(name, forKey: .deviceName)
        case let .decide(id, allow, message):
            try c.encode("decide", forKey: .t); try c.encode(id, forKey: .requestId)
            try c.encode(allow, forKey: .allow); try c.encodeIfPresent(message, forKey: .message)
        case let .answer(id, answers):
            try c.encode("answer", forKey: .t); try c.encode(id, forKey: .requestId); try c.encode(answers, forKey: .answers)
        case let .prompt(sid, text):
            try c.encode("prompt", forKey: .t); try c.encode(sid, forKey: .sessionId); try c.encode(text, forKey: .text)
        }
    }
}

/// Mac → phone, inside the secure channel. JSON discriminated by `"t"`.
public enum MacToPhone: Codable, Equatable, Sendable {
    case snapshot(sessions: [Session], pending: [PendingRequest], usage: Usage?)
    case session(Session)
    case sessionRemoved(id: String)
    case request(PendingRequest)
    case requestResolved(id: String, by: ResolvedBy)
    case usage(Usage)
    case error(code: String)
    /// A type this build does not know (a newer plugin): ignored, never fatal.
    case unknown(String)

    private enum Keys: String, CodingKey { case t, sessions, pending, usage, session, id, request, by, code }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "snapshot": self = .snapshot(sessions: try c.decode([Session].self, forKey: .sessions),
                                          pending: try c.decode([PendingRequest].self, forKey: .pending),
                                          usage: try c.decodeIfPresent(Usage.self, forKey: .usage))
        case "session": self = .session(try c.decode(Session.self, forKey: .session))
        case "sessionRemoved": self = .sessionRemoved(id: try c.decode(String.self, forKey: .id))
        case "request": self = .request(try c.decode(PendingRequest.self, forKey: .request))
        case "requestResolved": self = .requestResolved(id: try c.decode(String.self, forKey: .id),
                                                        by: try c.decode(ResolvedBy.self, forKey: .by))
        case "usage": self = .usage(try c.decode(Usage.self, forKey: .usage))
        case "error": self = .error(code: try c.decode(String.self, forKey: .code))
        case let t: self = .unknown(t)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .unknown(t): try c.encode(t, forKey: .t)
        case let .snapshot(sessions, pending, usage):
            try c.encode("snapshot", forKey: .t); try c.encode(sessions, forKey: .sessions)
            try c.encode(pending, forKey: .pending); try c.encodeIfPresent(usage, forKey: .usage)
        case let .session(s): try c.encode("session", forKey: .t); try c.encode(s, forKey: .session)
        case let .sessionRemoved(id): try c.encode("sessionRemoved", forKey: .t); try c.encode(id, forKey: .id)
        case let .request(r): try c.encode("request", forKey: .t); try c.encode(r, forKey: .request)
        case let .requestResolved(id, by):
            try c.encode("requestResolved", forKey: .t); try c.encode(id, forKey: .id); try c.encode(by, forKey: .by)
        case let .usage(u): try c.encode("usage", forKey: .t); try c.encode(u, forKey: .usage)
        case let .error(code): try c.encode("error", forKey: .t); try c.encode(code, forKey: .code)
        }
    }
}
