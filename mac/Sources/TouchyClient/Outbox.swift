import Foundation
import TouchyProtocol

/// The prompts sent from this phone that Claude has not taken up yet. A
/// session reads a prompt when its current step is over: until then the
/// phone keeps showing it, so that sending is never met with silence.
public struct Outbox: Equatable, Sendable {
    public struct Prompt: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let sessionId: String
        public let text: String
        /// The round that was on screen when the prompt left: that one is
        /// not its answer.
        let sentDuring: Date?
    }

    private var prompts: [Prompt] = []

    public init() {}

    public func waiting(in sessionId: String) -> [Prompt] {
        prompts.filter { $0.sessionId == sessionId }
    }

    public mutating func sent(_ text: String, to session: Session?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !text.isEmpty else { return }
        prompts.append(Prompt(id: UUID(), sessionId: session.id, text: text, sentDuring: session.round?.startedAt))
    }

    /// Lets go of the prompts a session has started working on, one per new
    /// round, and of those whose session is gone.
    public mutating func settle(with sessions: [Session]) {
        var taken = Set<String>()
        prompts.removeAll { prompt in
            guard let session = sessions.first(where: { $0.id == prompt.sessionId }) else { return true }
            guard let round = session.round, round.startedAt != prompt.sentDuring,
                  !taken.contains(session.id), Self.shows(round.prompt, prompt.text) else { return false }
            taken.insert(session.id)
            return true
        }
    }

    /// The Mac said the last prompt could not be delivered.
    public mutating func dropLast() {
        if !prompts.isEmpty { prompts.removeLast() }
    }

    /// The Mac sends back a long prompt cut short and ending in an ellipsis.
    private static func shows(_ shown: String?, _ sent: String) -> Bool {
        guard var shown else { return false }
        guard shown.hasSuffix("…") else { return shown == sent }
        shown.removeLast()
        return !shown.isEmpty && sent.hasPrefix(shown)
    }
}
