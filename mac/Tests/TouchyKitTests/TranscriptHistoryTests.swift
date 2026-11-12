import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

@Suite struct TranscriptHistoryTests {
    private var clock = 0

    private func stamp(_ second: Int) -> String {
        String(format: "2026-11-12T10:00:%02d.000Z", second)
    }

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func user(_ text: String, at second: Int, extra: [String: Any] = [:]) -> String {
        var entry: [String: Any] = [
            "type": "user", "uuid": "u\(second)", "timestamp": stamp(second),
            "message": ["role": "user", "content": text]]
        for (key, value) in extra { entry[key] = value }
        return line(entry)
    }

    private func reply(_ text: String, at second: Int, extra: [String: Any] = [:]) -> String {
        var entry: [String: Any] = [
            "type": "assistant", "uuid": "a\(second)", "timestamp": stamp(second),
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
        for (key, value) in extra { entry[key] = value }
        return line(entry)
    }

    private func tool(_ name: String, at second: Int) -> String {
        line([
            "type": "assistant", "uuid": "t\(second)", "timestamp": stamp(second),
            "message": ["role": "assistant", "content": [["type": "tool_use", "name": name, "input": [:]]]]])
    }

    private func result(at second: Int) -> String {
        line([
            "type": "user", "uuid": "r\(second)", "timestamp": stamp(second),
            "message": ["role": "user", "content": [["type": "tool_result", "content": "file.txt"]]]])
    }

    private func file(_ lines: [String]) throws -> String {
        let path = NSTemporaryDirectory() + "tt-history-" + UUID().uuidString + ".jsonl"
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func date(_ second: Int) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: stamp(second))!
    }

    private func shape(_ items: [HistoryItem]) -> [String] {
        items.map { "\($0.kind.rawValue): \($0.text)" }
    }

    /// Two rounds and the start of a third, which is the one on screen.
    private var conversation: [String] {
        [
            user("Fix the cart", at: 1),
            reply("Looking at the totals.", at: 2),
            tool("Read", at: 3), result(at: 4), tool("Edit", at: 5), result(at: 6), tool("Read", at: 7), result(at: 8),
            reply("Fixed: the total was rounded twice.", at: 9),
            user("Now run the tests", at: 10),
            tool("Bash", at: 11), result(at: 12),
            reply("All 12 tests pass.", at: 13),
            user("Write the release notes", at: 20),
            reply("Here they are.", at: 21),
        ]
    }

