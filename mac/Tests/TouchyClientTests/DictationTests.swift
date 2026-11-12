import Foundation
import Testing
@testable import TouchyClient

/// A speech engine that says what the test tells it to.
final class ScriptedEngine: SpeechEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var feed: AsyncThrowingStream<SpeechEvent, Error>.Continuation?
    private var _locales: [Locale] = []
    private var _stops = 0
    private var _cancels = 0
    /// What the engine still recognizes after the microphone closes.
    var lastWords: [SpeechEvent] = []

    var locales: [Locale] { lock.withLock { _locales } }
    var stops: Int { lock.withLock { _stops } }
    var cancels: Int { lock.withLock { _cancels } }

    func listen(locale: Locale) -> AsyncThrowingStream<SpeechEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        lock.withLock {
            _locales.append(locale)
            feed = continuation
        }
        return stream
    }

    func stop() async {
        let feed = lock.withLock {
            _stops += 1
            return self.feed
        }
        for event in lastWords { feed?.yield(event) }
        feed?.finish()
    }

    func cancel() async {
        let feed = lock.withLock {
            _cancels += 1
            return self.feed
        }
        feed?.finish()
    }

    func say(_ events: SpeechEvent...) {
        let feed = lock.withLock { self.feed }
        for event in events { feed?.yield(event) }
    }

    func fail(_ problem: SpeechProblem) {
        lock.withLock { feed }?.finish(throwing: problem)
    }

    /// The microphone goes away on its own: a phone call, the app in background.
    func interrupt() {
        lock.withLock { feed }?.finish()
    }
}

private let italian = Locale(identifier: "it_IT")

@MainActor @Suite struct DictationTests {
    let engine = ScriptedEngine()

    @Test func wordsAppearWhileSpeaking() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "", locale: italian)
        engine.say(.listening, .partial("ciao"))
        #expect(await eventually { dictation.text == "ciao" })
        #expect(dictation.phase == .listening)
        #expect(engine.locales == [italian])
    }

    @Test func settledWordsReplaceTheGuess() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "", locale: italian)
        engine.say(.listening, .partial("ciao mon"), .final("Ciao mondo."), .partial(" Come"))
        #expect(await eventually { dictation.text == "Ciao mondo. Come" })
    }

    @Test func dictationIsAddedAfterWhatWasTyped() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "fix the", locale: italian)
        engine.say(.listening, .final(" login bug"))
        #expect(await eventually { dictation.text == "fix the login bug" })
    }

    @Test func typedTextEndingInASpaceGetsNoSecondSpace() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "fix the\n", locale: italian)
        engine.say(.listening, .final(" login bug"))
        #expect(await eventually { dictation.text == "fix the\nlogin bug" })
    }

    @Test func typedTextStaysOnScreenBeforeTheFirstWord() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "fix the", locale: italian)
        #expect(dictation.text == "fix the")
        #expect(dictation.phase == .preparing(nil))
    }

    @Test func finishingWaitsForTheLastWords() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "", locale: italian)
        engine.say(.listening, .partial("run the"))
        #expect(await eventually { dictation.text == "run the" })
        engine.lastWords = [.final("Run the tests.")]

        let text = await dictation.finish()

        #expect(text == "Run the tests.")
        #expect(dictation.phase == .idle)
        #expect(engine.stops == 1)
    }

    @Test func aGuessNeverSettledIsStillKept() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "", locale: italian)
        engine.say(.listening, .partial("deploy now"))
        #expect(await eventually { dictation.text == "deploy now" })

        #expect(await dictation.finish() == "deploy now")
    }

    @Test func cancellingRestoresWhatWasTyped() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "keep me", locale: italian)
        engine.say(.listening, .partial("drop this"))
        #expect(await eventually { dictation.text == "keep me drop this" })

        await dictation.cancel()

        #expect(dictation.text == "keep me")
        #expect(dictation.phase == .idle)
        #expect(engine.cancels == 1)
        #expect(engine.stops == 0)
    }

    @Test func theModelDownloadShowsItsProgress() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "", locale: italian)
        engine.say(.downloading(0.4))
        #expect(await eventually { dictation.phase == .preparing(0.4) })
        engine.say(.listening)
        #expect(await eventually { dictation.phase == .listening })
    }

    @Test func theMicrophoneLevelFollowsTheVoice() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "", locale: italian)
        engine.say(.listening, .level(0.7))
        #expect(await eventually { dictation.level == 0.7 })
        _ = await dictation.finish()
        #expect(dictation.level == 0)
    }

    @Test func aRefusedMicrophoneIsExplained() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "typed", locale: italian)
        engine.fail(.microphoneDenied)
        #expect(await eventually { dictation.phase == .idle })
        #expect(dictation.problem == SpeechProblem.microphoneDenied.message)
        #expect(dictation.text == "typed")
    }

    @Test func aNewDictationClearsTheOldProblem() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "", locale: italian)
        engine.fail(.modelUnavailable)
        #expect(await eventually { dictation.problem != nil })

        dictation.start(after: "", locale: italian)

        #expect(dictation.problem == nil)
    }

    @Test func anInterruptionKeepsWhatWasSaid() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "", locale: italian)
        engine.say(.listening, .final("Half a sentence"))
        engine.interrupt()
        #expect(await eventually { dictation.phase == .idle })
        #expect(dictation.text == "Half a sentence")
    }

    @Test func startingTwiceOpensOneMicrophone() async {
        let dictation = Dictation(engine: engine)
        dictation.start(after: "", locale: italian)
        dictation.start(after: "", locale: italian)
        engine.say(.listening)
        #expect(await eventually { dictation.phase == .listening })
        #expect(engine.locales.count == 1)
    }

    @Test func finishingWhenIdleReturnsTheText() async {
        let dictation = Dictation(engine: engine)
        #expect(await dictation.finish() == "")
        #expect(engine.stops == 0)
    }
}

