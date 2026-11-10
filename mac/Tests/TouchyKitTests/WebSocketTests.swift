import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

@Suite struct WebSocketTests {
    @Test func acceptKeyMatchesRFC6455Example() {
        #expect(WebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")  // gitleaks:allow (RFC 6455 sample nonce)
    }

    @Test func parsesUpgradeRequestKey() {
        let req = "GET / HTTP/1.1\r\nHost: x:47311\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"  // gitleaks:allow (RFC 6455 sample nonce)
        #expect(WebSocket.upgradeKey(fromRequest: Data(req.utf8)) == "dGhlIHNhbXBsZSBub25jZQ==")  // gitleaks:allow (RFC 6455 sample nonce)
        #expect(WebSocket.upgradeKey(fromRequest: Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) == nil)
    }

    @Test func handshakeResponseCarriesAccept() {
        let r = String(decoding: WebSocket.handshakeResponse(key: "dGhlIHNhbXBsZSBub25jZQ=="), as: UTF8.self)  // gitleaks:allow (RFC 6455 sample nonce)
        #expect(r.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        #expect(r.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        #expect(r.hasSuffix("\r\n\r\n"))
    }

    @Test func decodesMaskedClientFrameFromRFC() throws {
        var buffer = Data([0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58, 0xAA])
        let frame = try #require(try WebSocket.decodeFrame(from: &buffer))
        #expect(frame.opcode == 0x1)
        #expect(String(decoding: frame.payload, as: UTF8.self) == "Hello")
        #expect(buffer == Data([0xAA]), "consumes exactly one frame")
    }

    @Test func incompleteFrameReturnsNil() throws {
        var buffer = Data([0x82, 0xFE, 0x01])
        #expect(try WebSocket.decodeFrame(from: &buffer) == nil)
        #expect(buffer.count == 3)
    }

    @Test func roundTripsExtendedLength() throws {
        let payload = Data((0..<300).map { UInt8($0 % 251) })
        var buffer = WebSocket.encodeFrame(opcode: 0x2, payload: payload)
        #expect(buffer[1] == 126, "server frames are unmasked, 16-bit length")
        let frame = try #require(try WebSocket.decodeFrame(from: &buffer))
        #expect(frame.opcode == 0x2 && frame.payload == payload && buffer.isEmpty)
    }

    @Test func fragmentedFramesRejected() {
        var buffer = Data([0x02, 0x81, 0, 0, 0, 0, 0x41])
        #expect(throws: WebSocket.FrameError.unsupported) { _ = try WebSocket.decodeFrame(from: &buffer) }
    }

    @Test func hugeLengthWithHighBitRejectedNotCrashing() {
        // 64-bit length 0x8000_0000_0000_0005: would turn negative as Int.
        var buffer = Data([0x82, 0x7F, 0x80, 0, 0, 0, 0, 0, 0, 0x05, 1, 2, 3, 4, 5])
        #expect(throws: WebSocket.FrameError.tooLarge) { _ = try WebSocket.decodeFrame(from: &buffer) }
    }
}
