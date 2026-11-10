import Foundation

/// Delivers a prompt to a Claude Code session through its inbox socket:
/// an auth line with the session's token, then a user line (phase-0 T1).
/// Claude Code presents it as a message from another session; callers add
/// `PhoneRouter.promptPrefix`.
public enum InboxInjector {
    public enum Failure: Error, Equatable { case noInbox, connectFailed }

    public static func inject(text: String, into session: Session) throws {
        guard let path = session.inboxSocket, let token = session.inboxToken else { throw Failure.noInbox }
        let auth: JSONValue = .object(["type": .string("auth"), "token": .string(token)])
        let user: JSONValue = .object([
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .string(text)]),
        ])
        let encoder = JSONEncoder()
        var payload = try encoder.encode(auth)
        payload.append(0x0A)
        payload.append(try encoder.encode(user))
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.connectFailed }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.connectFailed }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.connectFailed }
        // Both lines in one write: Claude Code closes a connection that sends
        // no complete line within its first-line deadline.
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw Failure.connectFailed }
    }
}
