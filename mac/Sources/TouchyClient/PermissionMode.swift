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

    /// The modes Shift+Tab goes through in the terminal, in its order:
    /// bypass before auto.
    public static let cycle = ["default", "acceptEdits", "plan", "bypassPermissions", "auto"]
        .map(PermissionMode.init(wire:))

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
        case "bypassPermissions": "Never asks"
        case "dontAsk": "Refuses what it would ask for"
        default: ""
        }
    }

    /// Where bubble `index` of `count` sits on the quarter ring that opens
    /// up and to the right of the button: the first straight up, the last
    /// straight to the right.
    public static func ringPlace(_ index: Int, radius: Double, count: Int) -> (right: Double, up: Double) {
        let angle = ringAngle(index, count: count)
        return (radius * cos(angle), radius * sin(angle))
    }

    /// Which bubble the finger points at, from how far it has moved from
    /// the button. Nil close to the button, far beyond the ring, or off
    /// to a side the ring does not open on.
    public static func ringSlot(right: Double, up: Double, radius: Double, count: Int) -> Int? {
        let distance = (right * right + up * up).squareRoot()
        guard count > 0, distance >= radius * 0.45, distance <= radius * 1.6 else { return nil }
        let angle = atan2(up, right)
        // A little past either end of the arc still counts.
        let slack = Double.pi / 10
        guard angle >= -slack, angle <= .pi / 2 + slack else { return nil }
        guard count > 1 else { return 0 }
        let step = (Double.pi / 2) / Double(count - 1)
        return min(count - 1, max(0, Int(((.pi / 2 - angle) / step).rounded())))
    }

    private static func ringAngle(_ index: Int, count: Int) -> Double {
        count > 1 ? .pi / 2 - Double(index) * (.pi / 2) / Double(count - 1) : .pi / 4
    }
}

extension Session {
    /// The modes to choose from: the cycle, and always the mode the
    /// session is in, so that it can be chosen back.
    public var offeredModes: [PermissionMode] {
        var offered = PermissionMode.cycle
        let current = PermissionMode(wire: mode)
        if !offered.contains(current) { offered.append(current) }
        return offered
    }

    /// The mode a tap moves to: the one after the mode shown.
    public var modeAfterTap: PermissionMode {
        let offered = offeredModes
        guard let index = offered.firstIndex(of: shownMode) else { return offered[0] }
        return offered[(index + 1) % offered.count]
    }

    /// The mode the button shows: the one chosen, while it is on its way.
    public var shownMode: PermissionMode {
        PermissionMode(wire: nextMode ?? mode)
    }

    /// Why this session's mode cannot be changed from the phone, when it
    /// cannot: a new mode travels with the answer to a permission request,
    /// and in these modes the session never makes one.
    public var modeLock: String? {
        guard let mode, ["bypassPermissions", "dontAsk"].contains(mode) else { return nil }
        return "This session never asks for permission, so its mode changes only on your Mac, with Shift+Tab."
    }

    /// One line about a chosen mode Claude Code has not taken yet.
    public var modeNote: String? {
        guard let nextMode, nextMode != mode else { return nil }
        return "\(PermissionMode(wire: nextMode).label) mode starts at Claude's next step, with a request to approve."
    }
}
