import Foundation
import TouchyProtocol

/// Starting a session on the Mac from the phone: where it can be started,
/// and what went wrong when it could not.
public struct Launcher: Equatable, Sendable {
    public private(set) var folders: [StartFolder] = []
    /// The list of folders is on its way.
    public private(set) var isLoading = false
    public private(set) var problem: String?

    public init() {}

    public mutating func asked() {
        isLoading = true
        problem = nil
    }

    public mutating func received(folders: [StartFolder], enabled: Bool) {
        isLoading = false
        self.folders = folders
        if !enabled {
            problem = "Starting sessions from the phone is switched off on your Mac. Turn it on there with: touchytua phone-start on"
        } else if folders.isEmpty {
            problem = "No folders yet. One appears here once a session has run in it on your Mac."
        } else {
            problem = nil
        }
    }

    /// A start is on its way: what went wrong before no longer applies.
    public mutating func starting() {
        problem = nil
    }

    /// Takes an error from the Mac. False when it is about something else.
    public mutating func failed(code: String) -> Bool {
        if code == "unsupported_message" {
            guard isLoading else { return false }
            isLoading = false
            problem = "Update the touchytua plugin on your Mac to start sessions from here."
            return true
        }
        guard let message = Self.messages[code] else { return false }
        isLoading = false
        problem = message
        return true
    }

    public mutating func interrupted() {
        isLoading = false
    }

    private static let messages = [
        "start_disabled": "Starting sessions from the phone is switched off on your Mac. Turn it on there with: touchytua phone-start on",
        "start_unknown_folder": "That folder isn't available any more.",
        "start_empty_prompt": "Write what the session should do.",
        "start_too_many": "Too many sessions started in a minute. Try again shortly.",
        "start_failed": "Your Mac couldn't start Claude Code.",
    ]
}
