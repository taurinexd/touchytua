import Foundation

/// The JSON a `PermissionRequest` hook prints to grant or deny a request,
/// as one newline-terminated line.
public enum HookReply {
    /// Tools whose native picker Claude Code insists on unless the hook
    /// replies with data: an `allow` without `updatedInput` is discarded for
    /// them (verified in Meowtch). Kept deliberately small, because echoing
    /// an input re-runs the permission rules against it.
    public static let interactiveTools: Set<String> = ["ExitPlanMode", "AskUserQuestion"]

    /// `mode` puts the session in another permission mode along with an
    /// approval: the only moment Claude Code takes one from a hook.
    public static func permission(
        allow: Bool, message: String?, toolName: String, toolInput: [String: JSONValue], mode: String? = nil
    ) -> Data {
        var decision: [String: JSONValue] = ["behavior": .string(allow ? "allow" : "deny")]
        // A denial that echoed the input back would read as an approval of it.
        if !allow, let message { decision["message"] = .string(message) }
        if allow, interactiveTools.contains(toolName) { decision["updatedInput"] = .object(toolInput) }
        if allow, let mode { decision["updatedPermissions"] = modeChange(mode) }
        return line(decision)
    }

    /// Answers an `AskUserQuestion`: the original input plus `answers`
    /// (question text → chosen label; multi-select labels comma-joined).
    public static func question(toolInput: [String: JSONValue], answers: [String: String], mode: String? = nil) -> Data {
        var updated = toolInput
        updated["answers"] = .object(answers.mapValues { .string($0) })
        var decision: [String: JSONValue] = ["behavior": .string("allow"), "updatedInput": .object(updated)]
        if let mode { decision["updatedPermissions"] = modeChange(mode) }
        return line(decision)
    }

    /// For this session only: nothing is written to a settings file.
    private static func modeChange(_ mode: String) -> JSONValue {
        .array([.object(["type": .string("setMode"), "mode": .string(mode), "destination": .string("session")])])
    }

    /// What a `PreToolUse` hook prints to make a tool call ask for
    /// permission, whatever the rules would have said.
    public static func askForPermission(reason: String) -> Data {
        let reply: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PreToolUse"),
                "permissionDecision": .string("ask"),
                "permissionDecisionReason": .string(reason),
            ]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(reply)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    private static func line(_ decision: [String: JSONValue]) -> Data {
        let reply: JSONValue = .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(decision),
            ]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(reply)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}
