import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

/// Minimal one-shot Unix socket server: returns everything the client sent.
private func captureOne(at path: String) -> Task<String, Never> {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) } }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    listen(fd, 1)
    return Task.detached {
        let c = accept(fd, nil, nil)
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(c, &buf, buf.count); if n <= 0 { break }; data.append(contentsOf: buf[0..<n]) }
        close(c); close(fd)
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite struct InboxInjectorTests {
    @Test func writesAuthThenUserLine() async throws {
        let path = NSTemporaryDirectory() + "tt-inj-\(getpid()).sock"
        let server = captureOne(at: path)
        try InboxInjector.inject(text: "ciao \"mondo\"\nriga 2", into: InboxCredentials(socket: path, token: "tok\"x"))
        let lines = await server.value.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let auth = try JSONDecoder().decode([String: String].self, from: Data(lines[0].utf8))
        #expect(auth == ["type": "auth", "token": "tok\"x"])
        let user = try JSONDecoder().decode([String: JSONValue].self, from: Data(lines[1].utf8))
        #expect(user["type"] == .string("user"))
        #expect(user["message"] == .object([
            "role": .string("user"), "content": .string(PhonePrompt.wrapped("ciao \"mondo\"\nriga 2"))]))
        // Who it is from, and an id of its own: with these Claude Code
        // shows it as a message from a session it knows by name.
        #expect(user["from"] == .string("touchytua"))
        #expect(user["msg_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
    }

    @Test func deadSocketThrowsConnectFailed() {
        let inbox = InboxCredentials(socket: "/tmp/does-not-exist-\(getpid()).sock", token: "t")
        #expect(throws: InboxInjector.Failure.connectFailed) { try InboxInjector.inject(text: "x", into: inbox) }
    }

    /// Liveness probe for sessions that ended without SessionEnd.
    @Test func reachabilityFollowsTheSocket() async {
        let path = NSTemporaryDirectory() + "tt-live-\(getpid()).sock"
        let server = captureOne(at: path)
        let inbox = InboxCredentials(socket: path, token: "t")
        #expect(InboxInjector.isReachable(inbox))
        _ = await server.value
        #expect(!InboxInjector.isReachable(inbox))
    }
}
