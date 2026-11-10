import Foundation
import Testing
@testable import TouchyKit

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PendingRequests.Event] = []
    func append(_ e: PendingRequests.Event) { lock.lock(); items.append(e); lock.unlock() }
    var all: [PendingRequests.Event] { lock.lock(); defer { lock.unlock() }; return items }
}

private func request(_ id: String, session: String = "s1", tool: String = "Bash",
                     input: [String: JSONValue] = ["command": .string("ls")]) -> PendingRequest {
    PendingRequest(id: id, sessionId: session, kind: .permission, toolName: tool,
                   toolInput: input, createdAt: Date(timeIntervalSince1970: 0))
}

private func waitUntilOpen(_ pending: PendingRequests, _ id: String) async {
    for _ in 0..<200 {
        if await pending.openRequests.contains(where: { $0.id == id }) { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@Suite struct PendingRequestsTests {
    @Test func resolveDeliversReply() async {
        let log = EventLog()
        let pending = PendingRequests { log.append($0) }
        let task = Task { await pending.open(request("abcd1234")) }
        await waitUntilOpen(pending, "abcd1234")
        let ok = await pending.resolve(id: "abcd1234", reply: Data("R\n".utf8))
        #expect(ok)
        #expect(await task.value == Data("R\n".utf8))
        #expect(log.all.contains(.resolved(id: "abcd1234", by: .phone)))
        #expect(await pending.openRequests.isEmpty)
    }

    @Test func lateResolveIgnored() async {
        let pending = PendingRequests { _ in }
        let task = Task { await pending.open(request("abcd1234")) }
        await waitUntilOpen(pending, "abcd1234")
        await pending.close(ids: ["abcd1234"], by: .terminal)
        _ = await task.value
        #expect(await pending.resolve(id: "abcd1234", reply: Data("R\n".utf8)) == false)
    }

    @Test func cancelReturnsEmptyReply() async {
        let log = EventLog()
        let pending = PendingRequests { log.append($0) }
        let task = Task { await pending.open(request("abcd1234")) }
        await waitUntilOpen(pending, "abcd1234")
        await pending.cancelAll(sessionId: "s1", by: .terminal)
        #expect(await task.value == Data("{}\n".utf8))
        #expect(log.all.contains(.resolved(id: "abcd1234", by: .terminal)))
    }

    @Test func idsAreEightLowercaseAlphanumerics() {
        let id = PendingRequest.makeId()
        #expect(id.count == 8)
        #expect(id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    }
}

@Suite struct PendingPolicyTests {
    private func env(_ name: String, session: String = "s1", tool: String? = nil,
                     input: [String: JSONValue]? = nil) -> HookEnvelope {
        var e: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string(session)]
        if let tool { e["tool_name"] = .string(tool) }
        if let input { e["tool_input"] = .object(input) }
        return HookEnvelope(v: 1, capturedAt: 0, event: e)
    }
    let open = [request("aaaaaaaa"), request("bbbbbbbb", tool: "Write", input: ["file_path": .string("/x")]),
                request("cccccccc", session: "s2")]

    @Test func postToolUseClosesMatchingCallOnly() {
        let ids = PendingPolicy.requestsToClose(after: env("PostToolUse", tool: "Bash", input: ["command": .string("ls")]), open: open)
        #expect(ids == ["aaaaaaaa"])
    }

    @Test func parallelSiblingDoesNotClose() {
        let ids = PendingPolicy.requestsToClose(after: env("PostToolUse", tool: "Read", input: ["file_path": .string("/y")]), open: open)
        #expect(ids.isEmpty)
    }

    @Test func stopClosesAllOfSession() {
        let ids = PendingPolicy.requestsToClose(after: env("Stop"), open: open)
        #expect(Set(ids) == ["aaaaaaaa", "bbbbbbbb"])
    }

    @Test func newPermissionClosesOlderOfSession() {
        let ids = PendingPolicy.requestsToClose(after: env("PermissionRequest", tool: "Bash"), open: open)
        #expect(Set(ids) == ["aaaaaaaa", "bbbbbbbb"])
    }

    @Test func preToolUseClosesNothing() {
        #expect(PendingPolicy.requestsToClose(after: env("PreToolUse", tool: "Bash", input: ["command": .string("ls")]), open: open).isEmpty)
    }
}
