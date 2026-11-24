import Foundation
import Testing
@testable import TouchyClient
import TouchyProtocol

@Suite struct SessionArchiveTests {
    private let then = Date(timeIntervalSince1970: 1000)

    private func session(_ id: String, roundAt: TimeInterval? = 10, state: SessionState = .done) -> Session {
        Session(
            id: id, title: id, cwd: "/p", state: state,
            round: roundAt.map { Round(startedAt: Date(timeIntervalSince1970: $0)) }, lastEventAt: then)
    }

    @Test func anArchivedSessionIsPutAway() {
        var archive = SessionArchive()
        archive.put(away: session("a"), at: then)
        #expect(archive.hides(session("a"), waitingOnYou: false))
        #expect(!archive.hides(session("b"), waitingOnYou: false))
    }

    @Test func itStaysAwayWhileNothingNewIsAsked() {
        var archive = SessionArchive()
        archive.put(away: session("a"), at: then)
        // The same round going on, or ending, is not something new.
        #expect(archive.hides(session("a", state: .working), waitingOnYou: false))
    }

    @Test func aNewPromptBringsItBack() {
        var archive = SessionArchive()
        archive.put(away: session("a", roundAt: 10), at: then)
        #expect(!archive.hides(session("a", roundAt: 50), waitingOnYou: false))
    }

    @Test func aSessionPutAwayBeforeItsFirstPromptComesBackWithIt() {
        var archive = SessionArchive()
        archive.put(away: session("a", roundAt: nil), at: then)
        #expect(archive.hides(session("a", roundAt: nil), waitingOnYou: false))
        #expect(!archive.hides(session("a", roundAt: 5), waitingOnYou: false))
    }

    @Test func aSessionThatAsksSomethingIsNeverHidden() {
        var archive = SessionArchive()
        archive.put(away: session("a"), at: then)
        #expect(!archive.hides(session("a", state: .waiting), waitingOnYou: true))
    }

    @Test func countsWhatItHidesAmongTheSessionsShown() {
        var archive = SessionArchive()
        archive.put(away: session("a"), at: then)
        archive.put(away: session("b"), at: then)
        let sessions = [session("a"), session("b", roundAt: 99), session("c")]
        #expect(archive.hidden(among: sessions) { _ in false } == 1)
    }

    @Test func bringingEverythingBackEmptiesIt() {
        var archive = SessionArchive()
        archive.put(away: session("a"), at: then)
        archive.bringAllBack()
        #expect(!archive.hides(session("a"), waitingOnYou: false))
        #expect(archive == SessionArchive())
    }

    @Test func itIsKeptAcrossLaunches() throws {
        var archive = SessionArchive()
        archive.put(away: session("a"), at: then)
        let again = SessionArchive(data: archive.data)
        #expect(again == archive)
        #expect(SessionArchive(data: Data("junk".utf8)) == SessionArchive())
    }

    @Test func itForgetsTheOldestBeyondAFewHundred() {
        var archive = SessionArchive()
        for index in 0..<(SessionArchive.most + 5) {
            archive.put(away: session("s\(index)"), at: then + Double(index))
        }
        #expect(!archive.hides(session("s0"), waitingOnYou: false))
        #expect(archive.hides(session("s\(SessionArchive.most + 4)"), waitingOnYou: false))
    }
}
