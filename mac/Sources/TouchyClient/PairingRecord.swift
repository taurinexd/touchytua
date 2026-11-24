import CryptoKit
import Foundation

/// A Mac this phone is paired with.
public struct PairingRecord: Codable, Equatable, Sendable {
    public var macName: String
    /// The Mac's static public key, pinned from the QR.
    public var macKey: Data
    /// Where the Mac listens, in the order to try them: from the QR, then
    /// whatever the Mac said last.
    public var endpoints: [String]

    public init(macName: String, macKey: Data, endpoints: [String]) {
        self.macName = macName
        self.macKey = macKey
        self.endpoints = endpoints
    }

    /// This pairing with the addresses the Mac says it listens on now.
    /// Only addresses that can be dialed count. A kind the Mac leaves out
    /// (Tailscale switched off for a moment) keeps the address already
    /// known: it may work again by the time it is needed.
    public func refreshed(with addresses: [String]) -> PairingRecord {
        var kept: [String] = []
        var kinds: Set<String> = []
        for address in addresses {
            guard let kind = Self.kind(of: address), !kept.contains(address) else { continue }
            kept.append(address)
            kinds.insert(kind)
        }
        guard !kept.isEmpty else { return self }
        for address in endpoints {
            guard let kind = Self.kind(of: address), !kinds.contains(kind), !kept.contains(address) else { continue }
            kept.append(address)
        }
        var record = self
        record.endpoints = Array(kept.prefix(Self.mostAddresses))
        return record
    }

    /// `lan` or `ts` for an address that can be dialed, nil for anything else.
    private static func kind(of address: String) -> String? {
        switch Endpoint(address) {
        case .lan: "lan"
        case .tailscale: "ts"
        default: nil
        }
    }

    static let mostAddresses = 6
}

/// A Mac whose plugin is older than the one this app was built with.
public struct MacUpdate: Equatable, Sendable {
    /// What the Mac runs; nil when it is too old to say.
    public let installed: String?
    public let wanted: String

    public init(installed: String?, wanted: String) {
        self.installed = installed
        self.wanted = wanted
    }

    /// What is the matter, for the Mac called `macName`.
    public func explanation(macName: String) -> String {
        let runs = installed.map { "touchytua \($0)" } ?? "an older touchytua"
        return "\(macName) runs \(runs); this app is made for \(wanted). Until it is updated, some of what the app shows is missing there."
    }

    /// What to do about it, on that Mac.
    public static let steps =
        "In Claude Code on that Mac: /plugin marketplace update taurinexd, then /plugin update touchytua@taurinexd, then restart Claude Code."

    /// How not to be told again.
    public static let keepUpdated =
        "To have updates arrive by themselves, turn on auto-update for taurinexd under Marketplaces in /plugin."
}

/// A paired Mac as a list shows it.
public struct PairedMac: Identifiable, Equatable, Sendable {
    /// The Mac's public key: two Macs may carry the same name.
    public let id: Data
    public let name: String

    public init(id: Data, name: String) {
        self.id = id
        self.name = name
    }
}

/// Where the phone keeps its key and its pairings: the Keychain in the app,
/// a file in the command-line simulator.
public protocol SecretStore: Sendable {
    /// The phone's static private key, created on first use.
    func phoneKey() throws -> Curve25519.KeyAgreement.PrivateKey
    /// Most recently saved first: the first is the Mac in use.
    func pairings() -> [PairingRecord]
    /// Puts a pairing first, replacing an earlier one with the same Mac.
    func save(_ record: PairingRecord)
    func remove(macKey: Data)
}
