import Foundation
import TouchyProtocol

/// The sessions put away from the list on this phone. A session comes back
/// by itself when it is asked something new, or when it asks something.
public struct SessionArchive: Codable, Equatable, Sendable {
    /// Sessions end and their ids are never seen again: beyond this many,
    /// the oldest are forgotten.
    static let most = 300

    private struct Entry: Codable, Equatable, Sendable {
        /// When the round it was in began; nil before its first prompt.
        var roundStartedAt: Date?
        var at: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// As kept between launches; anything unreadable is an empty archive.
    public init(data: Data) {
        self = (try? JSONDecoder().decode(SessionArchive.self, from: data)) ?? SessionArchive()
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public mutating func put(away session: Session, at now: Date) {
        entries[session.id] = Entry(roundStartedAt: session.round?.startedAt, at: now)
        if entries.count > Self.most {
            for id in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - Self.most).map(\.key) {
                entries[id] = nil
            }
        }
    }

    /// True while the session is in the round it was put away in and asks
    /// nothing: a new prompt starts a new round, and a question must be seen.
    public func hides(_ session: Session, waitingOnYou: Bool) -> Bool {
        guard !waitingOnYou, let entry = entries[session.id] else { return false }
        return entry.roundStartedAt == session.round?.startedAt
    }

    public func hidden(among sessions: [Session], waitingOnYou: (Session) -> Bool) -> Int {
        sessions.filter { hides($0, waitingOnYou: waitingOnYou($0)) }.count
    }

    public mutating func bringAllBack() {
        entries = [:]
    }
}
