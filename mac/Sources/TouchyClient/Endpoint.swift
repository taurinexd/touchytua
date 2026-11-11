import Foundation
import TouchyProtocol

/// One way to reach the Mac. An address only says where to knock; who
/// answers is settled by the handshake.
public enum Endpoint: Equatable, Sendable {
    /// `lan:<host>:<port>`, from the QR.
    case lan(host: String, port: UInt16)
    /// `ts:<name>:<port>`, from the QR.
    case tailscale(host: String, port: UInt16)
    /// `bonjour:<id>`: the Mac announcing this id, wherever it is on the
    /// local network now. Derived from the Mac's key, never in the QR.
    case bonjour(id: String)

    public init?(_ text: String) {
        guard let first = text.firstIndex(of: ":") else { return nil }
        let rest = text[text.index(after: first)...]
        switch text[..<first] {
        case "bonjour":
            guard !rest.isEmpty else { return nil }
            self = .bonjour(id: String(rest))
        case "lan", "ts":
            guard let last = rest.lastIndex(of: ":"), last > rest.startIndex,
                  let port = UInt16(rest[rest.index(after: last)...]) else { return nil }
            let host = String(rest[..<last])
            self = text.hasPrefix("lan") ? .lan(host: host, port: port) : .tailscale(host: host, port: port)
        default:
            return nil
        }
    }

    public static func bonjour(forMacKey key: Data) -> Endpoint {
        .bonjour(id: Discovery.id(forMacKey: key))
    }

    public var text: String {
        switch self {
        case let .lan(host, port): "lan:\(host):\(port)"
        case let .tailscale(host, port): "ts:\(host):\(port)"
        case let .bonjour(id): "bonjour:\(id)"
        }
    }

    /// What the app shows next to "connected".
    public var label: String {
        switch self {
        case .lan, .bonjour: "Wi-Fi"
        case .tailscale: "Tailscale"
        }
    }
}
