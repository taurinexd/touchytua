import XCTest

/// A scripted finger for the Simulator, where nothing else can tap. Not a
/// test of its own: end-to-end runs drive the app with it while real Claude
/// Code sessions run on the Mac.
///
///   TEST_RUNNER_STEPS="waitFor:WAITING;tap:WAITING;shot:detail;tap:Approve" \
///   TEST_RUNNER_SHOT_DIR=/tmp/shots xcodebuild test-without-building …
///
/// Steps, separated by `;`:
///   shot:<name>            save a screenshot as <name>.png in SHOT_DIR
///   tap:<text>             tap the first element whose label contains <text>
///   swipeRight:<text> / swipeLeft:<text>
///   scrollDown / scrollUp  drag the content one screenful
///   type:<text>            type into the focused field
///   waitFor:<text>         wait up to 60 s for an element to appear
///   waitGone:<text>        wait up to 60 s for it to disappear
///   sleep:<seconds>
///   back                   tap the navigation bar's back button
///   relaunch               terminate and launch the app
final class DriverTests: XCTestCase {
    // Not `testRun`: XCTest already has a property with that name, and the
    // runner would call that instead of this method.
    @MainActor func testDrive() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["SHOT_DIR"] ?? NSTemporaryDirectory()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.activate()
        for step in (environment["STEPS"] ?? "shot:screen").split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "shot":
                let file = URL(fileURLWithPath: directory).appendingPathComponent(argument + ".png")
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
            case "tap":
                let target = try find(argument, in: app)
                print("DRIVER tap \(argument): \(target.elementType.rawValue) \(target.frame)")
                target.tap()
            case "swipeRight":
                try find(argument, in: app).swipeRight()
            case "swipeLeft":
                try find(argument, in: app).swipeLeft()
            case "scrollDown":
                app.swipeUp()
            case "scrollUp":
                app.swipeDown()
            case "type":
                app.typeText(argument)
            case "waitFor":
                XCTAssertTrue(element(argument, in: app).waitForExistence(timeout: 60), "never appeared: \(argument)")
            case "waitGone":
                XCTAssertTrue(element(argument, in: app).waitForNonExistence(timeout: 60), "never went away: \(argument)")
            case "sleep":
                Thread.sleep(forTimeInterval: Double(argument) ?? 1)
            case "back":
                app.navigationBars.buttons.firstMatch.tap()
            case "relaunch":
                app.terminate()
                app.launch()
            default:
                XCTFail("unknown step: \(step)")
            }
        }
    }

    /// A control with that label if there is one, else anything: a container
    /// can carry its children's text, and tapping it would miss the button.
    @MainActor private func element(_ text: String, in app: XCUIApplication) -> XCUIElement {
        let labelled = NSPredicate(format: "label CONTAINS[c] %@ OR placeholderValue CONTAINS[c] %@", text, text)
        for query in [app.buttons, app.textFields, app.textViews, app.staticTexts] {
            let match = query.matching(labelled).firstMatch
            if match.exists { return match }
        }
        return app.descendants(matching: .any).matching(labelled).firstMatch
    }

    @MainActor private func find(_ text: String, in app: XCUIApplication) throws -> XCUIElement {
        var found = element(text, in: app)
        if !found.exists {
            _ = found.waitForExistence(timeout: 15)
            found = element(text, in: app)
        }
        guard found.exists else {
            throw XCTSkip("no element labelled \(text)").asFailure()
        }
        return found
    }
}

private extension XCTSkip {
    /// A missing element is a failed run, not a skipped one.
    func asFailure() -> NSError {
        NSError(domain: "DriverTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message ?? "missing element"])
    }
}
