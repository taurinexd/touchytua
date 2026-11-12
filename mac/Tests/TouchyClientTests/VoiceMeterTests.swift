import Testing
@testable import TouchyClient

@Suite struct VoiceMeterTests {
    private func feed(_ meter: inout VoiceMeter, _ decibels: Float, times: Int) -> Float {
        var level: Float = 0
        for _ in 0..<times { level = meter.level(decibels: decibels) }
        return level
    }

    @Test func aQuietRoomShowsNothing() {
        var meter = VoiceMeter()
        #expect(feed(&meter, -62, times: 40) < 0.05)
    }

    @Test func aVoiceWellAboveTheRoomFillsTheBars() {
        var meter = VoiceMeter()
        _ = feed(&meter, -62, times: 20)
        #expect(feed(&meter, -32, times: 3) > 0.8)
    }

    /// The microphone runs without gain control: held away from the mouth,
    /// speech is only some twenty decibels above a very quiet room.
    @Test func aFaintVoiceStillMovesTheBars() {
        var meter = VoiceMeter()
        _ = feed(&meter, -72, times: 20)
        #expect(feed(&meter, -50, times: 3) > 0.5)
    }

    @Test func speakingFromTheFirstInstantMovesTheBars() {
        var meter = VoiceMeter()
        #expect(feed(&meter, -40, times: 3) > 0.3)
    }

    @Test func theBarsFallSlowlyBetweenSyllables() {
        var meter = VoiceMeter()
        _ = feed(&meter, -62, times: 20)
        let loud = feed(&meter, -32, times: 5)
        let justAfter = meter.level(decibels: -62)
        #expect(justAfter > loud * 0.6)
        #expect(feed(&meter, -62, times: 30) < 0.05)
    }

    /// Speech dips to the room between words; a breath every couple of seconds is enough.
    @Test func aLongSentenceDoesNotFlattenTheBars() {
        var meter = VoiceMeter()
        _ = feed(&meter, -62, times: 20)
        var level: Float = 0
        for slice in 1...600 { level = meter.level(decibels: slice % 40 == 0 ? -60 : -35) }
        #expect(level > 0.5)
    }

    /// A fan, a train: steady noise is the room, however loud.
    @Test func steadyNoiseSettlesToNothing() {
        var meter = VoiceMeter()
        #expect(feed(&meter, -38, times: 200) < 0.05)
        #expect(feed(&meter, -18, times: 3) > 0.5)
    }

    @Test func theLevelStaysBetweenZeroAndOne() {
        var meter = VoiceMeter()
        for decibels: Float in [-200, 0, 30, -.infinity, .nan, -62, -10] {
            let level = meter.level(decibels: decibels)
            #expect(level >= 0 && level <= 1)
        }
    }
}
