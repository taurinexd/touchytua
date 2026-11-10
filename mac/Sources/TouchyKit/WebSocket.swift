import CryptoKit
import Foundation

/// Minimal RFC 6455 server side: upgrade handshake and unfragmented frames.
/// Exists because NWListener connections on the Tailscale interface never
/// complete (see ledger, Task 11); the daemon serves over BSD sockets.
public enum WebSocket {
    public struct Frame: Equatable, Sendable {
        public let opcode: UInt8
        public let payload: Data
    }

    public enum FrameError: Error, Equatable { case unsupported, tooLarge }

    public static let opText: UInt8 = 0x1, opBinary: UInt8 = 0x2, opClose: UInt8 = 0x8,
                      opPing: UInt8 = 0x9, opPong: UInt8 = 0xA
    static let maxPayload = 4 << 20
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public static func acceptKey(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
    }

    /// The `Sec-WebSocket-Key` of a complete upgrade request, nil otherwise.
    public static func upgradeKey(fromRequest data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n"),
              text.hasPrefix("GET ") else { return nil }
        var key: String?, upgrade = false
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "sec-websocket-key" { key = value }
            if name == "upgrade", value.lowercased() == "websocket" { upgrade = true }
        }
        return upgrade ? key : nil
    }

    public static func handshakeResponse(key: String) -> Data {
        Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              + "Sec-WebSocket-Accept: \(acceptKey(for: key))\r\n\r\n").utf8)
    }

    /// Server → client frame: FIN set, unmasked.
    public static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode])
        switch payload.count {
        case ..<126: out.append(UInt8(payload.count))
        case ..<65536: out.append(126); out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
        default:
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        out.append(payload)
        return out
    }

    /// Removes and returns one complete frame from `buffer`; nil when more bytes are needed.
    public static func decodeFrame(from buffer: inout Data) throws -> Frame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        guard bytes[0] & 0x80 != 0 else { throw FrameError.unsupported }  // no fragmentation
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            // Unsigned arithmetic: a length with the high bit set must be
            // rejected as too large, not wrap to a negative Int.
            let wide = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard wide <= UInt64(maxPayload) else { throw FrameError.tooLarge }
            length = Int(wide); offset = 10
        }
        guard length <= maxPayload else { throw FrameError.tooLarge }
        let maskLength = masked ? 4 : 0
        guard bytes.count >= offset + maskLength + length else { return nil }
        let mask = masked ? Array(bytes[offset..<offset + 4]) : []
        offset += maskLength
        var payload = Array(bytes[offset..<offset + length])
        if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
        buffer.removeFirst(offset + length)
        return Frame(opcode: opcode, payload: Data(payload))
    }
}
