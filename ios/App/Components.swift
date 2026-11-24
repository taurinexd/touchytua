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

/// The two-button vocabulary of the app: a filled action and an outlined
/// one. Both are the system's glass, which answers the finger by itself:
/// it grows and brightens under a touch, and follows a drag.
struct ActionButtonStyle: ButtonStyle {
    let color: Color
    var filled = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        configuration.label
            .font(Theme.display(16, .bold))
            .foregroundStyle(filled ? Color.black : color)
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay { shape.strokeBorder(color.opacity(filled ? 0 : 0.6), lineWidth: 1) }
            .glassEffect(.regular.tint(filled ? color : color.opacity(0.12)).interactive(isEnabled), in: shape)
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// A card or a row that is tapped: lighter and a touch smaller under the
/// finger, back with a small bounce.
struct RowPressStyle: ButtonStyle {
    var radius: CGFloat = 14
    /// Rows that fill a card edge to edge do not shrink: they only light up.
    var shrinks = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed && shrinks ? 0.975 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/// A control that is only words or a small sign: it dims under the finger.
struct DimPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.25), value: configuration.isPressed)
    }
}
