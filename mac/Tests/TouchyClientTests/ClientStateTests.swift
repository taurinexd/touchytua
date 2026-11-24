import Foundation
import Testing
@testable import TouchyClient
import TouchyProtocol

private func session(_ id: String, _ state: SessionState, at: Double) -> Session {
    Session(id: id, title: id, cwd: "/p/\(id)", state: state, lastEventAt: Date(timeIntervalSince1970: at))
}

private func request(_ id: String, session: String) -> PendingRequest {
    PendingRequest(id: id, sessionId: session, kind: .permission, toolName: "Bash", toolInput: [:],
                   createdAt: Date(timeIntervalSince1970: 1))
}

@Suite struct ClientStateTests {
    @Test func snapshotReplacesEverything() {
        var state = ClientState()
        state.apply(.session(session("old", .working, at: 1)))
        state.apply(.snapshot(sessions: [session("a", .done, at: 5)], pending: [request("r1", session: "a")],
                              usage: Usage(totalCostUSD: 2)))
        #expect(state.sessions.map(\.id) == ["a"])
        #expect(state.pending.map(\.id) == ["r1"])
        #expect(state.usage?.totalCostUSD == 2)
    }

    /// What needs the user comes first, then what is running, then the
    /// rest; within each, the most recent on top.
    @Test func waitingSessionsFirstThenWorkingThenTheRest() {
        var state = ClientState()
        state.apply(.session(session("old-working", .working, at: 1)))
        state.apply(.session(session("new-done", .done, at: 9)))
        state.apply(.session(session("old-done", .done, at: 2)))
        state.apply(.session(session("waiting", .waiting, at: 3)))
        state.apply(.session(session("new-working", .working, at: 4)))
        state.apply(.session(session("failed", .error, at: 5)))
        #expect(state.sessions.map(\.id) == ["waiting", "new-working", "old-working", "new-done", "failed", "old-done"])
    }

    /// A running session says something new at every tool call: its place
    /// among the running ones goes by when its round began, or the rows
    /// would keep changing places.
    @Test func workingSessionsKeepTheirPlacesWhileTheyWork() {
        var state = ClientState()
        var first = session("first", .working, at: 10)
        first.round = Round(startedAt: Date(timeIntervalSince1970: 10))
        var second = session("second", .working, at: 20)
        second.round = Round(startedAt: Date(timeIntervalSince1970: 20))
        state.apply(.session(first))
        state.apply(.session(second))
        #expect(state.sessions.map(\.id) == ["second", "first"])

        first.lastEventAt = Date(timeIntervalSince1970: 30)
        state.apply(.session(first))
        #expect(state.sessions.map(\.id) == ["second", "first"])
    }

    @Test func sessionUpdateReplacesInPlace() {
        var state = ClientState()
        state.apply(.session(session("a", .working, at: 1)))
        state.apply(.session(session("a", .done, at: 2)))
        #expect(state.sessions.count == 1)
        #expect(state.sessions.first?.state == .done)
    }

    @Test func requestsOpenAndResolve() {
        var state = ClientState()
        state.apply(.request(request("r1", session: "a")))
        state.apply(.request(request("r1", session: "a")))
        state.apply(.request(request("r2", session: "b")))
        #expect(state.requests(for: "a").map(\.id) == ["r1"])
        state.apply(.requestResolved(id: "r1", by: .terminal))
        #expect(state.pending.map(\.id) == ["r2"])
    }

    @Test func removingASessionDropsItsRequests() {
        var state = ClientState()
        state.apply(.session(session("a", .waiting, at: 1)))
        state.apply(.request(request("r1", session: "a")))
        state.apply(.sessionRemoved(id: "a"))
        #expect(state.sessions.isEmpty && state.pending.isEmpty)
    }

    @Test func unknownAndErrorChangeNothing() {
        var state = ClientState()
        state.apply(.session(session("a", .working, at: 1)))
        let before = state
        state.apply(.unknown("confetti"))
        state.apply(.error(code: "unknown_request"))
        #expect(state == before)
    }

    @Test func countsByState() {
        var state = ClientState()
        state.apply(.snapshot(sessions: [
            session("a", .working, at: 1), session("b", .working, at: 2), session("c", .waiting, at: 3),
            session("d", .done, at: 4), session("e", .ready, at: 5), session("f", .error, at: 6),
        ], pending: [], usage: nil))
        #expect(state.counts == ClientState.Counts(working: 2, waiting: 1, done: 2, failed: 1))
    }
}
