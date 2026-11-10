import CryptoKit
import Foundation

public enum ChannelError: Error, Equatable {
    case malformed, replay, authentication
}

/// ChaCha20-Poly1305 framing over one handshake's keys.
/// Frame = counter (UInt64 big-endian, 8 bytes) || ciphertext || tag.
/// Nonce = 4 zero bytes || counter. Counters must strictly increase.
public struct SecureChannel: Sendable {
    private let keys: SessionKeys
    private var sendCounter: UInt64 = 0
    private var lastReceived: UInt64?

    public init(keys: SessionKeys) {
        self.keys = keys
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        sendCounter += 1
        let header = Self.bigEndian(sendCounter)
        let box = try ChaChaPoly.seal(plaintext, using: keys.send, nonce: Self.nonce(header))
        return header + box.ciphertext + box.tag
    }

    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 8 + 16 else { throw ChannelError.malformed }
        let header = frame.prefix(8)
        let counter = header.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        if let last = lastReceived, counter <= last { throw ChannelError.replay }
        let body = frame.dropFirst(8)
        guard let box = try? ChaChaPoly.SealedBox(
            nonce: Self.nonce(Data(header)), ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let plaintext = try? ChaChaPoly.open(box, using: keys.receive) else {
            throw ChannelError.authentication
        }
        lastReceived = counter
        return plaintext
    }

    static func bigEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func nonce(_ header: Data) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + header)
    }
}
