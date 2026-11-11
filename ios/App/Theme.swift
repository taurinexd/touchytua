import SwiftUI
import TouchyProtocol

/// Colors and type, in one place.
enum Theme {
    static let background = Color.black
    static let surface = Color(hex: 0x0C0C0C)
    static let surfaceRaised = Color(hex: 0x141414)
    static let border = Color(hex: 0x232323)
    static let borderStrong = Color(hex: 0x2E2E2E)
    static let text = Color.white
    static let textSecondary = Color(hex: 0xB4B4B4)
    static let textTertiary = Color(hex: 0x8A8A8A)
    static let green = Color(hex: 0x72FF47)
    /// Behind white text, where the bright green would not be readable.
    static let greenDeep = Color(hex: 0x2A9D1E)
    static let redDeep = Color(hex: 0xD63A4A)
    static let blue = Color(hex: 0x4DA3FF)
    static let yellow = Color(hex: 0xF5D90A)
    static let red = Color(hex: 0xFF5C6C)

    /// Titles and status labels.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom("Space Grotesk", size: size).weight(weight)
    }

    /// Running text.
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

extension SessionState {
    var color: Color {
        switch self {
        case .working: Theme.blue
        case .waiting: Theme.yellow
        case .done, .ready: Theme.green
        case .error: Theme.red
        }
    }

    var label: String {
        switch self {
        case .working: "WORKING"
        case .waiting: "WAITING"
        case .done: "DONE"
        case .ready: "READY"
        case .error: "ERROR"
        }
    }
}
