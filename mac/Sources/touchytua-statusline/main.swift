import Foundation

// touchytua-statusline — opt-in chained statusline. Forwards Claude Code's
// statusline JSON (cost, rate limits) to the daemon, then runs the user's
// previous statusline command with the same input and prints its output
// unchanged. Never fails the statusline: errors only skip the forwarding.

let env = ProcessInfo.processInfo.environment
let home = env["TOUCHYTUA_HOME"] ?? (NSHomeDirectory() + "/.touchytua")
let input = FileHandle.standardInput.readDataToEndOfFile()

// 1. Forward to the daemon (best effort, non-blocking connect on a Unix socket).
if let statusline = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
    let envelope: [String: Any] = [
        "v": 1,
        "capturedAt": Date().timeIntervalSince1970,
        "event": [
            "hook_event_name": "touchytua_usage",
            "session_id": statusline["session_id"] as? String ?? "unknown",
            "statusline": statusline,
        ],
    ]
    if var data = try? JSONSerialization.data(withJSONObject: envelope) {
        data.append(0x0A)
        forward(data, to: home + "/run/hook.sock")
    }
}

// 2. Run the previous statusline with the same stdin; relay its stdout.
if let record = FileManager.default.contents(atPath: home + "/statusline-previous.json"),
   let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
   let command = (object["previous"] as? [String: Any])?["command"] as? String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    if (try? process.run()) != nil {
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        FileHandle.standardOutput.write(output)
    }
}
exit(0)

func forward(_ data: Data, to path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return }
    data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    shutdown(fd, SHUT_WR)
    var buffer = [UInt8](repeating: 0, count: 256)
    _ = read(fd, &buffer, buffer.count)  // daemon answers `{}` at once
}
