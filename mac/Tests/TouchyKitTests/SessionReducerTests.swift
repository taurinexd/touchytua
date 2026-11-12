import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

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
    }

    /// Until the first round ends there is no transcript title: without this
    /// two sessions in one folder look the same while they wait for approval.
    @Test func theFirstPromptNamesAnUntitledSession() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("SessionStart", at: 100), to: &sessions)
        SessionReducer.apply(envelope("UserPromptSubmit", at: 101, extra: [
            "prompt": .string("  Fix the cart total\n\nIt is off by one cent."),
        ]), to: &sessions)
        #expect(sessions["s1"]?.title == "Fix the cart total")
    }

    @Test func aLaterPromptDoesNotRenameTheSession() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("UserPromptSubmit", at: 101, extra: ["prompt": .string("Fix the cart")]), to: &sessions)
        SessionReducer.apply(envelope("UserPromptSubmit", at: 102, extra: ["prompt": .string("now the tests")]), to: &sessions)
        #expect(sessions["s1"]?.title == "Fix the cart")
    }

    @Test func aPromptFromThePhoneIsNamedWithoutItsPrefix() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("UserPromptSubmit", at: 101, extra: [
            "prompt": .string(PhoneRouter.promptPrefix + "Run the tests"),
        ]), to: &sessions)
        #expect(sessions["s1"]?.title == "Run the tests")
    }

    @Test func aReplyQuotingAPhonePromptLosesThePrefix() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("UserPromptSubmit", at: 101), to: &sessions)
        SessionReducer.apply(envelope("Stop", at: 130, extra: [
            "last_assistant_message": .string("You asked: \"" + PhoneRouter.promptPrefix + "Run the tests\". Done."),
        ]), to: &sessions)
        #expect(sessions["s1"]?.round?.summary == "You asked: \"Run the tests\". Done.")
    }

    @Test func aLongPromptIsCutForTheTitle() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("UserPromptSubmit", at: 101, extra: [
            "prompt": .string(String(repeating: "word ", count: 100)),
        ]), to: &sessions)
        let title = sessions["s1"]?.title ?? ""
        #expect(title.count <= 120)
        #expect(title.hasSuffix("word…"))
    }

    @Test func aPromptThatFitsIsNotMarkedAsCut() {
        var sessions: [String: Session] = [:]
        let prompt = String(repeating: "a", count: 120)
        SessionReducer.apply(envelope("UserPromptSubmit", at: 101, extra: ["prompt": .string(prompt)]), to: &sessions)
        #expect(sessions["s1"]?.title == prompt)
    }

    @Test func aLongWordIsCutWhereItMust() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("UserPromptSubmit", at: 101, extra: [
            "prompt": .string(String(repeating: "a", count: 300)),
        ]), to: &sessions)
        #expect(sessions["s1"]?.title == String(repeating: "a", count: 119) + "…")
    }

    @Test func anEmptyPromptKeepsTheFolderName() {
        var sessions: [String: Session] = [:]
        SessionReducer.apply(envelope("UserPromptSubmit", at: 101, extra: ["prompt": .string("  \n ")]), to: &sessions)
        SessionReducer.apply(envelope("UserPromptSubmit", at: 102), to: &sessions)
        #expect(sessions["s1"]?.title == "app")
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

    /// A daemon restarted mid-session never sees SessionStart again: the
    /// credentials must be picked up from whatever event comes next.
    @Test func inboxCredentialsFromLaterEventAreStored() async {
        let hub = Hub()
        _ = await hub.handle(envelope("UserPromptSubmit", at: 100, socket: "/tmp/cc-socks/9.sock", token: "tok9"))
        #expect(await hub.inbox["s1"] == InboxCredentials(socket: "/tmp/cc-socks/9.sock", token: "tok9"))
        _ = await hub.handle(envelope("SessionEnd", at: 101))
        #expect(await hub.inbox["s1"] == nil)
    }
}
