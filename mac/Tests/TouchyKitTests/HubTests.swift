import Foundation
import Testing
@testable import TouchyKit

private func env(_ name: String, session: String = "s1", at: Double, extra: [String: JSONValue] = [:]) -> HookEnvelope {
    var e: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string(session), "cwd": .string("/p/app")]
    for (k, v) in extra { e[k] = v }
    return HookEnvelope(v: 1, capturedAt: at, event: e)
}

@Suite struct HubTests {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/round.jsonl").path

    @Test func nonBlockingEventRepliesEmpty() async {
        let hub = Hub()
        let reply = await hub.handle(env("UserPromptSubmit", at: 1))
        #expect(reply == PendingRequests.emptyReply)
        #expect(await hub.sessions["s1"]?.state == .working)
    }

    @Test func permissionRequestHoldsUntilPhoneDecides() async throws {
        let hub = Hub()
        let input: [String: JSONValue] = ["command": .string("ls")]
        let task = Task { await hub.handle(env("PermissionRequest", at: 2, extra: ["tool_name": .string("Bash"), "tool_input": .object(input)])) }
        var id: String?
        for _ in 0..<200 {
            id = await hub.pending.openRequests.first?.id
            if id != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let rid = try #require(id)
        #expect(await hub.decide(requestId: rid, allow: true, message: nil))
        let reply = await task.value
        #expect(String(decoding: reply, as: UTF8.self).contains(#""behavior":"allow""#))
    }

    @Test func questionKindForAskUserQuestion() async throws {
        let hub = Hub()
        let task = Task { await hub.handle(env("PermissionRequest", at: 2, extra: ["tool_name": .string("AskUserQuestion"), "tool_input": .object([:])])) }
        for _ in 0..<200 where await hub.pending.openRequests.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(await hub.pending.openRequests.first?.kind == .question)
        await hub.pending.cancelAll(sessionId: "s1", by: .terminal)
        _ = await task.value
    }

    @Test func stopClosesPendingAsTerminal() async throws {
        let hub = Hub()
        let task = Task { await hub.handle(env("PermissionRequest", at: 2, extra: ["tool_name": .string("Bash"), "tool_input": .object([:])])) }
        for _ in 0..<200 where await hub.pending.openRequests.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        _ = await hub.handle(env("Stop", at: 3))
        #expect(await task.value == PendingRequests.emptyReply)
        #expect(await hub.pending.openRequests.isEmpty)
    }

    @Test func stopEnrichesRoundFromTranscript() async {
        let hub = Hub()
        let start = ISO8601DateFormatter().date(from: "2026-11-06T10:05:00Z")!.timeIntervalSince1970
        _ = await hub.handle(env("UserPromptSubmit", at: start))
        _ = await hub.handle(env("Stop", at: start + 10, extra: ["transcript_path": .string(fixture)]))
        let s = await hub.sessions["s1"]
        #expect(s?.round?.tokens == 1700)
        #expect(s?.title == "vecchio prompt")
    }
}

@Suite struct HubUsageTests {
    private func usageEnv(_ session: String, _ statusline: String) -> HookEnvelope {
        let input = try! JSONDecoder().decode(JSONValue.self, from: Data(statusline.utf8))
        return HookEnvelope(v: 1, capturedAt: 1, event: [
            "hook_event_name": .string("touchytua_usage"), "session_id": .string(session), "statusline": input])
    }

    @Test func usageSumsCostAcrossSessionsAndKeepsLatestLimits() async {
        let hub = Hub()
        _ = await hub.handle(usageEnv("a", #"{"cost":{"total_cost_usd":1.5},"rate_limits":{"five_hour":{"used_percentage":40}}}"#))
        _ = await hub.handle(usageEnv("b", #"{"cost":{"total_cost_usd":2.0},"rate_limits":{"five_hour":{"used_percentage":55},"seven_day":{"used_percentage":9}}}"#))
        _ = await hub.handle(usageEnv("a", #"{"cost":{"total_cost_usd":2.5}}"#))
        #expect(await hub.usage == Usage(totalCostUSD: 4.5, fiveHourPct: 55, sevenDayPct: 9))
        #expect(await hub.sessions.isEmpty)
    }
}
