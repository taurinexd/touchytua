import Foundation

/// One line of a session's earlier conversation, as the phone shows it.
public struct HistoryItem: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// What the person asked.
        case prompt
        /// What Claude said.
        case reply
        /// The tools Claude used between two messages: their names and how
        /// many calls, never what they ran or returned.
        case tools
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let at: Date

    public init(id: String, kind: Kind, text: String, at: Date) {
        self.id = id
        self.kind = kind
        self.text = text
        self.at = at
    }
}
