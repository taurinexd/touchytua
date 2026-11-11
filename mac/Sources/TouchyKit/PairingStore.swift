import CryptoKit
import Foundation

public struct PairingState: Codable, Equatable, Sendable {
    public var phoneKey: Data?
    public var deviceName: String?
    /// Set by `touchytua pair`, burned by the first successful handshake.
    public var pendingSecret: Data?
    /// After this moment the pending secret no longer pairs anything.
    public var pendingSecretExpiresAt: Date?

    public init(
        phoneKey: Data? = nil, deviceName: String? = nil,
        pendingSecret: Data? = nil, pendingSecretExpiresAt: Date? = nil
    ) {
        self.phoneKey = phoneKey
        self.deviceName = deviceName
        self.pendingSecret = pendingSecret
        self.pendingSecretExpiresAt = pendingSecretExpiresAt
    }
}

/// File-backed pairing state under `~/.touchytua` (all files mode 0600).
/// Shared by the daemon (reads on every handshake) and the `pair` command.
public final class PairingStore: @unchecked Sendable {
    private let directory: String
    private let lock = NSLock()

    public init(directory: String) {
        self.directory = directory
    }

    /// How long a QR stays scannable.
    public static let secretLifetime: TimeInterval = 600

    /// The QR as an image, for `touchytua pair`; deleted once it has been used.
    public var qrImagePath: String { directory + "/pair.png" }

    /// The pending pairing secret, nil when there is none or it has expired.
    public func activeSecret(now: Date) -> Data? {
        let state = load()
        guard let secret = state.pendingSecret, let expires = state.pendingSecretExpiresAt, now < expires else {
            return nil
        }
        return secret
    }

    private var keyPath: String { directory + "/mac-key" }
    private var statePath: String { directory + "/pairing.json" }

    public func macKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock(); defer { lock.unlock() }
        if let raw = FileManager.default.contents(atPath: keyPath) {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try write(key.rawRepresentation, to: keyPath)
        return key
    }

    public func load() -> PairingState {
        lock.lock(); defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: statePath) else { return PairingState() }
        return (try? JSONDecoder().decode(PairingState.self, from: data)) ?? PairingState()
    }

    public func save(_ state: PairingState) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(state) { try? write(data, to: statePath) }
    }

    /// Creates a fresh one-time secret and the payload for the QR.
    public func beginPairing(endpoints: [String], macName: String, now: Date = Date()) throws -> PairingPayload {
        let key = try macKey()
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var state = load()
        state.pendingSecret = secret
        state.pendingSecretExpiresAt = now.addingTimeInterval(Self.secretLifetime)
        save(state)
        return PairingPayload(v: 1, macKey: key.publicKey.rawRepresentation, secret: secret,
                              endpoints: endpoints, macName: macName)
    }

    /// v1 pairs one phone: a new pairing replaces the previous phone.
    public func completePairing(phoneKey: Data, deviceName: String?) {
        save(PairingState(phoneKey: phoneKey, deviceName: deviceName, pendingSecret: nil))
        try? FileManager.default.removeItem(atPath: qrImagePath)
    }

    private func write(_ data: Data, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        chmod(path, 0o600)
    }
}
