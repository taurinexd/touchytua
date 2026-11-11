import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

private func env(
    _ name: String, session: String = "s1", at: Double, extra: [String: JSONValue] = [:], socket: String? = nil
) -> HookEnvelope {
    var e: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string(session), "cwd": .string("/p/app")]
    for (k, v) in extra { e[k] = v }
    return HookEnvelope(v: 1, capturedAt: at, event: e, messagingSocket: socket, messagingToken: socket.map { _ in "tok" })
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

@Suite struct HubLateTranscriptTests {
    private func line(_ id: String, _ stamp: String, tokens: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"\#(id)","content":[],"usage":{"output_tokens":\#(tokens)}}}"# + "\n"
    }

    /// The last message of a round can reach the transcript after the Stop hook.
    @Test func tokensWrittenAfterTheStopAreCountedOnASecondLook() async throws {
        let path = NSTemporaryDirectory() + "tt-late-" + UUID().uuidString + ".jsonl"
        try Data(line("msg_1", "2026-11-11T16:13:59.000Z", tokens: 154).utf8).write(to: URL(fileURLWithPath: path))
        let changes = Changes()
        let looks = AsyncStream<Void>.makeStream()
        let hub = Hub(onChange: { changes.add($0) }, secondLooks: [.seconds(1)]) { _ in
            for await _ in looks.stream { break }
        }
        let start = ISO8601DateFormatter().date(from: "2026-11-11T16:13:56Z")!.timeIntervalSince1970
        _ = await hub.handle(env("UserPromptSubmit", at: start))
        _ = await hub.handle(env("Stop", at: start + 227, extra: ["transcript_path": .string(path)]))
        #expect(await hub.sessions["s1"]?.round?.tokens == 154)

        let handle = try #require(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(line("msg_2", "2026-11-11T16:17:42.000Z", tokens: 5).utf8))
        try handle.close()
        looks.continuation.yield()

        for _ in 0..<400 where await hub.sessions["s1"]?.round?.tokens != 159 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await hub.sessions["s1"]?.round?.tokens == 159)
        #expect(changes.sessionTokens.last == 159)
    }

    /// A new round has started by the time of the second look: leave it alone.
    @Test func aSecondLookDoesNotTouchANewerRound() async throws {
        let path = NSTemporaryDirectory() + "tt-late-" + UUID().uuidString + ".jsonl"
        try Data(line("msg_1", "2026-11-11T16:13:59.000Z", tokens: 154).utf8).write(to: URL(fileURLWithPath: path))
        let looks = AsyncStream<Void>.makeStream()
        let done = AsyncStream<Void>.makeStream()
        let hub = Hub(secondLooks: [.seconds(1)]) { _ in
            for await _ in looks.stream { break }
            done.continuation.yield()
        }
        let start = ISO8601DateFormatter().date(from: "2026-11-11T16:13:56Z")!.timeIntervalSince1970
        _ = await hub.handle(env("UserPromptSubmit", at: start))
        _ = await hub.handle(env("Stop", at: start + 10, extra: ["transcript_path": .string(path)]))
        _ = await hub.handle(env("UserPromptSubmit", at: start + 20))
        looks.continuation.yield()
        for await _ in done.stream { break }
        try await Task.sleep(for: .milliseconds(30))

        #expect(await hub.sessions["s1"]?.round?.tokens == nil)
    }
}

private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Hub.Change] = []
    func add(_ c: Hub.Change) { lock.lock(); items.append(c); lock.unlock() }
    var removed: [String] {
        lock.lock(); defer { lock.unlock() }
        return items.compactMap { if case let .sessionRemoved(id) = $0 { return id } else { return nil } }
    }
    var sessionTokens: [Int?] {
        lock.lock(); defer { lock.unlock() }
        return items.compactMap { if case let .session(session) = $0 { return .some(session.round?.tokens) } else { return nil } }
    }
    var sessionUpdates: Int {
        lock.lock(); defer { lock.unlock() }
        return items.filter { if case .session = $0 { return true } else { return false } }.count
    }
}

@Suite struct HubChangeTests {
    /// Tool calls inside one turn do not change what the phone shows:
    /// they must not be re-sent.
    @Test func eventsThatChangeNothingVisibleAreNotEmitted() async {
        let changes = Changes()
        let hub = Hub { changes.add($0) }
        _ = await hub.handle(env("UserPromptSubmit", at: 1))
        #expect(changes.sessionUpdates == 1)
        _ = await hub.handle(env("PreToolUse", at: 2, extra: ["tool_name": .string("Bash")]))
        _ = await hub.handle(env("PostToolUse", at: 3, extra: ["tool_name": .string("Bash")]))
        #expect(changes.sessionUpdates == 1)
        _ = await hub.handle(env("Stop", at: 4))
        #expect(changes.sessionUpdates == 2)
    }
}

@Suite struct HubReapTests {
    /// A session that died without SessionEnd (crash, kill, closed terminal)
    /// must leave the list, and its open requests with it.
    @Test func deadSessionsAreRemovedWithTheirRequests() async throws {
        let changes = Changes()
        let hub = Hub { changes.add($0) }
        _ = await hub.handle(env("UserPromptSubmit", session: "alive", at: 1, socket: "/tmp/alive.sock"))
        _ = await hub.handle(env("UserPromptSubmit", session: "dead", at: 1, socket: "/tmp/dead.sock"))
        // No inbox, no way to tell: such a session is kept.
        _ = await hub.handle(env("UserPromptSubmit", session: "no-inbox", at: 1))
        let task = Task { await hub.handle(env("PermissionRequest", session: "dead", at: 2, extra: ["tool_name": .string("Bash"), "tool_input": .object([:])])) }
        for _ in 0..<200 where await hub.pending.openRequests.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }

        await hub.reap { $0.socket != "/tmp/dead.sock" }

        #expect(await hub.sessions.keys.sorted() == ["alive", "no-inbox"])
        #expect(await hub.inbox.keys.sorted() == ["alive"])
        #expect(await hub.pending.openRequests.isEmpty)
        #expect(await task.value == PendingRequests.emptyReply)
        #expect(changes.removed == ["dead"])
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
