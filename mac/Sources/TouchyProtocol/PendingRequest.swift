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

    public init(
        id: String, sessionId: String, kind: Kind, toolName: String,
        toolInput: [String: JSONValue], createdAt: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.toolName = toolName
        self.toolInput = toolInput
        self.createdAt = createdAt
    }
}
