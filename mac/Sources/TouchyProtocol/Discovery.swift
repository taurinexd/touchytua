import CryptoKit
import Foundation

/// How a phone finds its Mac on the local network when the address in the
/// QR no longer holds. A hint only: the handshake decides who is who.
public enum Discovery {
    public static let serviceType = "_touchytua._tcp"

    /// A short public fingerprint of the Mac's key, announced in the TXT
    /// record so a phone can pick its Mac among several.
    public static func id(forMacKey key: Data) -> String {
        SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The DNS-SD TXT record `id=<id>`.
    public static func txtRecord(id: String) -> Data {
        let entry = Data("id=\(id)".utf8)
        return Data([UInt8(entry.count)]) + entry
    }
}
