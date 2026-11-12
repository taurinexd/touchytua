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
    /// Only what changes on the phone is sent: a tool call once, for the
    /// line that says what the session is doing, and not again when it ends
    /// or repeats.
    @Test func eventsThatChangeNothingVisibleAreNotEmitted() async {
        let changes = Changes()
        let hub = Hub { changes.add($0) }
        _ = await hub.handle(env("UserPromptSubmit", at: 1))
        #expect(changes.sessionUpdates == 1)
        _ = await hub.handle(env("PreToolUse", at: 2, extra: ["tool_name": .string("Bash")]))
        #expect(changes.sessionUpdates == 2)
        _ = await hub.handle(env("PostToolUse", at: 3, extra: ["tool_name": .string("Bash")]))
        _ = await hub.handle(env("PreToolUse", at: 4, extra: ["tool_name": .string("Bash")]))
        _ = await hub.handle(env("PostToolUse", at: 5, extra: ["tool_name": .string("Bash")]))
        #expect(changes.sessionUpdates == 2)
        _ = await hub.handle(env("Stop", at: 6))
        #expect(changes.sessionUpdates == 3)
    }
}

@Suite struct HubNameTests {
    private func transcript(_ lines: String...) throws -> String {
        let path = NSTemporaryDirectory() + "tt-name-" + UUID().uuidString + ".jsonl"
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// A session started with a name is called by it from its first
    /// prompt: several of them waiting for approval must be told apart.
    @Test func aNamedSessionIsCalledByItsNameFromTheFirstPrompt() async throws {
        let path = try transcript(#"{"type":"custom-title","customTitle":"release-notes","sessionId":"s1"}"#)
        let hub = Hub()
        _ = await hub.handle(env("UserPromptSubmit", at: 1, extra: [
            "prompt": .string("Write the release notes"), "transcript_path": .string(path)]))
        let session = await hub.sessions["s1"]
        #expect(session?.title == "release-notes")
        #expect(session?.round?.prompt == "Write the release notes")
    }

    @Test func aSessionWithoutANameIsCalledByItsFirstPrompt() async throws {
        let path = try transcript(#"{"type":"mode","sessionId":"s1"}"#)
        let hub = Hub()
        _ = await hub.handle(env("UserPromptSubmit", at: 1, extra: [
            "prompt": .string("Write the release notes"), "transcript_path": .string(path)]))
        #expect(await hub.sessions["s1"]?.title == "Write the release notes")
    }

    /// The name wins over the title Claude makes up.
    @Test func theGivenNameWinsWhenTheRoundEnds() async throws {
        let path = try transcript(
            #"{"type":"custom-title","customTitle":"release-notes","sessionId":"s1"}"#,
            #"{"type":"ai-title","aiTitle":"Cart release notes","sessionId":"s1"}"#)
        let hub = Hub()
        _ = await hub.handle(env("UserPromptSubmit", at: 1, extra: ["prompt": .string("Write them")]))
        _ = await hub.handle(env("Stop", at: 2, extra: ["transcript_path": .string(path)]))
        #expect(await hub.sessions["s1"]?.title == "release-notes")
    }
}

@Suite struct HubResumeTests {
    private func ask(_ hub: Hub, file: String, at: Double) -> Task<Data, Never> {
        Task {
            await hub.handle(env("PermissionRequest", at: at, extra: [
                "tool_name": .string("Read"), "tool_input": .object(["file_path": .string(file)])]))
        }
    }

    private func open(_ hub: Hub, _ count: Int) async -> [PendingRequest] {
        for _ in 0..<400 where await hub.pending.openRequests.count != count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await hub.pending.openRequests
    }

    /// No hook fires between an approval and the end of the tool it
    /// allowed: without this a long command would look like a pause.
    @Test func approvingFromThePhonePutsTheSessionBackToWork() async {
        let hub = Hub()
        _ = await hub.handle(env("UserPromptSubmit", at: 1))
        let hook = ask(hub, file: "/a", at: 2)
        let request = await open(hub, 1)[0]
        #expect(await hub.sessions["s1"]?.state == .waiting)

        #expect(await hub.decide(requestId: request.id, allow: true, message: nil))

        #expect(await hub.sessions["s1"]?.state == .working)
        _ = await hook.value
    }

    @Test func theSessionWaitsUntilItsLastRequestIsAnswered() async {
        let hub = Hub()
        _ = await hub.handle(env("UserPromptSubmit", at: 1))
        let first = ask(hub, file: "/a", at: 2)
        _ = await open(hub, 1)
        let second = ask(hub, file: "/b", at: 3)
        let requests = await open(hub, 2)

        #expect(await hub.decide(requestId: requests[0].id, allow: true, message: nil))
        #expect(await hub.sessions["s1"]?.state == .waiting)
        #expect(await hub.decide(requestId: requests[1].id, allow: false, message: nil))
        #expect(await hub.sessions["s1"]?.state == .working)
        _ = await first.value
        _ = await second.value
    }
}

@Suite struct HubActivityTests {
    private func tool(_ event: String, _ name: String, at: Double, input: [String: JSONValue] = [:],
                      response: JSONValue? = nil, transcript: String? = nil) -> HookEnvelope {
        var extra: [String: JSONValue] = ["tool_name": .string(name), "tool_input": .object(input)]
        if let response { extra["tool_response"] = response }
        if let transcript { extra["transcript_path"] = .string(transcript) }
        return env(event, at: at, extra: extra)
    }

    @Test func aToolCallNamesWhatTheSessionIsDoing() async {
        let hub = Hub()
        _ = await hub.handle(env("UserPromptSubmit", at: 1))
        #expect(await hub.sessions["s1"]?.round?.activity == nil)
        _ = await hub.handle(tool("PreToolUse", "Read", at: 2, input: ["file_path": .string("/p/app/Cart.swift")]))
        #expect(await hub.sessions["s1"]?.round?.activity == "Reading Cart.swift")
    }

    @Test func theTaskInProgressNamesTheWorkWhateverTheTool() async {
        let hub = Hub()
        _ = await hub.handle(env("UserPromptSubmit", at: 1))
        _ = await hub.handle(tool("PostToolUse", "TaskCreate", at: 2, input: ["subject": .string("Draft"), "activeForm": .string("Writing the draft")],
                                  response: .object(["task": .object(["id": .string("4")])])))
        _ = await hub.handle(tool("PostToolUse", "TaskUpdate", at: 3, input: ["taskId": .string("4"), "status": .string("in_progress")]))
        #expect(await hub.sessions["s1"]?.round?.activity == "Writing the draft")
        _ = await hub.handle(tool("PreToolUse", "Read", at: 4, input: ["file_path": .string("/p/app/Cart.swift")]))
        #expect(await hub.sessions["s1"]?.round?.activity == "Writing the draft")
    }

    @Test func aFinishedTaskStopsNamingTheWork() async {
        let hub = Hub()
        _ = await hub.handle(env("UserPromptSubmit", at: 1))
        _ = await hub.handle(tool("PostToolUse", "TaskUpdate", at: 2, input: [
            "taskId": .string("4"), "status": .string("in_progress"), "activeForm": .string("Writing the draft")]))
        _ = await hub.handle(tool("PostToolUse", "TaskUpdate", at: 3, input: ["taskId": .string("4"), "status": .string("completed")]))
        #expect(await hub.sessions["s1"]?.round?.activity == nil)
        _ = await hub.handle(tool("PreToolUse", "Bash", at: 4, input: ["description": .string("Run the tests")]))
        #expect(await hub.sessions["s1"]?.round?.activity == "Run the tests")
    }

    @Test func theActivityEndsWithTheRound() async {
        let hub = Hub()
        _ = await hub.handle(env("UserPromptSubmit", at: 1))
        _ = await hub.handle(tool("PreToolUse", "Bash", at: 2, input: ["description": .string("Run the tests")]))
        _ = await hub.handle(env("Stop", at: 3))
        #expect(await hub.sessions["s1"]?.round?.activity == nil)
    }

    private func line(_ id: String, _ stamp: String, tokens: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"\#(id)","content":[],"usage":{"output_tokens":\#(tokens)}}}"# + "\n"
    }

    /// Reading the transcript at every tool call would be wasteful: the
    /// count moves at most every five seconds.
    @Test func tokensAreCountedWhileTheRoundRuns() async throws {
        let path = NSTemporaryDirectory() + "tt-live-" + UUID().uuidString + ".jsonl"
        try Data(line("msg_1", "2026-11-11T16:14:00.000Z", tokens: 120).utf8).write(to: URL(fileURLWithPath: path))
        let hub = Hub()
        let start = ISO8601DateFormatter().date(from: "2026-11-11T16:13:56Z")!.timeIntervalSince1970
        _ = await hub.handle(env("UserPromptSubmit", at: start))
        _ = await hub.handle(tool("PostToolUse", "Bash", at: start + 6, transcript: path))
        #expect(await hub.sessions["s1"]?.round?.tokens == 120)

        let handle = try #require(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(line("msg_2", "2026-11-11T16:14:05.000Z", tokens: 80).utf8))
        try handle.close()
        _ = await hub.handle(tool("PostToolUse", "Bash", at: start + 8, transcript: path))
        #expect(await hub.sessions["s1"]?.round?.tokens == 120)
        _ = await hub.handle(tool("PostToolUse", "Bash", at: start + 12, transcript: path))
        #expect(await hub.sessions["s1"]?.round?.tokens == 200)
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
