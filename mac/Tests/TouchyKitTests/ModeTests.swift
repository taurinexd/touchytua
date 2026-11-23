import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

@Suite struct ModeTests {
    private func event(_ name: String, at: Double, mode: String? = "default", tool: String? = nil,
                       input: [String: JSONValue] = ["command": .string("ls")]) -> HookEnvelope {
        var e: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string("s1"), "cwd": .string("/p/app")]
        if let mode { e["permission_mode"] = .string(mode) }
        if let tool { e["tool_name"] = .string(tool); e["tool_input"] = .object(input) }
        return HookEnvelope(v: 1, capturedAt: at, event: e)
    }

    private func json(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private func openRequest(_ hub: Hub) async -> PendingRequest? {
        for _ in 0..<400 where await hub.pending.openRequests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        return await hub.pending.openRequests.first
    }

    @Test func theSessionShowsTheModeClaudeCodeReports() async {
        let hub = Hub()
        _ = await hub.handle(event("UserPromptSubmit", at: 1, mode: "acceptEdits"))
        #expect(await hub.sessions["s1"]?.mode == "acceptEdits")
        // An event without the field leaves it as it was.
        _ = await hub.handle(event("Notification", at: 2, mode: nil))
        #expect(await hub.sessions["s1"]?.mode == "acceptEdits")
    }

    @Test func aModeChosenOnThePhoneWaitsForClaudesNextStep() async {
        let hub = Hub()
        _ = await hub.handle(event("UserPromptSubmit", at: 1))
        #expect(await hub.setMode(sessionId: "s1", mode: "plan"))
        let session = await hub.sessions["s1"]
        #expect(session?.mode == "default")
        #expect(session?.nextMode == "plan")
    }

    @Test func onlyTheFourModesOfTheCycleCanBeChosen() async {
        let hub = Hub()
        _ = await hub.handle(event("UserPromptSubmit", at: 1))
        #expect(await !hub.setMode(sessionId: "s1", mode: "bypassPermissions"))
        #expect(await !hub.setMode(sessionId: "s1", mode: "dontAsk"))
        #expect(await !hub.setMode(sessionId: "nope", mode: "plan"))
        #expect(await hub.sessions["s1"]?.nextMode == nil)
    }

    @Test func choosingTheModeItIsAlreadyInChangesNothing() async {
        let hub = Hub()
        _ = await hub.handle(event("UserPromptSubmit", at: 1))
        _ = await hub.setMode(sessionId: "s1", mode: "plan")
        #expect(await hub.setMode(sessionId: "s1", mode: "default"))
        #expect(await hub.sessions["s1"]?.nextMode == nil)
        #expect(json(await hub.handle(event("PreToolUse", at: 2, tool: "Bash"))) == "{}\n")
    }

    /// Claude Code changes mode only in the answer to a permission
    /// request: the next tool call is made to ask for one.
    @Test func theNextToolCallIsMadeToAskForPermission() async {
        let hub = Hub()
        _ = await hub.handle(event("UserPromptSubmit", at: 1))
        _ = await hub.setMode(sessionId: "s1", mode: "plan")
        let reply = json(await hub.handle(event("PreToolUse", at: 2, tool: "Read")))
        #expect(reply.contains(#""hookEventName":"PreToolUse""#))
        #expect(reply.contains(#""permissionDecision":"ask""#))
        // One request is enough: the calls beside it are left alone.
        #expect(json(await hub.handle(event("PreToolUse", at: 2.1, tool: "Grep"))) == "{}\n")
    }

    @Test func approvingTheRequestCarriesTheNewMode() async {
        let hub = Hub()
        _ = await hub.handle(event("UserPromptSubmit", at: 1))
        _ = await hub.setMode(sessionId: "s1", mode: "acceptEdits")
        let hook = Task { await hub.handle(event("PermissionRequest", at: 2, tool: "Bash")) }
        let request = await openRequest(hub)
        #expect(await hub.decide(requestId: request?.id ?? "", allow: true, message: nil))
        let reply = json(await hook.value)
        #expect(reply.contains(#""behavior":"allow""#))
        #expect(reply.contains(#""updatedPermissions":[{"destination":"session","mode":"acceptEdits","type":"setMode"}]"#))
    }

    @Test func aDenialCarriesNoModeAndTheChangeKeepsWaiting() async {
        let hub = Hub()
        _ = await hub.handle(event("UserPromptSubmit", at: 1))
        _ = await hub.setMode(sessionId: "s1", mode: "acceptEdits")
        #expect(json(await hub.handle(event("PreToolUse", at: 2, tool: "Bash"))).contains("ask"))
        let hook = Task { await hub.handle(event("PermissionRequest", at: 2.1, tool: "Bash")) }
        let request = await openRequest(hub)
        _ = await hub.decide(requestId: request?.id ?? "", allow: false, message: nil)
        #expect(!json(await hook.value).contains("updatedPermissions"))
        #expect(await hub.sessions["s1"]?.nextMode == "acceptEdits")
        // The next tool call asks again.
        #expect(json(await hub.handle(event("PreToolUse", at: 3, tool: "Bash"))).contains("ask"))
    }

    @Test func theChangeIsDoneOnceClaudeCodeReportsTheNewMode() async {
        let hub = Hub()
        _ = await hub.handle(event("UserPromptSubmit", at: 1))
        _ = await hub.setMode(sessionId: "s1", mode: "plan")
        _ = await hub.handle(event("PostToolUse", at: 2, mode: "plan", tool: "Read"))
        let session = await hub.sessions["s1"]
        #expect(session?.mode == "plan")
        #expect(session?.nextMode == nil)
        #expect(json(await hub.handle(event("PreToolUse", at: 3, mode: "plan", tool: "Read"))) == "{}\n")
    }

    /// A mode this Mac does not have (auto switched off, say) is asked
    /// for once: it must not make every later tool call ask.
    @Test func aModeClaudeCodeDoesNotTakeIsGivenUp() async {
        let hub = Hub(clock: { Date(timeIntervalSince1970: 2) })
        _ = await hub.handle(event("UserPromptSubmit", at: 1))
        _ = await hub.setMode(sessionId: "s1", mode: "auto")
        let hook = Task { await hub.handle(event("PermissionRequest", at: 2, tool: "Bash")) }
        let request = await openRequest(hub)
        _ = await hub.decide(requestId: request?.id ?? "", allow: true, message: nil)
        _ = await hook.value
        // Right after the answer the old mode may still be reported.
        _ = await hub.handle(event("PostToolUse", at: 2.5, tool: "Bash"))
        #expect(await hub.sessions["s1"]?.nextMode == "auto")
        _ = await hub.handle(event("PreToolUse", at: 9, tool: "Bash"))
        #expect(await hub.sessions["s1"]?.nextMode == nil)
        #expect(json(await hub.handle(event("PreToolUse", at: 10, tool: "Bash"))) == "{}\n")
    }

    @Test func thePhoneAsksForAModeThroughTheRouter() async {
        let hub = Hub()
        _ = await hub.handle(event("UserPromptSubmit", at: 1))
        let router = PhoneRouter(hub: hub) { _, _ in }
        #expect(await router.handle(.mode(sessionId: "s1", mode: "plan")).isEmpty)
        #expect(await hub.sessions["s1"]?.nextMode == "plan")
        #expect(await router.handle(.mode(sessionId: "s1", mode: "bypassPermissions")) == [.error(code: "mode_refused")])
    }

    @Test func theMessageTravels() throws {
        let message = PhoneToMac.mode(sessionId: "s1", mode: "plan")
        #expect(try JSONDecoder().decode(PhoneToMac.self, from: JSONEncoder().encode(message)) == message)
    }

    /// An older app does not know the fields, an older daemon does not send them.
    @Test func aSessionWithoutModesStillDecodes() throws {
        let old = #"{"id":"s1","title":"t","cwd":"/p","state":"done","lastEventAt":0}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(old.utf8))
        #expect(session.mode == nil && session.nextMode == nil)
    }
}
