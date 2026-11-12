import Foundation
// Ported from Meowtch (VedettaKit/TranscriptPeek.swift, MIT, same author).

/// Parses the transcript's ISO8601-with-fractional-seconds timestamps.
/// A fresh formatter per call keeps this free of shared mutable state.
private func parseTimestamp(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
}

/// Bounded, tolerant reader for Claude Code transcript JSONL files:
/// pulls the first real user prompt (session title) and the latest
/// user/assistant text (card body lines) without loading giant files.
public struct TranscriptPeek: Sendable {
    public var firstUserPrompt: String?
    public var lastUserText: String?
    public var lastAssistantText: String?
    /// The name the user gave the session (Claude Code records renames as
    /// system-reminder entries); the last rename wins.
    public var sessionName: String?
    /// Claude's auto-generated title (`ai-title` / `agent-name` entries),
    /// what the original shows when the user didn't name the session.
    public var aiTitle: String?
    /// Working directory recorded in the entries.
    public var cwd: String?
    /// Timestamp of the last real user/assistant message — the honest
    /// "last activity", unlike the file mtime which background writes
    /// (repeated ai-title/agent-name entries) keep artificially fresh.
    public var lastActivity: Date?
    /// Claude's "recap" (`away_summary` system entries), generated after a
    /// turn while the user is away. Shown in place of the message lines,
    /// like the original; any newer user message invalidates it.
    public var awaySummary: String?
    /// Claude's latest main-session reasoning effort, when recorded.
    public var reasoningEffort: String?

    /// Parses transcript JSONL content. Malformed lines are skipped.
    public static func parse(_ data: Data) -> TranscriptPeek {
        var peek = TranscriptPeek()
        for lineData in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)),
                  let entry = object as? [String: Any],
                  let type = entry["type"] as? String else { continue }

            // The name given with `claude --name` or /rename: an entry of
            // its own, the last one wins.
            if let name = nonEmpty(entry["customTitle"] as? String) { peek.sessionName = name }

            // Claude's auto title: standalone entries with no message body.
            if let title = (entry["aiTitle"] as? String) ?? (entry["agentName"] as? String),
               !title.isEmpty {
                peek.aiTitle = title
            }

            if entry["isSidechain"] as? Bool != true,
               let effort = nonEmpty(entry["effort"] as? String) {
                peek.reasoningEffort = effort
            }

            // The recap is a bare system entry (content string, no message).
            if type == "system", entry["subtype"] as? String == "away_summary",
               entry["isSidechain"] as? Bool != true,
               let content = entry["content"] as? String, !content.isEmpty {
                peek.awaySummary = content
            }

            guard let message = entry["message"] as? [String: Any] else { continue }
            // Subagent (sidechain) traffic interleaves with the main loop:
            // its texts are not the session's own words.
            if entry["isSidechain"] as? Bool == true { continue }

            if let cwd = entry["cwd"] as? String { peek.cwd = cwd }
            if (type == "user" || type == "assistant"),
               let stamp = entry["timestamp"] as? String,
               let date = parseTimestamp(stamp) {
                peek.lastActivity = date
            }
            guard let text = textContent(of: message), !text.isEmpty else { continue }
            switch type {
            case "user":
                if let name = namedSession(in: text) {
                    peek.sessionName = name
                    continue
                }
                // Command invocations, caveats and reminders are transport
                // noise, not something the user typed.
                guard !text.hasPrefix("<") else { continue }
                if peek.firstUserPrompt == nil { peek.firstUserPrompt = text }
                peek.lastUserText = text
                // A real user message outdates any earlier recap.
                peek.awaySummary = nil
            case "assistant":
                peek.lastAssistantText = text
            default:
                break
            }
        }
        return peek
    }

    /// Extracts NAME from `The user named this session "NAME"`.
    private static func namedSession(in text: String) -> String? {
        guard let range = text.range(of: #"The user named this session "([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let match = text[range]
        guard let open = match.firstIndex(of: "\""),
              let close = match.lastIndex(of: "\""), open < close else { return nil }
        return String(match[match.index(after: open)..<close])
    }

    /// Reads a bounded window of the file: the head answers "how did this
    /// session start" (first prompt, cwd), the tail answers "what happened
    /// last" (latest messages). Keeping them separate avoids attributing a
    /// head text as the latest message when the tail has none. Files can
    /// be tens of MB; we never load them whole.
    public static func read(path: String, headBytes: Int = 128 << 10, tailBytes: Int = 256 << 10) -> TranscriptPeek {
        guard let handle = FileHandle(forReadingAtPath: path) else { return TranscriptPeek() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0

        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: min(headBytes, size))) ?? Data()
        let headPeek = parse(head)
        guard size > headBytes else { return headPeek }

        let tailStart = max(size - tailBytes, headBytes)
        try? handle.seek(toOffset: UInt64(tailStart))
        var tail = ((try? handle.read(upToCount: size - tailStart)) ?? nil) ?? Data()
        if let newline = tail.firstIndex(of: 0x0A) {
            // drop the (possibly truncated) first line
            tail = tail.suffix(from: newline + 1)
        }
        let tailPeek = parse(tail)

        var merged = TranscriptPeek()
        merged.firstUserPrompt = headPeek.firstUserPrompt
        // The starting directory identifies the session (mid-session cd
        // into subdirectories must not relabel it); fall back to the tail
        // only when the original path no longer exists (dir renamed).
        if let headCwd = headPeek.cwd, FileManager.default.fileExists(atPath: headCwd) {
            merged.cwd = headCwd
        } else {
            merged.cwd = tailPeek.cwd ?? headPeek.cwd
        }
        merged.sessionName = tailPeek.sessionName ?? headPeek.sessionName
        merged.aiTitle = tailPeek.aiTitle ?? headPeek.aiTitle
        merged.lastUserText = tailPeek.lastUserText
        merged.lastAssistantText = tailPeek.lastAssistantText
        merged.lastActivity = tailPeek.lastActivity ?? headPeek.lastActivity
        // Tail only: a recap buried in the head predates the tail's lines.
        merged.awaySummary = tailPeek.awaySummary
        merged.reasoningEffort = tailPeek.reasoningEffort ?? headPeek.reasoningEffort

        // Renames outside these windows are picked up by the async
        // TranscriptFullScan — never a synchronous full read here.
        return merged
    }

    private static func textContent(of message: [String: Any]) -> String? {
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
