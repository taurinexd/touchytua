import Foundation
import TouchyProtocol

/// The earlier conversation of the sessions, as far as it has been asked
/// for. Kept in memory only: leaving a session lets go of it.
public struct Earlier: Equatable, Sendable {
    public struct Page: Equatable, Sendable {
        /// Oldest first.
        public var items: [HistoryItem] = []
        public var isLoading = false
        /// The Mac could not give this session's history.
        public var isUnavailable = false
        /// Everything up to the start of the conversation is here.
        var isComplete = false
        /// Where the next request continues from.
        var cursor: String?
        /// The round that was on screen when the first page was asked for.
        var upTo: Date?

        public init() {}

        public var canLoadMore: Bool { !isLoading && !isComplete && !isUnavailable }
    }

    private var pages: [String: Page] = [:]
    /// The session whose page is on its way.
    private var asked: String?

    public init() {}

    public func page(of sessionId: String) -> Page {
        pages[sessionId] ?? Page()
    }

    /// Marks the session as loading and returns the cursor to send: nil
    /// inside the optional for the first page. Nil when there is nothing
    /// to ask: a request is on its way, or it is all here.
    public mutating func ask(_ session: Session) -> String?? {
        var page = pages[session.id] ?? Page()
        guard asked == nil, page.canLoadMore else { return nil }
        if page.items.isEmpty, page.cursor == nil { page.upTo = session.round?.startedAt }
        page.isLoading = true
        pages[session.id] = page
        asked = session.id
        return .some(page.cursor)
    }

    public mutating func received(sessionId: String, items: [HistoryItem], next: String?) {
        guard asked == sessionId, var page = pages[sessionId] else { return }
        asked = nil
        page.items.insert(contentsOf: items, at: 0)
        page.cursor = next
        page.isComplete = next == nil
        page.isLoading = false
        pages[sessionId] = page
    }

    /// The Mac answered the request with an error.
    public mutating func failed() {
        guard let sessionId = asked else { return }
        asked = nil
        pages[sessionId]?.isLoading = false
        pages[sessionId]?.isUnavailable = true
    }

    /// The connection dropped with a request on its way.
    public mutating func interrupted() {
        guard let sessionId = asked else { return }
        asked = nil
        pages[sessionId]?.isLoading = false
    }

    public mutating func forget(_ sessionId: String) {
        pages[sessionId] = nil
        if asked == sessionId { asked = nil }
    }

    /// Lets go of the history of sessions that are gone, and of those that
    /// started a new round: what was loaded stops short of the round that
    /// was on screen, which is history now.
    public mutating func settle(with sessions: [Session]) {
        for (id, page) in pages {
            guard let session = sessions.first(where: { $0.id == id }) else { forget(id); continue }
            if page.upTo != session.round?.startedAt, !(page.items.isEmpty && !page.isLoading && !page.isUnavailable) {
                forget(id)
            }
        }
    }
}
