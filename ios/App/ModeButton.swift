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
/// Shift+Tab is in the terminal. A tap moves to the next mode. Held, a
/// ring of bubbles opens up and to the right of it, one per mode, and
/// the finger slides onto the one to take.
struct ModeButton: View {
    let mode: PermissionMode
    /// The modes to choose from, top to bottom.
    let options: [PermissionMode]
    /// The mode a tap moves to.
    let afterTap: PermissionMode
    /// The mode shown was chosen here and Claude Code has not taken it yet.
    let pending: Bool
    let enabled: Bool
    let choose: (PermissionMode) -> Void

    /// When the finger went down.
    @State private var pressedAt: Date?
    @State private var open = false
    /// The bubble the finger points at.
    @State private var picked: Int?
    @State private var opener: Task<Void, Never>?
    /// True while the finger is down: the system resets it even when it
    /// takes the touch away without ending the gesture.
    @GestureState private var touching = false

    /// How long the finger rests before the ring opens.
    private static let holdToOpen = 0.14
    /// A touch that ends on no bubble sooner than this was a tap, even if
    /// the ring had begun to open.
    private static let longestTap = 0.3
    /// How far from the button the bubbles sit, and how large they are.
    private static let radius: CGFloat = 152
    private static let bubble: CGFloat = 54

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
            .accessibilityAction { choose(afterTap) }
            // The menu is always in the view and only fades: swapping
            // views under a finger would cancel the gesture.
            .overlay { ring }
            .overlay(alignment: .bottomLeading) {
                caption.offset(y: -(Self.radius + Self.bubble / 2 + 30))
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

    /// The bubbles on their quarter ring, and the arc they sit on. They
    /// start under the button and fly out to their places.
    private var ring: some View {
        ZStack {
            Circle()
                .trim(from: 0.75, to: 1)
                .stroke(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                .frame(width: Self.radius * 2, height: Self.radius * 2)
                .opacity(open ? 1 : 0)
                .scaleEffect(open ? 1 : 0.3)
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                let place = PermissionMode.ringPlace(index, radius: Self.radius, count: options.count)
                let isPicked = picked == index
                Image(systemName: option.symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isPicked ? Color.black : option.color)
                    .frame(width: Self.bubble, height: Self.bubble)
                    .background(isPicked ? option.color : Theme.surfaceRaised, in: Circle())
                    .overlay {
                        Circle().strokeBorder(option.color.opacity(option == mode ? 1 : 0.45), lineWidth: option == mode ? 2 : 1)
                    }
                    .shadow(color: isPicked ? option.color.opacity(0.6) : .black.opacity(0.6), radius: isPicked ? 12 : 8)
                    .scaleEffect(open ? (isPicked ? 1.22 : 1) : 0.4)
                    .offset(x: open ? place.right : 0, y: open ? -place.up : 0)
                    .opacity(open ? 1 : 0)
                    .animation(.spring(duration: 0.32, bounce: 0.35).delay(open ? Double(index) * 0.03 : 0), value: open)
                    .animation(.spring(duration: 0.18), value: picked)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The name of the mode under the finger, above the ring: the finger
    /// hides the bubble it is on.
    private var caption: some View {
        let shown = picked.map { options[$0] } ?? mode
        return VStack(alignment: .leading, spacing: 2) {
            Text(shown.label)
                .font(Theme.display(16, .bold))
                .foregroundStyle(picked == nil ? Theme.textSecondary : shown.color)
            Text(picked == nil ? "Slide onto a mode" : shown.summary)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .fixedSize()
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.borderStrong, lineWidth: 1) }
        .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
        .opacity(open ? 1 : 0)
        .offset(y: open ? 0 : 12)
        .animation(.spring(duration: 0.26), value: open)
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
                let over = PermissionMode.ringSlot(
                    right: finger.translation.width, up: -finger.translation.height,
                    radius: Self.radius, count: options.count)
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
        if let slot, wasOpen {
            choose(options[slot])
        } else if Date.now.timeIntervalSince(since) < Self.longestTap {
            choose(afterTap)
        }
    }
}
