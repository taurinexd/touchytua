import Testing
@testable import TouchyClient
import TouchyProtocol

@Suite struct PermissionModeTests {
    @Test func theFourModesOfTheCycleAreOfferedInItsOrder() {
        #expect(PermissionMode.cycle.map(\.wire) == ["default", "acceptEdits", "plan", "auto"])
        #expect(PermissionMode.cycle.map(\.label) == ["Manual", "Accept edits", "Plan", "Auto"])
    }

    @Test func aTapMovesToTheNextModeAndAround() {
        #expect(PermissionMode(wire: "default").next.wire == "acceptEdits")
        #expect(PermissionMode(wire: "auto").next.wire == "default")
        // From a mode outside the cycle, back to its start.
        #expect(PermissionMode(wire: "bypassPermissions").next.wire == "default")
    }

    @Test func modesOutsideTheCycleAreStillNamed() {
        #expect(PermissionMode(wire: "bypassPermissions").label == "Bypass permissions")
        #expect(PermissionMode(wire: "dontAsk").label == "Don't ask")
        #expect(PermissionMode(wire: "somethingNew").label == "somethingNew")
        #expect(PermissionMode(wire: nil).label == "Manual")
    }

    private func session(mode: String?, next: String?) -> Session {
        Session(id: "s", title: "t", cwd: "/p", state: .working, lastEventAt: .distantPast, mode: mode, nextMode: next)
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

    /// The slots above the button, counted from the nearest one.
    @Test func theFingerPicksTheSlotItIsOver() {
        let pick = { PermissionMode.slot(lifted: $0, slotHeight: 48, count: 4) }
        #expect(pick(0) == nil)
        #expect(pick(20) == nil)
        #expect(pick(40) == 0)
        #expect(pick(90) == 1)
        #expect(pick(215) == 3)
        #expect(pick(400) == nil)
        #expect(pick(-30) == nil)
    }
}
