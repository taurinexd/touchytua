import SwiftUI
import TouchyClient
import UIKit

extension PermissionMode {
    var symbol: String {
        switch wire {
        case "acceptEdits": "pencil"
        case "plan": "list.bullet.clipboard"
        case "auto": "bolt.fill"
        case "bypassPermissions", "dontAsk": "exclamationmark.triangle.fill"
        default: "hand.raised.fill"
        }
    }

    var color: Color {
        switch wire {
        case "acceptEdits": Theme.blue
        case "plan": Theme.green
        case "auto": Theme.yellow
        case "bypassPermissions", "dontAsk": Theme.red
        default: Theme.textSecondary
        }
    }
}

/// The session's permission mode, to the left of the prompt: what
/// Shift+Tab is in the terminal. A tap moves to the next mode; held, it
/// opens the four of them, and the finger slides onto the one to take.
struct ModeButton: View {
    let mode: PermissionMode
    /// The mode shown was chosen here and Claude Code has not taken it yet.
    let pending: Bool
    let enabled: Bool
    let choose: (PermissionMode) -> Void

    /// When the finger went down.
    @State private var pressedAt: Date?
    @State private var open = false
    /// The slot under the finger, counted from the one nearest the button.
    @State private var picked: Int?
    @State private var opener: Task<Void, Never>?
    /// True while the finger is down: the system resets it even when it
    /// takes the touch away without ending the gesture.
    @GestureState private var touching = false

    /// A hold shorter than this is a tap.
    private static let holdToOpen = 0.28
    private static let slotHeight: CGFloat = 52
    /// Top to bottom, in the order of the cycle.
    private static let options = PermissionMode.cycle

    var body: some View {
        face
            // Only the circle takes the touch, not the room its menu opens in.
            .gesture(hold, isEnabled: enabled)
            .onChange(of: touching) { _, touching in
                if !touching { released(cancelled: true) }
            }
            .opacity(enabled ? 1 : 0.35)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Permission mode: \(mode.label)")
            .accessibilityHint("Tap for the next mode, or hold to pick one")
            .accessibilityAction { choose(mode.next) }
            // The menu is always in the view and only fades: swapping
            // views under a finger would cancel the gesture.
            .overlay(alignment: .bottomLeading) {
                menu.offset(y: -(42 + Self.slotHeight * 0.6 - 21))
            }
    }

    private var face: some View {
        Image(systemName: mode.symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(mode.color)
            .frame(width: 42, height: 42)
            .background(Theme.surfaceRaised, in: Circle())
            .overlay {
                Circle().strokeBorder(
                    mode.color.opacity(open ? 1 : 0.55),
                    style: StrokeStyle(lineWidth: 1.5, dash: pending ? [4, 3] : []))
            }
            .shadow(color: mode.color.opacity(open ? 0.5 : 0), radius: 8)
            .scaleEffect(open ? 1.12 : 1)
            .contentShape(Circle())
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.options.enumerated()), id: \.element.id) { index, option in
                let isPicked = picked == Self.options.count - 1 - index
                HStack(spacing: 12) {
                    Image(systemName: option.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(option.color)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(Theme.display(15, .bold))
                            .foregroundStyle(Theme.text)
                        Text(option.summary)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if option == mode {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(width: 252, height: Self.slotHeight)
                .background(isPicked ? option.color.opacity(0.18) : .clear)
                // Each row arrives a moment after the one below it.
                .opacity(open ? 1 : 0)
                .offset(y: open ? 0 : 10)
                .animation(.spring(duration: 0.28).delay(open ? Double(Self.options.count - 1 - index) * 0.035 : 0), value: open)
            }
        }
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.borderStrong, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
        .scaleEffect(open ? 1 : 0.6, anchor: .bottomLeading)
        .opacity(open ? 1 : 0)
        .animation(.spring(duration: 0.26, bounce: 0.25), value: open)
        .animation(.easeOut(duration: 0.1), value: picked)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var hold: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { finger in
                if pressedAt == nil {
                    pressedAt = .now
                    opener = Task {
                        try? await Task.sleep(for: .seconds(Self.holdToOpen))
                        guard !Task.isCancelled, pressedAt != nil else { return }
                        open = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
                guard open else { return }
                let slot = PermissionMode.slot(
                    lifted: -finger.translation.height, slotHeight: Self.slotHeight, count: Self.options.count)
                // Off to the side of the menu is off the menu.
                let over = abs(finger.translation.width) < 252 ? slot : nil
                if over != picked {
                    picked = over
                    if over != nil { UISelectionFeedbackGenerator().selectionChanged() }
                }
            }
            .onEnded { _ in released(cancelled: false) }
    }

    /// The finger left. Only the first call for a touch counts.
    private func released(cancelled: Bool) {
        guard let since = pressedAt else { return }
        opener?.cancel()
        pressedAt = nil
        let wasOpen = open, slot = picked
        open = false
        picked = nil
        guard !cancelled else { return }
        if wasOpen {
            if let slot { choose(Self.options[Self.options.count - 1 - slot]) }
        } else if Date.now.timeIntervalSince(since) < Self.holdToOpen {
            choose(mode.next)
        }
    }
}
