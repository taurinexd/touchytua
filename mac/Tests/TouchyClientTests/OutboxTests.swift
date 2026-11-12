import Foundation
import Testing
@testable import TouchyClient
import TouchyProtocol

@Suite struct OutboxTests {
    private func session(_ id: String = "s1", roundAt: Double? = 10, prompt: String? = "Fix the cart") -> Session {
        Session(
            id: id, title: "shop", cwd: "/p/shop", state: .working,
            round: roundAt.map { Round(startedAt: Date(timeIntervalSince1970: $0), prompt: prompt) },
            lastEventAt: Date(timeIntervalSince1970: 0))
    }

    @Test func aSentPromptWaitsUntilClaudeTakesIt() {
        var outbox = Outbox()
        outbox.sent("  and run the tests\n", to: session())
        #expect(outbox.waiting(in: "s1").map(\.text) == ["and run the tests"])
        #expect(outbox.waiting(in: "s2").isEmpty)
    }

    @Test func theRoundThatWasRunningDoesNotTakeIt() {
        var outbox = Outbox()
        outbox.sent("Fix the cart", to: session())
        outbox.settle(with: [session()])
        #expect(outbox.waiting(in: "s1").count == 1)
    }

    @Test func aNewRoundWithThatPromptTakesIt() {
        var outbox = Outbox()
        outbox.sent("and run the tests", to: session())
        outbox.settle(with: [session(roundAt: 20, prompt: "and run the tests")])
        #expect(outbox.waiting(in: "s1").isEmpty)
    }

    @Test func aLongPromptIsRecognizedByItsCutCopy() {
        var outbox = Outbox()
        let long = String(repeating: "word ", count: 200)
        outbox.sent(long, to: session())
        outbox.settle(with: [session(roundAt: 20, prompt: String(long.prefix(590)) + "…")])
        #expect(outbox.waiting(in: "s1").isEmpty)
    }

    @Test func aNewRoundAboutSomethingElseLeavesItWaiting() {
        var outbox = Outbox()
        outbox.sent("and run the tests", to: session())
        outbox.settle(with: [session(roundAt: 20, prompt: nil), session("s2", roundAt: 30, prompt: "and run the tests")])
        #expect(outbox.waiting(in: "s1").count == 1)
    }

    @Test func twoPromptsAreTakenOneRoundEach() {
        var outbox = Outbox()
        outbox.sent("first", to: session())
        outbox.sent("second", to: session())
        outbox.settle(with: [session(roundAt: 20, prompt: "first")])
        #expect(outbox.waiting(in: "s1").map(\.text) == ["second"])
    }

    @Test func aSessionThatEndedTakesItsPromptsWithIt() {
        var outbox = Outbox()
        outbox.sent("and run the tests", to: session())
        outbox.settle(with: [])
        #expect(outbox.waiting(in: "s1").isEmpty)
    }

    @Test func aPromptToASessionThatNeverRanIsTakenByItsFirstRound() {
        var outbox = Outbox()
        outbox.sent("hello", to: session(roundAt: nil))
        outbox.settle(with: [session(roundAt: 5, prompt: "hello")])
        #expect(outbox.waiting(in: "s1").isEmpty)
    }

    @Test func aPromptTheMacRefusedIsNotWaiting() {
        var outbox = Outbox()
        outbox.sent("first", to: session())
        outbox.sent("second", to: session())
        outbox.dropLast()
        #expect(outbox.waiting(in: "s1").map(\.text) == ["first"])
    }
}
