import Foundation

/// Who settled a pending request.
public enum ResolvedBy: String, Codable, Sendable {
    /// The paired phone answered.
    case phone
    /// Something else did: the terminal dialog, another tool's hook, or the
    /// session moving on.
    case terminal
}

/// A permission or question waiting for an answer.
public struct PendingRequest: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case permission, question }

    public let id: String
    public let sessionId: String
    public let kind: Kind
    public let toolName: String
    public let toolInput: [String: JSONValue]
    public let createdAt: Date
    /// True when long strings of `toolInput` were cut before sending.
    public let truncated: Bool

    public init(
        id: String, sessionId: String, kind: Kind, toolName: String,
        toolInput: [String: JSONValue], createdAt: Date, truncated: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.toolName = toolName
        self.toolInput = toolInput
        self.createdAt = createdAt
        self.truncated = truncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        kind = try c.decode(Kind.self, forKey: .kind)
        toolName = try c.decode(String.self, forKey: .toolName)
        toolInput = try c.decode([String: JSONValue].self, forKey: .toolInput)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}
