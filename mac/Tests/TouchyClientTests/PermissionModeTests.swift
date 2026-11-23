import Testing
@testable import TouchyClient
import TouchyProtocol

@Suite struct PermissionModeTests {
    /// The order of Shift+Tab in the terminal, bypass before auto.
    @Test func theModesOfTheCycleAreOfferedInItsOrder() {
        #expect(PermissionMode.cycle.map(\.wire) == ["default", "acceptEdits", "plan", "bypassPermissions", "auto"])
        #expect(PermissionMode.cycle.map(\.label) == ["Manual", "Accept edits", "Plan", "Bypass permissions", "Auto"])
    }

    private func session(mode: String?, next: String? = nil) -> Session {
        Session(id: "s", title: "t", cwd: "/p", state: .working, lastEventAt: .distantPast, mode: mode, nextMode: next)
    }

    @Test func aTapMovesToTheNextModeAndAround() {
        #expect(session(mode: "default").modeAfterTap.wire == "acceptEdits")
        #expect(session(mode: "plan").modeAfterTap.wire == "bypassPermissions")
        #expect(session(mode: "bypassPermissions").modeAfterTap.wire == "auto")
        #expect(session(mode: "auto").modeAfterTap.wire == "default")
        // A tap goes on from the mode chosen, not from the one still in force.
        #expect(session(mode: "default", next: "plan").modeAfterTap.wire == "bypassPermissions")
    }

    /// A mode outside the cycle is still offered, so that it can be chosen back.
    @Test func theModeTheSessionIsInIsAlwaysOffered() {
        let odd = session(mode: "dontAsk")
        #expect(odd.offeredModes.map(\.wire) == ["default", "acceptEdits", "plan", "bypassPermissions", "auto", "dontAsk"])
        #expect(odd.modeAfterTap.wire == "default")
    }

    @Test func modesOutsideTheCycleAreStillNamed() {
        #expect(PermissionMode(wire: "bypassPermissions").label == "Bypass permissions")
        #expect(PermissionMode(wire: "dontAsk").label == "Don't ask")
        #expect(PermissionMode(wire: "somethingNew").label == "somethingNew")
        #expect(PermissionMode(wire: nil).label == "Manual")
    }

    /// The button shows where the session is going, not only where it is.
    @Test func aChosenModeShowsAtOnceAsOnItsWay() {
        let waiting = session(mode: "default", next: "plan")
        #expect(waiting.shownMode.wire == "plan")
        #expect(waiting.modeNote == "Plan mode starts at Claude's next step, with a request to approve.")
        let settled = session(mode: "plan", next: nil)
        #expect(settled.shownMode.wire == "plan")
        #expect(settled.modeNote == nil)
    }

    /// Only a permission request can carry a new mode into a session, and
    /// these modes never make one.
    @Test func aSessionThatNeverAsksSaysWhereItsModeIsChanged() {
        #expect(session(mode: "bypassPermissions").modeLock == "This session never asks for permission, so its mode changes only on your Mac, with Shift+Tab.")
        #expect(session(mode: "dontAsk").modeLock != nil)
        #expect(session(mode: "auto").modeLock == nil)
        #expect(session(mode: nil).modeLock == nil)
    }

    /// The bubbles open on a quarter ring up and to the right of the
    /// button, the first straight up, the last straight to the right.
    @Test func theFingerPicksTheBubbleItPointsAt() {
        let pick = { (right: Double, up: Double) in PermissionMode.ringSlot(right: right, up: up, radius: 120, count: 5) }
        #expect(pick(0, 120) == 0)
        #expect(pick(46, 111) == 1)
        #expect(pick(85, 85) == 2)
        #expect(pick(111, 46) == 3)
        #expect(pick(120, 0) == 4)
        // A little past the ends of the arc still counts.
        #expect(pick(-15, 118) == 0)
        #expect(pick(118, -15) == 4)
    }

    @Test func nearTheButtonOrAwayFromTheRingNothingIsPicked() {
        let pick = { (right: Double, up: Double) in PermissionMode.ringSlot(right: right, up: up, radius: 120, count: 5) }
        #expect(pick(0, 0) == nil)
        #expect(pick(20, 30) == nil)
        #expect(pick(-90, 60) == nil)
        #expect(pick(60, -90) == nil)
        #expect(pick(220, 220) == nil)
    }

    @Test func aBubblesPlaceOnTheRing() {
        let top = PermissionMode.ringPlace(0, radius: 120, count: 5)
        let end = PermissionMode.ringPlace(4, radius: 120, count: 5)
        #expect(abs(top.right) < 0.001 && abs(top.up - 120) < 0.001)
        #expect(abs(end.right - 120) < 0.001 && abs(end.up) < 0.001)
        let middle = PermissionMode.ringPlace(2, radius: 120, count: 5)
        #expect(abs(middle.right - middle.up) < 0.001)
    }
}
