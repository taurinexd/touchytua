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
    /// Only addresses that can be dialed count, and a list with none of
    /// them changes nothing: the ones already known may still work.
    public func refreshed(with addresses: [String]) -> PairingRecord {
        var kept: [String] = []
        for address in addresses {
            switch Endpoint(address) {
            case .lan, .tailscale: if !kept.contains(address) { kept.append(address) }
            default: break
            }
        }
        guard !kept.isEmpty else { return self }
        var record = self
        record.endpoints = Array(kept.prefix(Self.mostAddresses))
        return record
    }

    static let mostAddresses = 6
}

/// Where the phone keeps its key and its pairings: the Keychain in the app,
/// a file in the command-line simulator.
public protocol SecretStore: Sendable {
    /// The phone's static private key, created on first use.
    func phoneKey() throws -> Curve25519.KeyAgreement.PrivateKey
    /// Most recently paired first.
    func pairings() -> [PairingRecord]
    /// Adds a pairing, replacing an earlier one with the same Mac.
    func save(_ record: PairingRecord)
    func remove(macKey: Data)
}
