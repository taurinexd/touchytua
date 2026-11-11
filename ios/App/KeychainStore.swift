import CryptoKit
import Foundation
import Security
import TouchyClient

/// The phone's key and its pairings, in the Keychain. Readable after the
/// first unlock (notifications will need them with the phone locked) and
/// never copied to another device.
struct KeychainStore: SecretStore {
    private static let service = "com.taurinexd.touchytua"
    private static let phoneKeyAccount = "phone-key"
    private static let pairingsAccount = "pairings"

    enum KeychainError: Error {
        case status(OSStatus)
    }

    func phoneKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let raw = read(Self.phoneKeyAccount),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try write(key.rawRepresentation, account: Self.phoneKeyAccount)
        return key
    }

    func pairings() -> [PairingRecord] {
        guard let data = read(Self.pairingsAccount) else { return [] }
        return (try? JSONDecoder().decode([PairingRecord].self, from: data)) ?? []
    }

    func save(_ record: PairingRecord) {
        store([record] + pairings().filter { $0.macKey != record.macKey })
    }

    func remove(macKey: Data) {
        store(pairings().filter { $0.macKey != macKey })
    }

    private func store(_ records: [PairingRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? write(data, account: Self.pairingsAccount)
    }

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: account]
    }

    private func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private func write(_ data: Data, account: String) throws {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var q = query(account)
        q[kSecValueData] = data
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(q as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError.status(add) }
    }
}
