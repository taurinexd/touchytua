import Foundation
import TouchyProtocol

/// A Claude Code permission mode, as the phone names and offers it.
public struct PermissionMode: Equatable, Sendable, Identifiable {
    /// The name Claude Code uses: "default", "acceptEdits", "plan", "auto"…
    public let wire: String

    public var id: String { wire }

    /// Nil, before Claude Code has said, reads as the mode sessions ask in.
    public init(wire: String?) {
        self.wire = wire ?? "default"
    }

    /// The modes Shift+Tab goes through in the terminal, in its order.
    public static let cycle = ["default", "acceptEdits", "plan", "auto"].map(PermissionMode.init(wire:))

    public var label: String {
        switch wire {
        case "default": "Manual"
        case "acceptEdits": "Accept edits"
        case "plan": "Plan"
        case "auto": "Auto"
        case "bypassPermissions": "Bypass permissions"
        case "dontAsk": "Don't ask"
        default: wire
        }
    }

    /// What the mode does, in a few words.
    public var summary: String {
        switch wire {
        case "default": "Asks before it acts"
        case "acceptEdits": "Edits files without asking"
        case "plan": "Plans first, changes nothing"
        case "auto": "Decides by itself what is safe"
        default: ""
        }
    }

    /// The mode a tap moves to.
    public var next: PermissionMode {
        guard let index = Self.cycle.firstIndex(of: self) else { return Self.cycle[0] }
        return Self.cycle[(index + 1) % Self.cycle.count]
    }

    /// Which of the slots stacked above the button the finger is over,
    /// counted from the nearest: `lifted` is how far up it has moved.
    /// Nil over the button itself, or past the last slot.
    public static func slot(lifted: Double, slotHeight: Double, count: Int) -> Int? {
        // The first slot starts a little above the button's middle.
        let start = slotHeight * 0.6
        guard lifted >= start else { return nil }
        let index = Int((lifted - start) / slotHeight)
        return index < count ? index : nil
    }
}

extension Session {
    /// The mode the button shows: the one chosen, while it is on its way.
    public var shownMode: PermissionMode {
        PermissionMode(wire: nextMode ?? mode)
    }

    /// One line about a chosen mode Claude Code has not taken yet.
    public var modeNote: String? {
        guard let nextMode, nextMode != mode else { return nil }
        return "\(PermissionMode(wire: nextMode).label) mode starts at Claude's next step, with a request to approve."
    }
}