@Suite struct HoldToTalkTests {
    @Test func aReleaseSendsWhatWasSaid() {
        #expect(HoldToTalk.prompt(heldFor: 1.2, text: " Run the tests.\n") == "Run the tests.")
    }

    @Test func aBriefTouchSendsNothing() {
        #expect(HoldToTalk.prompt(heldFor: 0.2, text: "Run") == nil)
    }

    @Test func silenceSendsNothing() {
        #expect(HoldToTalk.prompt(heldFor: 3, text: "  \n") == nil)
    }
}

@Suite struct DictationLanguageTests {
    /// Stands in for the system's own matching: same language and region,
    /// else the first supported locale of that language.
    static func equivalent(in supported: [String]) -> @Sendable (Locale) async -> Locale? {
        { wanted in
            let all = supported.map(Locale.init(identifier:))
            return all.first { $0.identifier(.bcp47) == wanted.identifier(.bcp47) }
                ?? all.first { $0.language.languageCode == wanted.language.languageCode }
        }
    }

    @Test func theChosenLanguageWins() async {
        let locale = await DictationLanguage.resolve(
            chosen: "en-US", device: Locale(identifier: "it_IT"),
            equivalent: Self.equivalent(in: ["it-IT", "en-US"]))
        #expect(locale?.identifier(.bcp47) == "en-US")
    }

    @Test func withNoChoiceThePhoneLanguageIsUsed() async {
        let locale = await DictationLanguage.resolve(
            chosen: nil, device: Locale(identifier: "it_IT"),
            equivalent: Self.equivalent(in: ["en-US", "it-IT"]))
        #expect(locale?.identifier(.bcp47) == "it-IT")
    }

    @Test func aChoiceThePhoneNoLongerSupportsFallsBackToThePhoneLanguage() async {
        let locale = await DictationLanguage.resolve(
            chosen: "nl-NL", device: Locale(identifier: "it_IT"),
            equivalent: Self.equivalent(in: ["en-US", "it-IT"]))
        #expect(locale?.identifier(.bcp47) == "it-IT")
    }

    @Test func anUnsupportedPhoneLanguageFallsBackToEnglish() async {
        let locale = await DictationLanguage.resolve(
            chosen: nil, device: Locale(identifier: "sq_AL"),
            equivalent: Self.equivalent(in: ["it-IT", "en-GB", "en-US"]))
        #expect(locale?.identifier(.bcp47) == "en-US")
    }

    @Test func withNothingSupportedThereIsNoLanguage() async {
        let locale = await DictationLanguage.resolve(
            chosen: nil, device: Locale(identifier: "it_IT"), equivalent: Self.equivalent(in: []))
        #expect(locale == nil)
    }

    @Test func languagesAreListedByNameInTheirOwnLanguage() {
        let names = DictationLanguage.names(for: ["en-US", "it-IT", "en-GB"].map(Locale.init(identifier:)))
        #expect(names.map(\.id) == ["en-GB", "en-US", "it-IT"])
        #expect(names.last?.name == "Italiano (Italia)")
    }
}
