import Foundation
import TouchyProtocol

/// How numbers read on screen.
public enum Format {
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h\(String(format: "%02d", s % 3600 / 60))m"
    }

    public static func tokens(_ count: Int) -> String {
        if count < 1_000 { return "\(count) token" }
        let thousands = Int((Double(count) / 1_000).rounded())
        if thousands < 1_000 { return "\(thousands)k token" }
        return "\(String(format: "%.1f", Double(count) / 1_000_000))M token"
    }

    public static func cost(_ dollars: Double) -> String {
        "$" + String(format: dollars < 10 ? "%.2f" : "%.1f", dollars)
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

extension Session {
    /// The one line a row shows: the first non-empty line of the title, or
    /// the folder name when there is no title yet.
    public var headline: String {
        let line = title.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? (cwd as NSString).lastPathComponent
    }
}

extension Round {
    /// "Worked for 1m35s · 2k token", or "Working for 12s" while it runs.
    public func caption(now: Date) -> String {
        let time = endedAt.map { "Worked for " + Format.duration($0.timeIntervalSince(startedAt)) }
            ?? "Working for " + Format.duration(now.timeIntervalSince(startedAt))
        return tokens.map { time + " · " + Format.tokens($0) } ?? time
    }
}

/// One question of an `AskUserQuestion` request.
public struct Question: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let description: String?

        public init(label: String, description: String?) {
            self.label = label
            self.description = description
        }
    }

    public let text: String
    public let header: String?
    public let multiSelect: Bool
    public let options: [Option]

    public init(text: String, header: String?, multiSelect: Bool, options: [Option]) {
        self.text = text
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }

    /// The `answers` to send: one entry per question, several labels joined
    /// in the order the options were shown. Nil until every question has
    /// at least one pick.
    public static func answers(to questions: [Question], picked: [String: Set<String>]) -> [String: String]? {
        guard !questions.isEmpty else { return nil }
        var answers: [String: String] = [:]
        for question in questions {
            let labels = question.options.map(\.label).filter { picked[question.text]?.contains($0) == true }
            guard !labels.isEmpty else { return nil }
            answers[question.text] = labels.joined(separator: ", ")
        }
        return answers
    }
}

extension PendingRequest {
    /// What the tool is about to do, in one glance: the command, the file,
    /// the address. For a tool this build does not know, its simple inputs.
    public var detail: String {
        for key in ["command", "file_path", "notebook_path", "url", "query", "plan"] {
            if let value = toolInput[key]?.stringValue { return value }
        }
        return toolInput.keys.sorted().compactMap { key in
            switch toolInput[key] {
            case let .string(s): "\(key): \(s)"
            case let .number(n): "\(key): \(n == n.rounded() ? String(Int(n)) : String(n))"
            case let .bool(b): "\(key): \(b)"
            default: nil
            }
        }.joined(separator: "\n")
    }

    public var questions: [Question] {
        guard case let .array(items)? = toolInput["questions"] else { return [] }
        return items.compactMap { item in
            guard let fields = item.objectValue, let text = fields["question"]?.stringValue,
                  case let .array(options)? = fields["options"] else { return nil }
            var multiSelect = false
            if case let .bool(flag)? = fields["multiSelect"] { multiSelect = flag }
            return Question(
                text: text, header: fields["header"]?.stringValue, multiSelect: multiSelect,
                options: options.compactMap { option in
                    guard let label = option.objectValue?["label"]?.stringValue else { return nil }
                    return Question.Option(label: label, description: option.objectValue?["description"]?.stringValue)
                })
        }
    }
}