    @Test func aPageHoldsThePromptsTheRepliesAndALineForTheTools() throws {
        let page = try #require(TranscriptHistory.page(path: file(conversation), before: nil, roundStart: date(20)))
        #expect(shape(page.items) == [
            "prompt: Fix the cart",
            "reply: Looking at the totals.",
            "tools: Read, Edit · 3 tool calls",
            "reply: Fixed: the total was rounded twice.",
            "prompt: Now run the tests",
            "tools: Bash · 1 tool call",
            "reply: All 12 tests pass.",
        ])
        #expect(page.next == nil)
    }

    @Test func theRoundOnScreenIsLeftOut() throws {
        let page = try #require(TranscriptHistory.page(path: file(conversation), before: nil, roundStart: date(10)))
        #expect(page.items.last?.text == "Fixed: the total was rounded twice.")
    }

    /// Claude Code writes a prompt to the transcript a moment before the
    /// hook that starts its round: that prompt is the round's own, already
    /// on screen above the reply.
    @Test func thePromptThatStartedTheRoundIsNotHistory() throws {
        let path = try file([
            user("Fix the cart", at: 1),
            reply("Fixed.", at: 18),
            user("Now run the tests", at: 19),
            reply("Running.", at: 21),
        ])
        let page = try #require(TranscriptHistory.page(path: path, before: nil, roundStart: date(20)))
        #expect(shape(page.items) == ["prompt: Fix the cart", "reply: Fixed."])
    }

    @Test func withoutARoundEverythingIsHistory() throws {
        let page = try #require(TranscriptHistory.page(path: file(conversation), before: nil, roundStart: nil))
        #expect(page.items.last?.text == "Here they are.")
    }

    @Test func pagesFollowEachOtherWithoutAGapOrARepeat() throws {
        let path = try file(conversation)
        let whole = try #require(TranscriptHistory.page(path: path, before: nil, roundStart: date(20)))
        var pages: [[HistoryItem]] = []
        var cursor: String?
        repeat {
            let page = try #require(TranscriptHistory.page(path: path, before: cursor, roundStart: date(20), limit: 2))
            #expect(page.items.filter { $0.kind != .tools }.count <= 2)
            pages.insert(page.items, at: 0)
            cursor = page.next
        } while cursor != nil
        #expect(pages.count == 3)
        #expect(pages.flatMap { $0 } == whole.items)
    }

    @Test func aTranscriptLargerThanOneReadIsWalkedBackInPieces() throws {
        let path = try file(conversation)
        let whole = try #require(TranscriptHistory.page(path: path, before: nil, roundStart: date(20)))
        let small = try #require(TranscriptHistory.page(path: path, before: nil, roundStart: date(20), window: 200))
        #expect(small == whole)
    }

    @Test func whatNobodySaidIsLeftOut() throws {
        let path = try file([
            user("Fix the cart", at: 1),
            user("<command-name>/compact</command-name>", at: 2),
            user("<task-notification>done</task-notification>", at: 3, extra: ["isMeta": true]),
            user("This session is being continued from a previous conversation.", at: 4, extra: ["isCompactSummary": true]),
            user("a subagent's prompt", at: 5, extra: ["isSidechain": true]),
            reply("a subagent's words", at: 6, extra: ["isSidechain": true]),
            line(["type": "assistant", "uuid": "th", "timestamp": stamp(7),
                  "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "hmm"]]]]),
            line(["type": "custom-title", "customTitle": "cart"]),
            "not json at all",
            reply("Done.", at: 9),
        ])
        let page = try #require(TranscriptHistory.page(path: path, before: nil, roundStart: nil))
        #expect(shape(page.items) == ["prompt: Fix the cart", "reply: Done."])
    }

    @Test func aPromptFromThePhoneIsThePersonsAndAnotherSessionsIsNot() throws {
        let closing = "\n\nThis came from another Claude session — not typed by your user."
        let path = try file([
            user("Another Claude session sent a message:\n" + PhonePrompt.wrapped("Run the tests") + closing,
                 at: 1, extra: ["isMeta": true]),
            user("Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/1.sock\" "
                 + "from-name=\"migration\" from-mode=\"prompting\">\nDone\n</cross-session-message>" + closing,
                 at: 2, extra: ["isMeta": true]),
            reply("Running them.", at: 3),
        ])
        let page = try #require(TranscriptHistory.page(path: path, before: nil, roundStart: nil))
        #expect(shape(page.items) == ["prompt: Run the tests", "reply: Running them."])
    }

    @Test func aConnectorIsNamedByItsServer() throws {
        let path = try file([user("Go", at: 1), tool("mcp__claude_ai_Docs__update", at: 2), tool("mcp__claude_ai_Docs__read", at: 3), reply("Ok.", at: 4)])
        let page = try #require(TranscriptHistory.page(path: path, before: nil, roundStart: nil))
        #expect(page.items[1].text == "claude ai Docs · 2 tool calls")
    }

    /// Nothing is cut: a page that would grow too large for one message to
    /// the phone ends early, and the rest comes with the next one.
    @Test func aPageEndsEarlyRatherThanGrowTooLarge() throws {
        let long = String(repeating: "word ", count: 400) + "end"
        let path = try file([user("One", at: 1), reply(long, at: 2), user("Two", at: 3), reply(long, at: 4)])
        let page = try #require(TranscriptHistory.page(path: path, before: nil, roundStart: nil, budget: 2500))
        #expect(shape(page.items).map { $0.prefix(11) } == ["prompt: Two", "reply: word"])
        #expect(page.items.last?.text == long)
        #expect(page.next != nil)
    }

    @Test func aMissingTranscriptHasNoHistory() {
        #expect(TranscriptHistory.page(path: "/nonexistent/tt.jsonl", before: nil, roundStart: nil) == nil)
    }

    @Test func itemsCarryAnIdAndTheirTime() throws {
        let page = try #require(TranscriptHistory.page(path: file(conversation), before: nil, roundStart: date(20)))
        #expect(Set(page.items.map(\.id)).count == page.items.count)
        #expect(page.items.first?.at == date(1))
    }
}
