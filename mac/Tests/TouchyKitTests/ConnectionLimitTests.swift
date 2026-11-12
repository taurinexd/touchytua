import Testing
@testable import TouchyKit

@Suite struct ConnectionLimitTests {
    @Test func connectionsAreAdmittedUpToTheLimit() {
        let limit = ConnectionLimit(max: 2)
        #expect(limit.admit())
        #expect(limit.admit())
        #expect(!limit.admit())
    }

    @Test func aClosedConnectionMakesRoomForAnother() {
        let limit = ConnectionLimit(max: 1)
        #expect(limit.admit())
        #expect(!limit.admit())
        limit.release()
        #expect(limit.admit())
    }

    @Test func releasingMoreThanAdmittedDoesNotAddRoom() {
        let limit = ConnectionLimit(max: 1)
        limit.release()
        #expect(limit.admit())
        #expect(!limit.admit())
    }
}
