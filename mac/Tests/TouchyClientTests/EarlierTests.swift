import Foundation
import Testing
@testable import TouchyClient
import TouchyProtocol

@Suite struct EarlierTests {
    private func session(_ id: String = "s1", roundAt: Double = 10) -> Session {
        Session(id: id, title: "shop", cwd: "/p/shop", state: .done,
                round: Round(startedAt: Date(timeIntervalSince1970: roundAt)), lastEventAt: Date(timeIntervalSince1970: 0))
    }

    private func item(_ id: String, _ text: String = "words") -> HistoryItem {
        HistoryItem(id: id, kind: .reply, text: text, at: Date(timeIntervalSince1970: 1))
    }

    @Test func nothingIsLoadedUntilAsked() {
        let earlier = Earlier()
        #expect(earlier.page(of: "s1") == .init())
        #expect(earlier.page(of: "s1").canLoadMore)
    }

    @Test func askingStartsFromTheRoundOnScreen() {
        var earlier = Earlier()
        #expect(earlier.ask(session()) == .some(nil))
        #expect(earlier.page(of: "s1").isLoading)
    }

    @Test func askingTwiceSendsOneRequest() {
        var earlier = Earlier()
        _ = earlier.ask(session())
        #expect(earlier.ask(session()) == nil)
    }

    @Test func aPageIsPutBeforeWhatIsAlreadyThere() {
        var earlier = Earlier()
        _ = earlier.ask(session())
        earlier.received(sessionId: "s1", items: [item("c"), item("d")], next: "128")
        #expect(earlier.ask(session()) == .some("128"))
        earlier.received(sessionId: "s1", items: [item("a"), item("b")], next: nil)

        let page = earlier.page(of: "s1")
        #expect(page.items.map(\.id) == ["a", "b", "c", "d"])
        #expect(!page.isLoading)
        #expect(!page.canLoadMore)
        #expect(earlier.ask(session()) == nil)
    }

    @Test func anAnswerNobodyAskedForIsIgnored() {
        var earlier = Earlier()
        earlier.received(sessionId: "s1", items: [item("a")], next: nil)
        #expect(earlier.page(of: "s1").items.isEmpty)
    }

    @Test func aMacThatCannotGiveHistorySaysSo() {
        var earlier = Earlier()
        _ = earlier.ask(session())
        earlier.failed()
        let page = earlier.page(of: "s1")
        #expect(page.isUnavailable)
        #expect(!page.isLoading)
        #expect(!page.canLoadMore)
    }

    @Test func aDroppedConnectionLetsYouAskAgain() {
        var earlier = Earlier()
        _ = earlier.ask(session())
        earlier.interrupted()
        #expect(!earlier.page(of: "s1").isLoading)
        #expect(earlier.ask(session()) == .some(nil))
    }

    /// The round that was on screen is now history too: what was loaded no
    /// longer reaches up to the present, so it is asked for again.
    @Test func aNewRoundStartsTheHistoryOver() {
        var earlier = Earlier()
        _ = earlier.ask(session())
        earlier.received(sessionId: "s1", items: [item("a")], next: nil)
        earlier.settle(with: [session(roundAt: 10)])
        #expect(earlier.page(of: "s1").items.count == 1)

        earlier.settle(with: [session(roundAt: 20)])

        #expect(earlier.page(of: "s1") == .init())
    }

    @Test func leavingASessionForgetsItsHistory() {
        var earlier = Earlier()
        _ = earlier.ask(session())
        earlier.received(sessionId: "s1", items: [item("a")], next: "64")
        earlier.forget("s1")
        #expect(earlier.page(of: "s1") == .init())
    }

    @Test func aSessionThatEndedTakesItsHistoryWithIt() {
        var earlier = Earlier()
        _ = earlier.ask(session())
        earlier.received(sessionId: "s1", items: [item("a")], next: nil)
        earlier.settle(with: [])
        #expect(earlier.page(of: "s1") == .init())
    }
}
