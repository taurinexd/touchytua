import Foundation

/// A prompt on its way from the phone into a session, and back out of what
/// Claude Code then reports about it.
///
/// The only door into a running session is its inbox, where Claude Code
/// takes everything for a message from another session. Sent in the shape
/// Claude Code itself gives such messages, a prompt shows in the terminal
/// as one line under the sender's name; sent bare, it shows with the whole
/// notice Claude Code writes around a message of unknown origin.
public enum PhonePrompt {
    /// The name the terminal shows the message under.
    public static let sender = "touchytua"
    /// Tells Claude who wrote the words: the person, not a session.
    public static let marker = "[From the user's phone] "
    /// The markers of the versions before this one.
    static let markers = [marker, "[Sent by the user from their phone via touchytua] "]

    private static let opening =
        "<cross-session-message from=\"\(sender)\" from-name=\"\(sender)\" from-mode=\"prompting\">\n"
    private static let closing = "\n</cross-session-message>"
    /// What Claude Code writes, in the transcript, before and after a
    /// message that came in through the inbox.
    private static let frameOpening = "Another Claude session sent a message:"
    private static let frameClosing = "\n\nThis came from another Claude session"

    /// The words as they go on the inbox line.
    public static func wrapped(_ text: String) -> String {
        // The words must not be able to close their own wrapper.
        let safe = text.replacingOccurrences(of: "</cross-session-message", with: "< /cross-session-message")
        return opening + marker + safe + closing
    }

    /// The person's words out of a prompt as a hook or the transcript
    /// reports it. Nil when the prompt did not come from the phone.
    public static func words(in prompt: String) -> String? {
        var text = Substring(prompt)
        if text.hasPrefix(frameOpening) {
            text = text.dropFirst(frameOpening.count)
            if let end = text.range(of: frameClosing) { text = text[..<end.lowerBound] }
        }
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.hasPrefix(opening) {
            words.removeFirst(opening.count)
            if words.hasSuffix(closing) { words.removeLast(closing.count) }
        }
        guard let marker = markers.first(where: words.hasPrefix) else { return nil }
        words.removeFirst(marker.count)
        words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// A text without the markers: Claude sometimes quotes a phone prompt
    /// back, marker included.
    public static func unmarked(_ text: String) -> String {
        markers.reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
    }
}
