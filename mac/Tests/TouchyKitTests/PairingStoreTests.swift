import CryptoKit
import Foundation
import Testing
@testable import TouchyKit

@Suite struct PairingStoreTests {
    private func tempDir() -> String {
        let d = NSTemporaryDirectory() + "tt-pair-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    private func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int) ?? -1
    }

    @Test func macKeyIsCreatedOnceWith0600() throws {
        let dir = tempDir()
        let store = PairingStore(directory: dir)
        let k1 = try store.macKey(), k2 = try store.macKey()
        #expect(k1.publicKey.rawRepresentation == k2.publicKey.rawRepresentation)
        #expect(mode(dir + "/mac-key") == 0o600)
    }

    @Test func beginPairingStoresSecretAndReturnsPayload() throws {
        let dir = tempDir()
        let store = PairingStore(directory: dir)
        let payload = try store.beginPairing(endpoints: ["lan:10.0.0.2:47311"], macName: "Mac")
        #expect(payload.macKey == (try store.macKey()).publicKey.rawRepresentation)
        #expect(payload.secret.count == 32)
        #expect(store.load().pendingSecret == payload.secret)
        #expect(mode(dir + "/pairing.json") == 0o600)
    }

    @Test func completePairingSavesPhoneAndBurnsSecret() throws {
        let store = PairingStore(directory: tempDir())
        _ = try store.beginPairing(endpoints: [], macName: "Mac")
        store.completePairing(phoneKey: Data(repeating: 3, count: 32), deviceName: "iPhone")
        let state = store.load()
        #expect(state.phoneKey == Data(repeating: 3, count: 32))
        #expect(state.deviceName == "iPhone")
        #expect(state.pendingSecret == nil)
    }

    /// The QR secret is short-lived: an unscanned QR must not stay valid forever.
    @Test func pendingSecretExpires() throws {
        let store = PairingStore(directory: tempDir())
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let payload = try store.beginPairing(endpoints: [], macName: "Mac", now: t0)
        #expect(store.activeSecret(now: t0.addingTimeInterval(PairingStore.secretLifetime - 1)) == payload.secret)
        #expect(store.activeSecret(now: t0.addingTimeInterval(PairingStore.secretLifetime + 1)) == nil)
    }

    @Test func completePairingDeletesTheQRImage() throws {
        let dir = tempDir()
        let store = PairingStore(directory: dir)
        _ = try store.beginPairing(endpoints: [], macName: "Mac")
        FileManager.default.createFile(atPath: store.qrImagePath, contents: Data([1]))
        store.completePairing(phoneKey: Data(repeating: 3, count: 32), deviceName: nil)
        #expect(!FileManager.default.fileExists(atPath: store.qrImagePath))
        #expect(store.activeSecret(now: Date()) == nil)
    }
}
