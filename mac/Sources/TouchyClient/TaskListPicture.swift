import Foundation
import TouchyProtocol

/// A session's task list as Claude Code draws it in the terminal: the
/// same tasks, in the same order, with the same line about the rest.
public struct TaskListPicture: Equatable, Sendable {
    /// How many tasks the terminal shows at a time.
    public static let shownAtATime = 5

    public struct Row: Equatable, Sendable, Identifiable {
        public let task: SessionTask
        /// The tasks it waits for that are not done yet, by number.
        public let openBlockers: [String]

        public var id: String { task.id }

        /// Said after the subject of a task that cannot start yet.
        public var waitingFor: String? {
            openBlockers.isEmpty ? nil : "› blocked by " + openBlockers.map { "#" + $0 }.joined(separator: ", ")
        }
    }

    public let rows: [Row]
    /// About the tasks not shown: "… +40 tasks (2 open, 38 done)".
    public let more: String?
    public let done: Int
    public let total: Int
    /// "2 in progress", when any is.
    public let inProgress: String?

    public var heading: String { "\(done)/\(total) \(total == 1 ? "task" : "tasks") done" }

    /// - Parameters:
    ///   - justCompleted: the tasks seen to complete a moment ago: they stay
    ///     on top for a while, so that the tick is seen.
    ///   - limit: how many rows; nil for the whole list.
    public init(tasks: [SessionTask], justCompleted: Set<String> = [], limit: Int? = TaskListPicture.shownAtATime) {
        let open = Set(tasks.filter { $0.status != .completed }.map(\.id))
        let shown: [SessionTask], hidden: [SessionTask]
        if let limit, tasks.count > limit {
            let completed = tasks.filter { $0.status == .completed }.sorted(by: Self.inOrder)
            let waits = { (task: SessionTask) in task.blockedBy.contains(where: open.contains) }
            let pending = tasks.filter { $0.status == .pending }.sorted {
                waits($0) != waits($1) ? !waits($0) : Self.inOrder($0, $1)
            }
            let ranked = completed.filter { justCompleted.contains($0.id) }
                + tasks.filter { $0.status == .inProgress }.sorted(by: Self.inOrder)
                + pending
                + completed.filter { !justCompleted.contains($0.id) }
            shown = Array(ranked.prefix(limit))
            hidden = Array(ranked.dropFirst(limit))
        } else {
            shown = tasks.sorted(by: Self.inOrder)
            hidden = []
        }
        rows = shown.map { task in
            Row(task: task, openBlockers: task.blockedBy.filter(open.contains).sorted(by: Self.numbers))
        }
        more = Self.line(about: hidden)
        total = tasks.count
        done = tasks.count - open.count
        let running = tasks.filter { $0.status == .inProgress }.count
        inProgress = running > 0 ? "\(running) in progress" : nil
    }

    private static func line(about hidden: [SessionTask]) -> String? {
        guard !hidden.isEmpty else { return nil }
        let count = { (status: SessionTask.Status) in hidden.filter { $0.status == status }.count }
        let parts = [(count(.inProgress), "in progress"), (count(.pending), "open"), (count(.completed), "done")]
            .filter { $0.0 > 0 }
        // One kind only: the number before the brackets already says how many.
        let what = parts.count == 1 ? parts[0].1 : parts.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        return "… +\(hidden.count) \(hidden.count == 1 ? "task" : "tasks") (\(what))"
    }

    /// By number; ids that are not numbers by name.
    private static func inOrder(_ a: SessionTask, _ b: SessionTask) -> Bool {
        numbers(a.id, b.id)
    }

    private static func numbers(_ a: String, _ b: String) -> Bool {
        if let x = Int(a), let y = Int(b) { return x < y }
        return a < b
    }
}

/// Remembers when each task was seen to complete. What was already done
/// at the first look is not news.
public struct CompletedWatch: Equatable, Sendable {
    /// How long a completed task stays on top of the list.
    public static let news: TimeInterval = 30

    /// Nil for a task that was done before the watch began.
    private var seen: [String: Date?]?

    public init() {}

    public mutating func observe(_ tasks: [SessionTask], at now: Date) {
        let completed = Set(tasks.filter { $0.status == .completed }.map(\.id))
        guard var known = seen else {
            seen = Dictionary(uniqueKeysWithValues: completed.map { ($0, Date?.none) })
            return
        }
        for id in completed where known[id] == nil { known[id] = .some(now) }
        for id in known.keys where !completed.contains(id) { known[id] = nil }
        seen = known
    }

    public func justCompleted(at now: Date) -> Set<String> {
        Set((seen ?? [:]).compactMap { id, at in
            at.map { now.timeIntervalSince($0) < Self.news } == true ? id : nil
        })
    }

    /// When the picture next changes by itself: a task stops being news.
    public func nextChange(after now: Date) -> Date? {
        (seen ?? [:]).values.compactMap { $0?.addingTimeInterval(Self.news) }.filter { $0 > now }.min()
    }
}
