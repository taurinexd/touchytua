import Foundation
import Testing
@testable import TouchyKit

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
}
