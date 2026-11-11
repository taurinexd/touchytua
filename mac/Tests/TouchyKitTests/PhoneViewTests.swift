import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

@Suite struct PhoneViewTests {
    private func request(_ input: [String: JSONValue], tool: String = "Write") -> PendingRequest {
        PendingRequest(id: "r1", sessionId: "s1", kind: .permission, toolName: tool, toolInput: input,
                       createdAt: Date(timeIntervalSince1970: 1))
    }

    /// A megabyte `Write` must not travel to the phone: long strings are cut.
    @Test func longStringsAreCutAtAnyDepth() {
        let long = String(repeating: "x", count: 5000)
        let view = request([
            "file_path": .string("/p/a.txt"), "content": .string(long),
            "edits": .array([.object(["new_string": .string(long)])]),
        ]).forPhone(limit: 100)
        #expect(view.truncated)
        #expect(view.toolInput["file_path"] == .string("/p/a.txt"))
        #expect(view.toolInput["content"]?.stringValue?.count == 101)
        #expect(view.toolInput["content"]?.stringValue?.hasSuffix("…") == true)
        guard case let .array(edits)? = view.toolInput["edits"], case let .object(edit)? = edits.first else {
            Issue.record("edits lost"); return
        }
        #expect(edit["new_string"]?.stringValue?.count == 101)
    }

    @Test func shortInputIsUntouched() {
        let original = request(["command": .string("ls -la")], tool: "Bash")
        #expect(original.forPhone() == original)
        #expect(!original.forPhone().truncated)
    }

    /// Older builds send no `truncated` field.
    @Test func truncatedDefaultsToFalseWhenAbsent() throws {
        let json = #"{"id":"r1","sessionId":"s1","kind":"permission","toolName":"Bash","toolInput":{},"createdAt":1}"#
        #expect(try JSONDecoder().decode(PendingRequest.self, from: Data(json.utf8)).truncated == false)
    }

    /// The phone gets the short view; the hook is answered with the full input.
    @Test func phoneSeesTheShortViewButTheHookGetsTheFullInput() async throws {
        let hub = Hub()
        let router = PhoneRouter(hub: hub) { _, _ in }
        let plan = String(repeating: "p", count: 5000)
        let hook = Task {
            await hub.handle(HookEnvelope(v: 1, capturedAt: 1, event: [
                "hook_event_name": .string("PermissionRequest"), "session_id": .string("s1"), "cwd": .string("/p"),
                "tool_name": .string("ExitPlanMode"), "tool_input": .object(["plan": .string(plan)])]))
        }
        for _ in 0..<200 where await hub.pending.openRequests.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let full = try #require(await hub.pending.openRequests.first)

        guard case let .snapshot(_, pending, _) = await router.snapshot() else { Issue.record("no snapshot"); return }
        #expect(pending.first?.truncated == true)
        #expect(pending.first?.toolInput["plan"]?.stringValue?.count == PendingRequest.phoneStringLimit + 1)
        guard case let .request(pushed) = PhoneRouter.message(for: .pending(.opened(full))) else {
            Issue.record("no request message"); return
        }
        #expect(pushed.truncated)

        #expect(await hub.decide(requestId: full.id, allow: true, message: nil))
        #expect(String(decoding: await hook.value, as: UTF8.self).contains(plan))
    }
}
