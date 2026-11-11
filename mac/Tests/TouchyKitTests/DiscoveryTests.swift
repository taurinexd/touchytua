import CryptoKit
import Foundation
import Testing
@testable import TouchyProtocol

@Suite struct DiscoveryTests {
    @Test func idIsAShortStableFingerprintOfTheMacKey() {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let id = Discovery.id(forMacKey: key)
        #expect(id.count == 16)
        #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(id == Discovery.id(forMacKey: key))
        #expect(id != Discovery.id(forMacKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation))
    }

    /// DNS-SD TXT format: one length byte, then `key=value`.
    @Test func txtRecordCarriesTheId() {
        let record = Discovery.txtRecord(id: "0123456789abcdef")
        #expect(record == Data([19]) + Data("id=0123456789abcdef".utf8))
    }
}
