import Foundation

/// Delivers a prompt to a Claude Code session through its inbox socket:
/// an auth line with the session's token, then a user line (phase-0 T1).
/// Claude Code presents it as a message from another session; callers add
/// `PhoneRouter.promptPrefix`.
public enum InboxInjector {
    public enum Failure: Error, Equatable { case connectFailed }

    /// Whether the session's inbox socket still accepts connections: false
    /// means the session is gone (a crashed process leaves its socket file
    /// behind, but nothing listens on it).
    /// Claude Code accepts and later drops a connection that sends nothing.
    public static func isReachable(_ inbox: InboxCredentials) -> Bool {
        guard let fd = connectedSocket(inbox.socket) else { return false }
        close(fd)
        return true
    }

    private static func connectedSocket(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    public static func inject(text: String, into inbox: InboxCredentials) throws {
        let auth: JSONValue = .object(["type": .string("auth"), "token": .string(inbox.token)])
        let user: JSONValue = .object([
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .string(text)]),
        ])
        let encoder = JSONEncoder()
        var payload = try encoder.encode(auth)
        payload.append(0x0A)
        payload.append(try encoder.encode(user))
        payload.append(0x0A)

        guard let fd = connectedSocket(inbox.socket) else { throw Failure.connectFailed }
        defer { close(fd) }
        // Both lines in one write: Claude Code closes a connection that sends
        // no complete line within its first-line deadline.
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw Failure.connectFailed }
    }
}
