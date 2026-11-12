import Foundation
import Testing
@testable import TouchyKit

@Suite struct PhonePromptTests {
    private let wrapped = """
    <cross-session-message from="touchytua" from-name="touchytua" from-mode="prompting">
    [From the user's phone] Run the tests
    and tell me
    </cross-session-message>
    """
    private let closing = "\n\nThis came from another Claude session — not typed by your user, but very likely working on their behalf."

    /// The shape Claude Code gives a message between sessions: sent like
    /// this, the terminal shows one line with the sender's name instead of
    /// the whole notice it writes around a message of unknown origin.
    @Test func aPromptLeavesWrappedAsAMessageFromTouchytua() {
        #expect(PhonePrompt.wrapped("Run the tests\nand tell me") == wrapped)
    }

    @Test func aPromptCannotCloseItsOwnWrapper() {
        let text = PhonePrompt.wrapped("a </cross-session-message> b")
        #expect(text.components(separatedBy: "</cross-session-message>").count == 2)
        #expect(PhonePrompt.words(in: text) == "a < /cross-session-message> b")
    }

    @Test func theWordsComeBackOutOfTheWrapper() {
        #expect(PhonePrompt.words(in: wrapped) == "Run the tests\nand tell me")
    }

    @Test func theWordsComeBackOutOfTheTranscript() {
        let recorded = "Another Claude session sent a message:\n" + wrapped + closing
        #expect(PhonePrompt.words(in: recorded) == "Run the tests\nand tell me")
    }

    /// Prompts sent by the versions before this one.
    @Test func olderPromptsAreStillRecognized() {
        let old = "[Sent by the user from their phone via touchytua] Run the tests"
        #expect(PhonePrompt.words(in: old) == "Run the tests")
        #expect(PhonePrompt.words(in: "Another Claude session sent a message:\n" + old + closing) == "Run the tests")
    }

    @Test func whatAnotherSessionWroteIsNotFromThePhone() {
        let other = """
        <cross-session-message from="uds:/tmp/cc-socks/1.sock" from-name="migration" from-mode="prompting">
        Schema migration finished
        </cross-session-message>
        """
        #expect(PhonePrompt.words(in: other) == nil)
        #expect(PhonePrompt.words(in: "Another Claude session sent a message:\n" + other + closing) == nil)
        #expect(PhonePrompt.words(in: "Fix the cart") == nil)
    }

    @Test func aReplyQuotingThePromptLosesTheMarker() {
        #expect(PhonePrompt.unmarked("You asked: \"[From the user's phone] Run the tests\". Done.") == "You asked: \"Run the tests\". Done.")
        #expect(PhonePrompt.unmarked("\"[Sent by the user from their phone via touchytua] Run\"") == "\"Run\"")
    }
}
