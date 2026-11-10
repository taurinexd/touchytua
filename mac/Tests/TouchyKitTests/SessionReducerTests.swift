import Foundation
import Testing
@testable import TouchyKit

private func envelope(
    _ name: String, session: String = "s1", at: Double, extra: [String: JSONValue] = [:],
    socket: String? = nil, token: String? = nil
) -> HookEnvelope {
    var event: [String: JSONValue] = [
        "hook_event_name": .string(name),
        "session_id": .string(session),
        "cwd": .string("/p/app"),
    ]
    for (k, v) in extra { event[k] = v }
    return HookEnvelope(v: 1, capturedAt: at, event: event, messagingSocket: socket, messagingToken: token)
}

@Suite struct SessionReducerTests {
    @Test func sessionStartCreatesReady() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("SessionStart", at: 100, socket: "/tmp/cc-socks/1.sock", token: "tok"), to: &sessions)
        let s = sessions["s1"]
        #expect(s?.state == .ready)
        #expect(s?.title == "app")
        #expect(s?.inboxSocket == "/tmp/cc-socks/1.sock")
        #expect(s?.inboxToken == "tok")
    }

    @Test func promptStartsRound() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("SessionStart", at: 100), to: &sessions)
        SessionReducer.apply(envelope("UserPromptSubmit", at: 110), to: &sessions)
        #expect(sessions["s1"]?.state == .working)
        #expect(sessions["s1"]?.round?.startedAt == Date(timeIntervalSince1970: 110))
        #expect(sessions["s1"]?.round?.endedAt == nil)
    }

    @Test func permissionRequestWaits() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("UserPromptSubmit", at: 110), to: &sessions)
        SessionReducer.apply(envelope("PermissionRequest", at: 120), to: &sessions)
        #expect(sessions["s1"]?.state == .waiting)
    }

    @Test func stopEndsRound() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("UserPromptSubmit", at: 110), to: &sessions)
        SessionReducer.apply(envelope("Stop", at: 130, extra: ["last_assistant_message": .string("Fatto")]), to: &sessions)
        #expect(sessions["s1"]?.state == .done)
        #expect(sessions["s1"]?.round?.summary == "Fatto")
        #expect(sessions["s1"]?.round?.endedAt == Date(timeIntervalSince1970: 130))
    }

    @Test func stopFailureErrors() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("UserPromptSubmit", at: 110), to: &sessions)
        SessionReducer.apply(envelope("StopFailure", at: 130), to: &sessions)
        #expect(sessions["s1"]?.state == .error)
    }

    @Test func postToolUseClearsWaiting() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("PermissionRequest", at: 120), to: &sessions)
        SessionReducer.apply(envelope("PostToolUse", at: 125), to: &sessions)
        #expect(sessions["s1"]?.state == .working)
    }

    @Test func staleEventIgnored() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("Stop", at: 200), to: &sessions)
        SessionReducer.apply(envelope("UserPromptSubmit", at: 150), to: &sessions)
        #expect(sessions["s1"]?.state == .done)
    }

    @Test func sessionEndRemoves() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("SessionStart", at: 100), to: &sessions)
        SessionReducer.apply(envelope("SessionEnd", at: 300), to: &sessions)
        #expect(sessions["s1"] == nil)
    }

    @Test func notificationNeedsInputWaits() {
        for type in ["permission_prompt", "elicitation_dialog", "agent_needs_input"] {
            var sessions: [String: Session] = [:]
            SessionReducer.apply(envelope("UserPromptSubmit", at: 110), to: &sessions)
            SessionReducer.apply(envelope("Notification", at: 120, extra: ["notification_type": .string(type)]), to: &sessions)
            #expect(sessions["s1"]?.state == .waiting, "type \(type)")
        }
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("UserPromptSubmit", at: 110), to: &sessions)
        SessionReducer.apply(envelope("Notification", at: 120, extra: ["notification_type": .string("idle_prompt")]), to: &sessions)
        #expect(sessions["s1"]?.state == .working)
    }

    @Test func unknownEventIgnored() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("touchytua_usage", at: 100), to: &sessions)
        #expect(sessions.isEmpty)
    }

    @Test func envelopeDecodesFromHookJSON() throws {
        let json = #"{"v":1,"capturedAt":100.5,"event":{"hook_event_name":"Stop","session_id":"s1","n":3,"ok":true,"x":null,"arr":[1,"a"]}}"#
        let env = try JSONDecoder().decode(HookEnvelope.self, from: Data(json.utf8))
        #expect(env.event["hook_event_name"] == .string("Stop"))
        #expect(env.event["n"] == .number(3))
        #expect(env.event["ok"] == .bool(true))
        #expect(env.event["x"] == .null)
        #expect(env.event["arr"] == .array([.number(1), .string("a")]))
        #expect(env.messagingSocket == nil)
    }
}
