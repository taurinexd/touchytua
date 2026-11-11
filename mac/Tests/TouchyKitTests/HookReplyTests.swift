import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

private func decode(_ data: Data) throws -> [String: JSONValue] {
    #expect(data.last == 0x0A, "reply must end with a newline")
    #expect(!data.dropLast().contains(0x0A), "reply must be a single line")
    return try JSONDecoder().decode([String: JSONValue].self, from: data)
}

private func decision(_ reply: [String: JSONValue]) -> [String: JSONValue]? {
    reply["hookSpecificOutput"]?.objectValue?["decision"]?.objectValue
}

@Suite struct HookReplyTests {
    let bashInput: [String: JSONValue] = ["command": .string("ls"), "description": .string("List")]

    @Test func denyCarriesMessage() throws {
        let reply = try decode(HookReply.permission(allow: false, message: "no", toolName: "Bash", toolInput: bashInput))
        #expect(reply["hookSpecificOutput"]?.objectValue?["hookEventName"] == .string("PermissionRequest"))
        #expect(decision(reply)?["behavior"] == .string("deny"))
        #expect(decision(reply)?["message"] == .string("no"))
        #expect(decision(reply)?["updatedInput"] == nil)
    }

    @Test func allowBashHasNoUpdatedInput() throws {
        let reply = try decode(HookReply.permission(allow: true, message: nil, toolName: "Bash", toolInput: bashInput))
        #expect(decision(reply)?["behavior"] == .string("allow"))
        #expect(decision(reply)?["updatedInput"] == nil)
        #expect(decision(reply)?["message"] == nil)
    }

    @Test func allowExitPlanEchoesInput() throws {
        let input: [String: JSONValue] = ["plan": .string("# Piano")]
        let reply = try decode(HookReply.permission(allow: true, message: nil, toolName: "ExitPlanMode", toolInput: input))
        #expect(decision(reply)?["updatedInput"] == .object(input))
    }

    @Test func questionAddsAnswers() throws {
        let questions: JSONValue = .array([.object([
            "question": .string("Quale?"),
            "options": .array([.object(["label": .string("A")]), .object(["label": .string("B")])]),
        ])])
        let reply = try decode(HookReply.question(toolInput: ["questions": questions], answers: ["Quale?": "B"]))
        #expect(decision(reply)?["behavior"] == .string("allow"))
        let updated = decision(reply)?["updatedInput"]?.objectValue
        #expect(updated?["questions"] == questions)
        #expect(updated?["answers"] == .object(["Quale?": .string("B")]))
    }
}
