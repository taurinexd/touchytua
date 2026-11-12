import Foundation

/// What a session is doing right now, in a few words, for the phone's
/// line under "This Round".
public enum Activity {
    /// The tool calls that keep Claude's own notes: they say nothing about
    /// the work, and the task board reads them instead.
    static let bookkeeping: Set<String> = [
        "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TodoWrite", "AskUserQuestion",
    ]

    /// A tool call in a few words. Nil when the call says nothing about the work.
    public static func line(tool: String, input: [String: JSONValue]) -> String? {
        guard !bookkeeping.contains(tool) else { return nil }
        let file = input["file_path"]?.stringValue.map { ($0 as NSString).lastPathComponent }.flatMap(nonEmpty)
        let described = input["description"]?.stringValue.flatMap(nonEmpty)
        let line: String
        switch tool {
        case "Bash": line = described ?? "Running a command"
        case "Read": line = "Reading " + (file ?? "a file")
        case "Edit", "MultiEdit", "NotebookEdit": line = "Editing " + (file ?? "a file")
        case "Write": line = "Writing " + (file ?? "a file")
        case "Grep", "Glob": line = "Searching the code"
        case "WebSearch": line = "Searching the web"
        case "WebFetch":
            let host = input["url"]?.stringValue.flatMap { URL(string: $0)?.host }
            line = "Reading " + (host ?? "a web page")
        case "Agent", "Task": line = described ?? "Running an agent"
        case "Skill": line = "Using " + (input["skill"]?.stringValue.flatMap(nonEmpty) ?? "a skill")
        default:
            line = "Using " + toolName(tool)
        }
        return SessionReducer.clipped(line, to: 80)
    }

    /// A tool's name as people know it: for mcp__<server>__<tool>, the server.
    public static func toolName(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        return tool.hasPrefix("mcp__") && parts.count >= 3 ? parts[1].replacingOccurrences(of: "_", with: " ") : tool
    }

    private static func nonEmpty(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Claude's own task list for one session, as far as the daemon saw it:
/// the task in progress is the best name for what the session is doing.
public struct TaskBoard: Sendable {
    /// What to call each task while it is being worked on, by task id.
    private var names: [String: String] = [:]
    private var inProgress: String?
    /// Set by the older todo list, which is rewritten whole each time.
    private var todo: String?

    public init() {}

    public var current: String? { inProgress.flatMap { names[$0] } ?? todo }

    /// Takes one finished task-list call: its input and what the tool answered.
    public mutating func note(tool: String, input: [String: JSONValue], response: JSONValue?) {
        switch tool {
        case "TaskCreate":
            guard let id = response?.objectValue?["task"]?.objectValue?["id"]?.stringValue else { return }
            names[id] = Self.name(input)
        case "TaskUpdate":
            guard let id = input["taskId"]?.stringValue else { return }
            if let name = input["activeForm"]?.stringValue, !name.isEmpty { names[id] = name }
            switch input["status"]?.stringValue {
            case "in_progress": inProgress = id
            case "completed", "deleted": if inProgress == id { inProgress = nil }
            default: break
            }
        case "TodoWrite":
            guard case let .array(todos)? = input["todos"] else { return }
            todo = todos.compactMap(\.objectValue)
                .first { $0["status"]?.stringValue == "in_progress" }
                .flatMap { Self.name($0) }
        default:
            break
        }
    }

    private static func name(_ task: [String: JSONValue]) -> String? {
        for key in ["activeForm", "subject", "content"] {
            if let text = task[key]?.stringValue, !text.isEmpty { return SessionReducer.clipped(text, to: 80) }
        }
        return nil
    }
}
