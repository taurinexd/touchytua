import Foundation

// touchytua-hook — invoked by the touchytua plugin's Claude Code hooks.
// Reads the hook payload from stdin, wraps it in an envelope, sends it to
// the daemon's Unix socket and prints the daemon's reply (nothing when the
// reply is `{}`). Exits 0 in every failure mode: a missing or busy daemon
// must never slow down or break Claude Code.
// Ported from Meowtch's vedetta-bridge (MIT, same author), without the
// terminal-identity capture.

let env = ProcessInfo.processInfo.environment
let socketPath = env["TOUCHYTUA_HOOK_SOCKET"]
    ?? (NSHomeDirectory() + "/.touchytua/run/hook.sock")

// 1. Read the hook payload.
let input = FileHandle.standardInput.readDataToEndOfFile()
let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]

// 2. Build the envelope. Inbox credentials travel with every event: a
//    daemon restarted mid-session never sees that session's SessionStart
//    again. They stay on this user's 0600 Unix socket.
var envelope: [String: Any] = [
    "v": 1,
    "capturedAt": Date().timeIntervalSince1970,
    "event": payload,
]
if let socket = env["CLAUDE_CODE_MESSAGING_SOCKET"], !socket.isEmpty {
    envelope["messagingSocket"] = socket
}
if let token = env["CLAUDE_CODE_MESSAGING_TOKEN"], !token.isEmpty {
    envelope["messagingToken"] = token
}
guard var data = try? JSONSerialization.data(withJSONObject: envelope) else { exit(0) }
data.append(0x0A)

// 3. Connect. A Unix socket connect succeeds or fails immediately.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = socketPath.utf8CString
guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
}
let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { exit(0) }

// 4. Send, half-close, wait for one reply line. No read timeout: for
//    permission requests the daemon holds the line until the phone (or the
//    terminal) decides; Claude Code's own hook timeout is the cap.
data.withUnsafeBytes { raw in _ = write(fd, raw.baseAddress, raw.count) }
shutdown(fd, SHUT_WR)

var reply = Data()
var chunk = [UInt8](repeating: 0, count: 64 << 10)
while true {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    reply.append(contentsOf: chunk[0..<n])
    if chunk[0..<n].contains(0x0A) { break }
}
close(fd)

// 5. Relay a non-trivial reply as the hook's JSON output.
if let newline = reply.firstIndex(of: 0x0A) { reply = reply.prefix(upTo: newline) }
if reply.count > 2 { FileHandle.standardOutput.write(reply) }
exit(0)
