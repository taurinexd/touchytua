import Foundation
import Testing
@testable import TouchyClient
import TouchyProtocol

@Suite struct LauncherTests {
    private let shop = StartFolder(path: "/p/shop", name: "shop")

    @Test func theFoldersComeFromTheMac() {
        var launcher = Launcher()
        launcher.asked()
        #expect(launcher.isLoading)
        launcher.received(folders: [shop], enabled: true)
        #expect(launcher.folders == [shop])
        #expect(!launcher.isLoading)
        #expect(launcher.problem == nil)
    }

    @Test func aMacWithStartingSwitchedOffSaysHowToTurnItOn() {
        var launcher = Launcher()
        launcher.asked()
        launcher.received(folders: [], enabled: false)
        #expect(launcher.problem == "Starting sessions from the phone is switched off on your Mac. Turn it on there with: touchytua phone-start on")
    }

    @Test func aMacWithNoFoldersYetSaysWhereTheyComeFrom() {
        var launcher = Launcher()
        launcher.asked()
        launcher.received(folders: [], enabled: true)
        #expect(launcher.problem == "No folders yet. One appears here once a session has run in it on your Mac.")
    }

    @Test func aRefusedStartIsExplained() {
        var launcher = Launcher()
        launcher.starting()
        let handled1 = launcher.failed(code: "start_too_many")
        #expect(handled1)
        #expect(launcher.problem == "Too many sessions started in a minute. Try again shortly.")
        let handled2 = launcher.failed(code: "start_failed")
        #expect(handled2)
        #expect(launcher.problem == "Your Mac couldn't start Claude Code.")
        launcher.starting()
        #expect(launcher.problem == nil)
    }

    /// A plugin older than this app does not know the question.
    @Test func anOlderPluginIsAskedToUpdate() {
        var launcher = Launcher()
        launcher.asked()
        let handled3 = launcher.failed(code: "unsupported_message")
        #expect(handled3)
        #expect(launcher.problem == "Update the touchytua plugin on your Mac to start sessions from here.")
        #expect(!launcher.isLoading)
    }

    @Test func errorsAboutOtherThingsAreNotItsOwn() {
        var launcher = Launcher()
        let handled4 = launcher.failed(code: "unsupported_message")
        #expect(!handled4)
        let handled5 = launcher.failed(code: "inject_failed")
        #expect(!handled5)
        #expect(launcher.problem == nil)
    }

    @Test func aDroppedConnectionStopsTheWait() {
        var launcher = Launcher()
        launcher.asked()
        launcher.interrupted()
        #expect(!launcher.isLoading)
    }
}
