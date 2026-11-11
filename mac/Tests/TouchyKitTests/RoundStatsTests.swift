import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

@Suite struct RoundStatsTests {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/round.jsonl").path

    @Test func sumsOutputTokensSinceRoundStart() {
        let since = ISO8601DateFormatter().date(from: "2026-11-06T10:05:00Z")!
        #expect(RoundStats.outputTokens(transcriptPath: fixture, since: since) == 1700)
    }

    @Test func missingFileReturnsNil() {
        #expect(RoundStats.outputTokens(transcriptPath: "/nonexistent/x.jsonl", since: .distantPast) == nil)
    }

    private func line(_ type: String, _ stamp: String, tokens: Int = 0, pad: Int = 0) -> String {
        #"{"type":"\#(type)","timestamp":"\#(stamp)","message":{"role":"x","content":"\#(String(repeating: "p", count: pad))","usage":{"output_tokens":\#(tokens)}}}"#
    }

    private func write(_ lines: [String]) -> String {
        let path = NSTemporaryDirectory() + "tt-round-" + UUID().uuidString + ".jsonl"
        try! Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Claude Code writes one line per content block, and each repeats the
    /// usage of the whole message.
    @Test func aMessageWrittenAsSeveralLinesCountsOnce() {
        func block(_ kind: String) -> String {
            #"{"type":"assistant","timestamp":"2026-11-11T16:19:40.000Z","message":{"id":"msg_1","content":[{"type":"\#(kind)"}],"usage":{"output_tokens":872}}}"#
        }
        let next = #"{"type":"assistant","timestamp":"2026-11-11T16:19:50.000Z","message":{"id":"msg_2","content":[],"usage":{"output_tokens":30}}}"#
        let path = write([block("thinking"), block("text"), next])
        #expect(RoundStats.outputTokens(transcriptPath: path, since: .distantPast) == 902)
    }

    /// Transcripts reach hundreds of MB: only the end of the file is read,
    /// growing the window until it reaches a line older than the round.
    @Test func windowGrowsUntilItCoversTheRound() {
        let since = ISO8601DateFormatter().date(from: "2026-11-06T10:05:00Z")!
        let path = write([
            line("assistant", "2026-11-06T09:00:00.000Z", tokens: 9000, pad: 4000),
            line("assistant", "2026-11-06T10:05:01.000Z", tokens: 100, pad: 3000),
            line("assistant", "2026-11-06T10:05:02.000Z", tokens: 20, pad: 3000),
            line("assistant", "2026-11-06T10:05:03.000Z", tokens: 3, pad: 10),
        ])
        var reads = 0
        #expect(RoundStats.outputTokens(transcriptPath: path, since: since, window: 256) { reads = $0 } == 123)
        #expect(reads > 1)
    }

    @Test func stopsAtTheFirstLineOlderThanTheRound() {
        let since = ISO8601DateFormatter().date(from: "2026-11-06T10:05:00Z")!
        var lines = (0..<200).map { _ in line("assistant", "2026-11-06T09:00:00.000Z", tokens: 9000, pad: 2000) }
        lines.append(line("assistant", "2026-11-06T10:05:03.000Z", tokens: 7))
        var reads = 0
        #expect(RoundStats.outputTokens(transcriptPath: write(lines), since: since, window: 8192) { reads = $0 } == 7)
        #expect(reads == 1)
    }
}
