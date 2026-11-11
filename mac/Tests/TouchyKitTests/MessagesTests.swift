import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private let session = Session(id: "s1", title: "app", cwd: "/p/app", state: .working,
                              round: Round(startedAt: Date(timeIntervalSince1970: 10)), lastEventAt: Date(timeIntervalSince1970: 10))
private let request = PendingRequest(id: "abcd1234", sessionId: "s1", kind: .permission, toolName: "Bash",
                                     toolInput: ["command": .string("ls")], createdAt: Date(timeIntervalSince1970: 11))

@Suite struct MessagesTests {
    @Test func phoneToMacRoundTrips() throws {
        for m: PhoneToMac in [.hello(deviceName: "iPhone"), .decide(requestId: "abcd1234", allow: true, message: nil),
                              .decide(requestId: "abcd1234", allow: false, message: "no"),
                              .answer(requestId: "abcd1234", answers: ["Quale?": "B"]),
                              .prompt(sessionId: "s1", text: "ciao")] {
            #expect(try roundTrip(m) == m)
        }
    }

    @Test func macToPhoneRoundTrips() throws {
        let usage = Usage(totalCostUSD: 1.5, fiveHourPct: 55, sevenDayPct: 9)
        for m: MacToPhone in [.snapshot(sessions: [session], pending: [request], usage: usage), .snapshot(sessions: [], pending: [], usage: nil),
                              .session(session), .sessionRemoved(id: "s1"), .request(request),
                              .requestResolved(id: "abcd1234", by: .terminal), .usage(usage), .error(code: "unknown_request")] {
            #expect(try roundTrip(m) == m)
        }
    }

    /// Plugin and app update separately: a message type one side does not
    /// know yet must decode (and be ignored), never break the connection.
    @Test func unknownTypesDecodeAsUnknown() throws {
        let fromPhone = try JSONDecoder().decode(PhoneToMac.self, from: Data(#"{"t":"teleport","x":1}"#.utf8))
        #expect(fromPhone == .unknown("teleport"))
        let fromMac = try JSONDecoder().decode(MacToPhone.self, from: Data(#"{"t":"confetti"}"#.utf8))
        #expect(fromMac == .unknown("confetti"))
    }

    @Test func unknownMessageGetsUnsupportedError() async {
        let router = PhoneRouter(hub: Hub()) { _, _ in }
        #expect(await router.handle(.unknown("teleport")) == [.error(code: "unsupported_message")])
    }

    @Test func discriminatorIsT() throws {
        let json = String(decoding: try JSONEncoder().encode(PhoneToMac.prompt(sessionId: "s1", text: "x")), as: UTF8.self)
        #expect(json.contains(#""t":"prompt""#))
    }
}

private final class Injected: @unchecked Sendable {
    var calls: [(String, String)] = []
}

@Suite struct PhoneRouterTests {
    @Test func helloGetsSnapshotWithoutInboxCredentials() async {
        let hub = Hub()
        _ = await hub.handle(HookEnvelope(v: 1, capturedAt: 1, event: ["hook_event_name": .string("SessionStart"), "session_id": .string("s1"), "cwd": .string("/p/app")],
                                          messagingSocket: "/tmp/x.sock", messagingToken: "tok"))
        let router = PhoneRouter(hub: hub) { _, _ in }
        let out = await router.handle(.hello(deviceName: "iPhone"))
        guard case let .snapshot(sessions, pending, _) = out.first else { Issue.record("no snapshot"); return }
        #expect(sessions.map(\.id) == ["s1"])
        #expect(pending.isEmpty)
        // The inbox credentials are not part of what can be sent at all.
        let wire = String(decoding: (try? JSONEncoder().encode(out.first)) ?? Data(), as: UTF8.self)
        #expect(!wire.contains("tok") && !wire.contains("x.sock"))
    }

    @Test func unknownRequestReturnsError() async {
        let router = PhoneRouter(hub: Hub()) { _, _ in }
        #expect(await router.handle(.decide(requestId: "zzzzzzzz", allow: true, message: nil)) == [.error(code: "unknown_request")])
        #expect(await router.handle(.answer(requestId: "zzzzzzzz", answers: [:])) == [.error(code: "unknown_request")])
    }

    @Test func promptInjectsWithPrefix() async {
        let hub = Hub()
        _ = await hub.handle(HookEnvelope(v: 1, capturedAt: 1, event: ["hook_event_name": .string("SessionStart"), "session_id": .string("s1"), "cwd": .string("/p")],
                                          messagingSocket: "/tmp/x.sock", messagingToken: "tok"))
        let log = Injected()
        let router = PhoneRouter(hub: hub) { inbox, text in log.calls.append((inbox.socket, text)) }
        #expect(await router.handle(.prompt(sessionId: "s1", text: "fai i test")).isEmpty)
        #expect(log.calls.count == 1)
        #expect(log.calls.first?.0 == "/tmp/x.sock")
        #expect(log.calls.first?.1 == "[Sent by the user from their phone via touchytua] fai i test")
    }

    @Test func promptToSessionWithoutInboxFails() async {
        let hub = Hub()
        _ = await hub.handle(HookEnvelope(v: 1, capturedAt: 1, event: ["hook_event_name": .string("SessionStart"), "session_id": .string("s1"), "cwd": .string("/p")]))
        let router = PhoneRouter(hub: hub) { _, _ in }
        #expect(await router.handle(.prompt(sessionId: "s1", text: "x")) == [.error(code: "inject_failed")])
    }

    @Test func promptToUnknownSessionFails() async {
        let router = PhoneRouter(hub: Hub()) { _, _ in }
        #expect(await router.handle(.prompt(sessionId: "nope", text: "x")) == [.error(code: "unknown_session")])
    }

    @Test func injectFailureReported() async {
        let hub = Hub()
        _ = await hub.handle(HookEnvelope(v: 1, capturedAt: 1, event: ["hook_event_name": .string("SessionStart"), "session_id": .string("s1"), "cwd": .string("/p")]))
        struct Boom: Error {}
        let router = PhoneRouter(hub: hub) { _, _ in throw Boom() }
        #expect(await router.handle(.prompt(sessionId: "s1", text: "x")) == [.error(code: "inject_failed")])
    }
}
