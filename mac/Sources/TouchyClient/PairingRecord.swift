import CryptoKit
import Foundation

/// A Mac this phone is paired with.
public struct PairingRecord: Codable, Equatable, Sendable {
    public var macName: String
    /// The Mac's static public key, pinned from the QR.
    public var macKey: Data
    /// Where the QR said the Mac listens, in the order to try them.
    public var endpoints: [String]

    public init(macName: String, macKey: Data, endpoints: [String]) {
        self.macName = macName
        self.macKey = macKey
        self.endpoints = endpoints
    }
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
