import Foundation
import TouchyProtocol

/// Everything the app shows, folded from the Mac's messages.
public struct ClientState: Equatable, Sendable {
    public struct Counts: Equatable, Sendable {
        public var working = 0, waiting = 0, done = 0, failed = 0

        public init(working: Int = 0, waiting: Int = 0, done: Int = 0, failed: Int = 0) {
            self.working = working
            self.waiting = waiting
            self.done = done
            self.failed = failed
        }
    }

    /// Sessions waiting on the user first, then by most recent activity.
    public private(set) var sessions: [Session] = []
    /// Open permission requests and questions, oldest first.
    public private(set) var pending: [PendingRequest] = []
    public private(set) var usage: Usage?

    public init() {}

    public mutating func apply(_ message: MacToPhone) {
        switch message {
        case let .snapshot(sessions, pending, usage):
            self.sessions = sessions
            self.pending = pending
            self.usage = usage
        case let .session(session):
            sessions.removeAll { $0.id == session.id }
            sessions.append(session)
        case let .sessionRemoved(id):
            sessions.removeAll { $0.id == id }
            pending.removeAll { $0.sessionId == id }
        case let .request(request):
            pending.removeAll { $0.id == request.id }
            pending.append(request)
        case let .requestResolved(id, _):
            pending.removeAll { $0.id == id }
        case let .usage(usage):
            self.usage = usage
        case .error, .unknown:
            return
        }
        sessions.sort {
            let (a, b) = ($0.state == .waiting, $1.state == .waiting)
            return a != b ? a : $0.lastEventAt > $1.lastEventAt
        }
        pending.sort { $0.createdAt < $1.createdAt }
    }

    public func requests(for sessionId: String) -> [PendingRequest] {
        pending.filter { $0.sessionId == sessionId }
    }

    /// Dropped locally when the Mac says a request is already settled.
    public mutating func forget(requestId: String) {
        pending.removeAll { $0.id == requestId }
    }

    public var counts: Counts {
        var counts = Counts()
        for session in sessions {
            switch session.state {
            case .working: counts.working += 1
            case .waiting: counts.waiting += 1
            case .done, .ready: counts.done += 1
            case .error: counts.failed += 1
            }
        }
        return counts
    }
}
