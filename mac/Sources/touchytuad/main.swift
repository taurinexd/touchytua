import Foundation
import TouchyKit

// touchytuad — the touchytua background daemon. One per user, enforced by
// an exclusive lock: a second copy exits 0 so `--ensure` style launches are
// harmless.

// A write to something that closed must fail with EPIPE, never end the
// daemon: every socket carries SO_NOSIGPIPE, this covers whatever does not.
// A handler, not SIG_IGN: handlers go back to the default in the sessions
// started from here, an ignored signal would be inherited by them.
signal(SIGPIPE) { _ in }

let env = ProcessInfo.processInfo.environment
let home = env["TOUCHYTUA_HOME"] ?? (NSHomeDirectory() + "/.touchytua")
let runDir = home + "/run"
try? FileManager.default.createDirectory(
    atPath: runDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

let lockFD = open(runDir + "/daemon.lock", O_CREAT | O_RDWR, 0o600)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    Log.info("another touchytuad is running; exiting")
    exit(0)
}
ftruncate(lockFD, 0)
_ = "\(getpid())\n".withCString { write(lockFD, $0, strlen($0)) }

/// Hub changes go to the log and to the phone; the phone server is created
/// after the hub, hence the late-bound box.
final class ChangeRelay: @unchecked Sendable {
    var phone: PhoneServer?

    var desk: LaunchDesk?

    func forward(_ change: Hub.Change) {
        switch change {
        case let .session(s):
            Log.info("session \(s.id.prefix(8)) \(s.state.rawValue) \"\(s.title.prefix(40))\"")
            // Where a session ran, another can be started from the phone.
            desk?.note(cwd: s.cwd)
        case let .sessionRemoved(id):
            Log.info("session \(id.prefix(8)) removed")
        case let .pending(.opened(r)):
            Log.info("request \(r.id) opened: \(r.kind.rawValue) \(r.toolName) (session \(r.sessionId.prefix(8)))")
        case let .pending(.resolved(id, by)):
            Log.info("request \(id) resolved by \(by.rawValue)")
        case .usage:
            break
        }
        phone?.push(PhoneRouter.message(for: change))
    }
}

let relay = ChangeRelay()
let sessionStore = SessionStore(path: runDir + "/sessions.json")
// Read before the hook socket opens: the first event to come in saves a
// registry of its own, and a hook held back by a restart comes in at once.
let savedSessions = sessionStore.load()
let hub = Hub(
    onChange: { relay.forward($0) }, persist: { sessionStore.save($0) },
    tasks: { session in
        // Claude Code keeps the lists under the person's home; a test points elsewhere.
        TaskList.directory(sessionId: session, userHome: env["TOUCHYTUA_USER_HOME"] ?? NSHomeDirectory())
            .map(TaskList.read(directory:)) ?? []
    })
let store = PairingStore(directory: home)
// Sessions started from the phone: `claude --bg` in a folder from the list,
// with the daemon's own environment. It hands the session to Claude Code's
// background supervisor and returns.
let desk = LaunchDesk(
    path: home + "/" + SessionLaunch.foldersFile,
    exists: { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    },
    spawn: { request in
        let candidates = [env["TOUCHYTUA_CLAUDE"]].compactMap { $0 }
            + SessionLaunch.claudeCandidates(stateDirectory: home, userHome: NSHomeDirectory())
        guard let claude = SessionLaunch.claudePath(
            candidates: candidates, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            Log.info("start refused: claude not found")
            throw SessionLaunch.Refusal.failed
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = SessionLaunch.arguments(for: request)
        process.currentDirectoryURL = URL(fileURLWithPath: request.folder)
        // Claude Code hands a background session the PATH it was started
        // with: without the terminal's, MCP servers and tools are not found.
        process.environment = SessionLaunch.environment(
            env, rememberedPath: try? String(contentsOfFile: home + "/" + SessionLaunch.pathFile, encoding: .utf8))
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 { Log.info("claude --bg exited with status \(finished.terminationStatus)") }
        }
        try process.run()
        Log.info("session started from the phone in \((request.folder as NSString).lastPathComponent)")
    })
relay.desk = desk
let phonePort = env["TOUCHYTUA_PORT"].flatMap(UInt16.init) ?? PhoneServer.port
let router = PhoneRouter(
    hub: hub, inject: { inbox, text in try InboxInjector.inject(text: text, into: inbox) },
    folders: { desk.folders() }, start: { desk.start(folder: $0, prompt: $1, name: $2) },
    addresses: {
        let tailscale = Setup.tailscale()
        let addresses = Setup.endpoints(lanIP: Setup.lanIPv4(), tailscaleName: tailscale.name, port: phonePort)
        // Kinds only: the addresses themselves stay out of the log.
        var told = addresses.map { String($0.prefix { $0 != ":" }) }.joined(separator: ", ")
        if case let .missing(why) = tailscale { told += "; Tailscale \(why)" }
        Log.info("phone: told where the Mac listens now (\(told))")
        return addresses
    })
let phoneServer = PhoneServer(store: store, router: router, macName: Host.current().localizedName ?? "Mac")
relay.phone = phoneServer

let hookSocket = env["TOUCHYTUA_HOOK_SOCKET"] ?? runDir + "/hook.sock"
let hookServer = HookServer(path: hookSocket, hub: hub)
do {
    try hookServer.start()
    // Hooks held back by a restart may come in now.
    try? FileManager.default.removeItem(
        atPath: (hookSocket as NSString).deletingLastPathComponent + "/" + Setup.restartMarkerName)
    try phoneServer.start(port: phonePort)
} catch {
    Log.info("cannot start: \(error)")
    exit(1)
}
// Bring back the registry of the previous run, then keep dropping the
// sessions that ended without a SessionEnd (crash, kill, closed terminal):
// they stop answering on their inbox socket.
// A Task, not a DispatchSource timer: top-level code is main-actor
// isolated, and a handler running on another queue traps at runtime.
let reapSeconds = env["TOUCHYTUA_REAP_SECONDS"].flatMap(Double.init) ?? 60
Task {
    await hub.restore(savedSessions)
    // Restored sessions send no event: their folders are offered too.
    for session in await hub.sessions.values { desk.note(cwd: session.cwd) }
    while true {
        await hub.reap { InboxInjector.isReachable($0) }
        try? await Task.sleep(nanoseconds: UInt64(reapSeconds * 1e9))
    }
}
dispatchMain()
