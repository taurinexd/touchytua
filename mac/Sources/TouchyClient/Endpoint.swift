import Foundation

/// One way to reach the Mac, as written in the QR: `lan:<host>:<port>` or
/// `ts:<name>:<port>`. An address only says where to knock; who answers is
/// settled by the handshake.
public struct Endpoint: Equatable, Sendable {
    public enum Route: String, Sendable {
        case lan
        case tailscale = "ts"
    }

    public let route: Route
    public let host: String
    public let port: UInt16

    public init?(_ text: String) {
        guard let first = text.firstIndex(of: ":"), let last = text.lastIndex(of: ":"), first < last,
              let route = Route(rawValue: String(text[..<first])),
              let port = UInt16(text[text.index(after: last)...]) else { return nil }
        let host = String(text[text.index(after: first)..<last])
        guard !host.isEmpty else { return nil }
        self.route = route
        self.host = host
        self.port = port
    }

    /// What the app shows next to "connected".
    public var label: String {
        switch route {
        case .lan: "Wi-Fi"
        case .tailscale: "Tailscale"
        }
    }
}
