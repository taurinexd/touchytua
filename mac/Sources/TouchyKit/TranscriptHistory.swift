import Foundation

/// A session's earlier conversation, read from its transcript one page at
/// a time, newest page first. Only what was said: prompts, replies and the
/// names of the tools used in between. Never tool input or output, never
/// thinking, never what subagents did.
public enum TranscriptHistory {
    public struct Page: Equatable, Sendable {
        /// Oldest first.
        public var items: [HistoryItem]
        /// Where the page before this one ends; nil at the start of the
        /// conversation.
        public var next: String?
    }

    /// The `limit` messages that come before `cursor`, or before the round
    /// that started at `roundStart` when there is no cursor yet: that round
    /// is already on screen. Nil when the transcript cannot be read.
    ///
    /// Transcripts reach hundreds of MB: the file is read backwards, a
    /// `window` at a time. Nothing is cut, so a page stops early once it
    /// holds `budget` bytes of text, and the rest comes with the next one.
    public static func page(
        path: String, before cursor: String?, roundStart: Date?,
        limit: Int = 20, budget: Int = 256 << 10, window: Int = 512 << 10
    ) -> Page? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        var end = min(cursor.flatMap(Int.init) ?? size, size)
        let bound = cursor == nil ? roundStart : nil

        var newestFirst: [HistoryItem] = []
        var tools: [Unit] = []
        var messages = 0, bytes = 0
        var window = max(window, 1)

        func flushTools() {
            guard let newest = tools.first else { return }
            var names: [String] = []
            for tool in tools.reversed() where !names.contains(tool.text) { names.append(tool.text) }
            let calls = tools.count == 1 ? "1 tool call" : "\(tools.count) tool calls"
            newestFirst.append(HistoryItem(
                id: "tools-" + newest.id, kind: .tools, text: names.joined(separator: ", ") + " · " + calls, at: newest.at))
            tools = []
        }

        while end > 0 {
            let start = max(end - window, 0)
            try? handle.seek(toOffset: UInt64(start))
            let data = ((try? handle.read(upToCount: end - start)) ?? nil) ?? Data()
            // The window opens mid-line: that line belongs to the next read.
            var first = data.startIndex
            if start > 0 {
                guard let newline = data.firstIndex(of: 0x0A), newline + 1 < data.endIndex else {
                    window *= 4
                    continue
                }
                first = newline + 1
            }
            var lineEnd = data.endIndex
            while lineEnd > first {
                // Each line ends in a newline; find where it starts.
                let body = data[first..<(lineEnd - 1)]
                let lineStart = body.lastIndex(of: 0x0A).map { $0 + 1 } ?? first
                let offset = start + (lineStart - data.startIndex)
                let units = Self.units(in: data[lineStart..<lineEnd], fallbackId: String(offset))
                    .filter { unit in bound.map { unit.at < (unit.kind == .prompt ? $0 - promptLead : $0) } ?? true }
                let said = units.filter { $0.kind != .tools }
                let weight = said.reduce(0) { $0 + $1.text.utf8.count }
                if messages > 0, !said.isEmpty, bytes + weight > budget {
                    flushTools()
                    return Page(items: newestFirst.reversed(), next: String(start + (lineEnd - data.startIndex)))
                }
                for unit in units.reversed() {
                    if unit.kind == .tools {
                        tools.append(unit)
                    } else {
                        flushTools()
                        newestFirst.append(HistoryItem(id: unit.id, kind: unit.kind, text: unit.text, at: unit.at))
                        messages += 1
                    }
                }
                bytes += weight
                if messages >= limit {
                    return Page(items: newestFirst.reversed(), next: offset > 0 ? String(offset) : nil)
                }
                lineEnd = lineStart
            }
            end = start + (first - data.startIndex)
        }
        flushTools()
        return Page(items: newestFirst.reversed(), next: nil)
    }

    /// Claude Code writes a prompt to the transcript a moment before the
    /// hook that starts its round runs: a prompt this close to the start
    /// of a round is the one that started it.
    private static let promptLead: TimeInterval = 5

    /// Something said, or a tool called, in one transcript line.
    private struct Unit {
        let id: String
        let kind: HistoryItem.Kind
        let text: String
        let at: Date
    }

    /// What one transcript line holds, in the order it happened.
    private static func units(in line: Data, fallbackId: String) -> [Unit] {
        guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              entry["isSidechain"] as? Bool != true,
              let type = entry["type"] as? String,
              let message = entry["message"] as? [String: Any],
              let stamp = entry["timestamp"] as? String, let at = timestamp(stamp) else { return [] }
        let id = entry["uuid"] as? String ?? fallbackId
        let blocks = message["content"] as? [[String: Any]] ?? []

        switch type {
        case "user":
            guard entry["isCompactSummary"] as? Bool != true else { return [] }
            let text = (message["content"] as? String)
                ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
            if let words = PhonePrompt.words(in: text) { return [Unit(id: id, kind: .prompt, text: words, at: at)] }
            // What Claude Code writes in the person's place: notices,
            // commands, what other sessions sent.
            guard entry["isMeta"] as? Bool != true else { return [] }
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty, !notWritten.contains(where: words.hasPrefix) else { return [] }
            return [Unit(id: id, kind: .prompt, text: words, at: at)]
        case "assistant":
            return blocks.enumerated().compactMap { index, block in
                switch block["type"] as? String {
                case "text":
                    let words = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return words.isEmpty ? nil : Unit(id: "\(id)-\(index)", kind: .reply, text: words, at: at)
                case "tool_use":
                    guard let name = block["name"] as? String else { return nil }
                    return Unit(id: "\(id)-\(index)", kind: .tools, text: Activity.toolName(name), at: at)
                default:
                    return nil
                }
            }
        default:
            return []
        }
    }

    /// How the lines that are not a prompt begin.
    private static let notWritten = ["<", "[Request interrupted", "Another Claude session sent a message:"]

    private static func timestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
