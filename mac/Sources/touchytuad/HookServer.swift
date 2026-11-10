import Foundation
import TouchyKit

/// Accepts `touchytua-hook` connections on a Unix socket: one envelope line
/// in, one reply line out. Permission requests keep their connection open
/// until the hub settles them.
final class HookServer: @unchecked Sendable {
    private let path: String
    private let hub: Hub
    private var listenFD: Int32 = -1

    init(path: String, hub: Hub) {
        self.path = path
        self.hub = hub
    }

    func start() throws {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        guard listen(listenFD, 64) == 0 else { throw POSIXError(.EIO) }
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "touchytua.hook-accept"
        thread.start()
        Log.info("hook socket listening: \(path)")
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            let hub = self.hub
            Thread.detachNewThread {
                guard let line = Self.readAll(fd),
                      let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: line) else {
                    close(fd)
                    return
                }
                Task {
                    let reply = await hub.handle(envelope)
                    reply.withUnsafeBytes { raw in _ = write(fd, raw.baseAddress, raw.count) }
                    close(fd)
                }
            }
        }
    }

    /// Reads until the hook half-closes its side. Capped at 4 MiB.
    private static func readAll(_ fd: Int32) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while data.count < 4 << 20 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        return data.isEmpty ? nil : data
    }
}

enum Log {
    static func info(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
    }
}
