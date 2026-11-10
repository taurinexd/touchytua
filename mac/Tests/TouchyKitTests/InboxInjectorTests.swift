import Foundation
import Testing
@testable import TouchyKit

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
        let session = Session(id: "s1", title: "t", cwd: "/", state: .done, lastEventAt: Date(),
                              inboxSocket: path, inboxToken: "tok\"x")
        try InboxInjector.inject(text: "ciao \"mondo\"\nriga 2", into: session)
        let lines = await server.value.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let auth = try JSONDecoder().decode([String: String].self, from: Data(lines[0].utf8))
        #expect(auth == ["type": "auth", "token": "tok\"x"])
        let user = try JSONDecoder().decode([String: JSONValue].self, from: Data(lines[1].utf8))
        #expect(user["type"] == .string("user"))
        #expect(user["message"] == .object(["role": .string("user"), "content": .string("ciao \"mondo\"\nriga 2")]))
    }

    @Test func noInboxThrows() {
        let session = Session(id: "s1", title: "t", cwd: "/", state: .done, lastEventAt: Date())
        #expect(throws: InboxInjector.Failure.noInbox) { try InboxInjector.inject(text: "x", into: session) }
    }

    @Test func deadSocketThrowsConnectFailed() {
        let session = Session(id: "s1", title: "t", cwd: "/", state: .done, lastEventAt: Date(),
                              inboxSocket: "/tmp/does-not-exist-\(getpid()).sock", inboxToken: "t")
        #expect(throws: InboxInjector.Failure.connectFailed) { try InboxInjector.inject(text: "x", into: session) }
    }
}
