import SwiftUI
import TouchyProtocol

/// The small glowing dot that carries a session's state.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.9), radius: 5)
    }
}

/// A rounded surface, optionally outlined with a glow in `glow`.
struct Card: ViewModifier {
    var glow: Color?
    var radius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(glow ?? Theme.border, lineWidth: glow == nil ? 1 : 1.5)
            }
            .shadow(color: (glow ?? .clear).opacity(0.45), radius: glow == nil ? 0 : 8)
    }
}

extension View {
    func card(glow: Color? = nil, radius: CGFloat = 14) -> some View {
        modifier(Card(glow: glow, radius: radius))
    }
}

/// The two-button vocabulary of the app: a filled action and an outlined one.
struct ActionButtonStyle: ButtonStyle {
    let color: Color
    var filled = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(16, .bold))
            .foregroundStyle(filled ? Color.black : color)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(filled ? color : color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(filled ? 0 : 0.6), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}
