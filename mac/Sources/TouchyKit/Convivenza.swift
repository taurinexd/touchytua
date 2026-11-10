import Foundation

/// Another tool's hook that can answer approvals or questions alongside
/// touchytua. Reported, never modified.
public struct Conflict: Equatable, Sendable {
    public let event: String
    public let matcher: String
    public let command: String
    /// "user", "project", "local" or "plugin:<name@marketplace>".
    public let source: String

    public init(event: String, matcher: String, command: String, source: String) {
        self.event = event
        self.matcher = matcher
        self.command = command
        self.source = source
    }
}

public enum ConflictScan {
    /// The user's `crossSessionInbound` setting, nil when unset. `hold` and
    /// `refuse` stop prompts sent through the inbox socket.
    public static func crossSessionInbound(home: URL) -> String? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["crossSessionInbound"] as? String
    }

    public static func scan(home: URL, projectDir: URL?) -> [Conflict] {
        var found: [Conflict] = []
        let userSettings = readJSON(home.appendingPathComponent(".claude/settings.json"))
        found += conflicts(in: userSettings?["hooks"], source: "user")
        if let projectDir {
            found += conflicts(in: readJSON(projectDir.appendingPathComponent(".claude/settings.json"))?["hooks"], source: "project")
            found += conflicts(in: readJSON(projectDir.appendingPathComponent(".claude/settings.local.json"))?["hooks"], source: "local")
        }
        // Enabled plugins, located through Claude Code's install registry.
        let enabled = (userSettings?["enabledPlugins"] as? [String: Any] ?? [:]).filter { ($0.value as? Bool) == true }.keys
        let registry = readJSON(home.appendingPathComponent(".claude/plugins/installed_plugins.json"))?["plugins"] as? [String: Any] ?? [:]
        for name in enabled.sorted() {
            guard let installs = registry[name] as? [[String: Any]],
                  let path = installs.first?["installPath"] as? String else { continue }
            let root = URL(fileURLWithPath: path)
            var hooks = readJSON(root.appendingPathComponent("hooks/hooks.json"))?["hooks"]
            if hooks == nil { hooks = readJSON(root.appendingPathComponent(".claude-plugin/plugin.json"))?["hooks"] as? [String: Any] }
            found += conflicts(in: hooks, source: "plugin:\(name)")
        }
        return found
    }

    static func conflicts(in hooks: Any?, source: String) -> [Conflict] {
        guard let hooks = hooks as? [String: Any] else { return [] }
        var out: [Conflict] = []
        for event in ["PermissionRequest", "PreToolUse"] {
            for group in hooks[event] as? [[String: Any]] ?? [] {
                let matcher = (group["matcher"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "*"
                if event == "PreToolUse", !matches(matcher, "AskUserQuestion") { continue }
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    let command = (hook["command"] as? String) ?? (hook["url"] as? String) ?? (hook["type"] as? String ?? "?")
                    if command.contains("touchytua") { continue }
                    out.append(Conflict(event: event, matcher: matcher, command: command, source: source))
                }
            }
        }
        return out
    }

    /// Claude Code matchers are regular expressions over the tool name; "*" matches all.
    static func matches(_ matcher: String, _ tool: String) -> Bool {
        if matcher == "*" { return true }
        guard let re = try? NSRegularExpression(pattern: "^(?:\(matcher))$") else { return matcher == tool }
        return re.firstMatch(in: tool, range: NSRange(tool.startIndex..., in: tool)) != nil
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Opt-in chained statusline: touchytua's wrapper reads cost and rate
/// limits, then runs the user's previous statusline with the same input.
/// Plugins cannot set `statusLine` themselves (only `agent` and
/// `subagentStatusLine` apply), so `/pair` offers this edit explicitly.
public enum StatusLineChain {
    static func stateFile(_ dir: String) -> URL { URL(fileURLWithPath: dir).appendingPathComponent("statusline-previous.json") }

    /// Backs up settings.json, swaps in the wrapper, remembers the previous command.
    /// Returns the backup's URL.
    @discardableResult
    public static func install(settingsURL: URL, wrapperPath: String, stateDirectory: String) throws -> URL {
        let original = (try? Data(contentsOf: settingsURL)) ?? Data("{}".utf8)
        let backup = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.touchytua-backup-\(Int(Date().timeIntervalSince1970))")
        try original.write(to: backup)
        var settings = (try JSONSerialization.jsonObject(with: original)) as? [String: Any] ?? [:]
        let current = (settings["statusLine"] as? [String: Any])?["command"] as? String
        if current != wrapperPath {
            // Remember what was there (possibly nothing) only on the first install.
            try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let record: [String: Any] = ["previous": settings["statusLine"] ?? NSNull()]
            try JSONSerialization.data(withJSONObject: record).write(to: stateFile(stateDirectory))
        }
        settings["statusLine"] = ["type": "command", "command": wrapperPath]
        try rewrite(settingsURL, original: original, with: settings)
        return backup
    }

    public static func uninstall(settingsURL: URL, stateDirectory: String) throws {
        guard let original = try? Data(contentsOf: settingsURL),
              var settings = (try JSONSerialization.jsonObject(with: original)) as? [String: Any],
              let recordData = try? Data(contentsOf: stateFile(stateDirectory)),
              let record = (try? JSONSerialization.jsonObject(with: recordData)) as? [String: Any] else { return }
        if let previous = record["previous"] as? [String: Any] {
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try rewrite(settingsURL, original: original, with: settings)
        try? FileManager.default.removeItem(at: stateFile(stateDirectory))
    }

    public static func previousCommand(stateDirectory: String) -> String? {
        guard let data = try? Data(contentsOf: stateFile(stateDirectory)),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (record["previous"] as? [String: Any])?["command"] as? String
    }

    /// Cost and rate limits from the statusline JSON Claude Code pipes in.
    public static func usage(fromStatusLineInput data: Data) -> Usage? {
        guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let limits = input["rate_limits"] as? [String: Any]
        func pct(_ window: String) -> Double? {
            ((limits?[window] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue
        }
        let cost = ((input["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue
        return Usage(totalCostUSD: cost, fiveHourPct: pct("five_hour"), sevenDayPct: pct("seven_day"))
    }

    private static func rewrite(_ url: URL, original: Data, with settings: [String: Any]) throws {
        let text: String
        if let document = try? OrderedJSONDocument(data: original) {
            text = document.merged(with: settings).serialized()
        } else {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
            text = String(decoding: data, as: UTF8.self)
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
