import Foundation
import TouchyProtocol

/// A session's task list, read where Claude Code keeps it: one JSON file
/// per task in `~/.claude/tasks/<session id>/`.
public enum TaskList {
    static let longestSubject = 200
    /// More files than any real list has; the rest is not read.
    static let mostTasks = 500
    static let largestFile = 64 << 10

    /// Nil for an id that is not a plain name: it is used as a folder name.
    public static func directory(sessionId: String, userHome: String) -> String? {
        guard !sessionId.isEmpty, !sessionId.hasPrefix("."), !sessionId.contains("/") else { return nil }
        return userHome + "/.claude/tasks/" + sessionId
    }

    private struct File: Decodable {
        let id: String
        let subject: String
        let status: SessionTask.Status
        let blockedBy: [String]?
    }

    /// The tasks in `directory`, in the order of their numbers. Whatever
    /// is not a task (lock files, a deleted task, a file half written) is
    /// left out.
    public static func read(directory: String) -> [SessionTask] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let tasks = names.filter { $0.hasSuffix(".json") }.prefix(mostTasks).compactMap { name -> SessionTask? in
            let path = directory + "/" + name
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= largestFile,
                  let data = FileManager.default.contents(atPath: path),
                  let file = try? JSONDecoder().decode(File.self, from: data), !file.subject.isEmpty else { return nil }
            return SessionTask(
                id: file.id, subject: SessionReducer.clipped(file.subject, to: longestSubject), status: file.status,
                blockedBy: file.blockedBy ?? [])
        }
        return tasks.sorted(by: inOrder)
    }

    /// The older todo list, rewritten whole at each call and without
    /// numbers: they are numbered as they come.
    static func fromTodos(_ todos: JSONValue?) -> [SessionTask] {
        guard case let .array(items)? = todos else { return [] }
        return items.prefix(mostTasks).enumerated().compactMap { index, item in
            guard let todo = item.objectValue, let subject = todo["content"]?.stringValue, !subject.isEmpty,
                  let status = todo["status"]?.stringValue.flatMap(SessionTask.Status.init(rawValue:)) else { return nil }
            return SessionTask(
                id: String(index + 1), subject: SessionReducer.clipped(subject, to: longestSubject), status: status)
        }
    }

    /// By number, as Claude Code lists them; ids that are not numbers by name.
    static func inOrder(_ a: SessionTask, _ b: SessionTask) -> Bool {
        if let x = Int(a.id), let y = Int(b.id) { return x < y }
        return a.id < b.id
    }
}
