import Foundation

/// The JSON a `PermissionRequest` hook prints to grant or deny a request,
/// as one newline-terminated line.
public enum HookReply {
    /// Tools whose native picker Claude Code insists on unless the hook
    /// replies with data: an `allow` without `updatedInput` is discarded for
    /// them (verified in Meowtch). Kept deliberately small, because echoing
    /// an input re-runs the permission rules against it.
    public static let interactiveTools: Set<String> = ["ExitPlanMode", "AskUserQuestion"]

    public static func permission(
        allow: Bool, message: String?, toolName: String, toolInput: [String: JSONValue]
    ) -> Data {
        var decision: [String: JSONValue] = ["behavior": .string(allow ? "allow" : "deny")]
        // A denial that echoed the input back would read as an approval of it.
        if !allow, let message { decision["message"] = .string(message) }
        if allow, interactiveTools.contains(toolName) { decision["updatedInput"] = .object(toolInput) }
        return line(decision)
    }

    /// Answers an `AskUserQuestion`: the original input plus `answers`
    /// (question text → chosen label; multi-select labels comma-joined).
    public static func question(toolInput: [String: JSONValue], answers: [String: String]) -> Data {
        var updated = toolInput
        updated["answers"] = .object(answers.mapValues { .string($0) })
        return line(["behavior": .string("allow"), "updatedInput": .object(updated)])
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
