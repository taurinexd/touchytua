import Foundation
import TouchyKit

// touchytuad — the touchytua background daemon. One per user, enforced by
// an exclusive lock: a second copy exits 0 so `--ensure` style launches are
// harmless.

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

    func forward(_ change: Hub.Change) {
        switch change {
        case let .session(s):
            Log.info("session \(s.id.prefix(8)) \(s.state.rawValue) \"\(s.title.prefix(40))\"")
            phone?.push(.session(s))
        case let .sessionRemoved(id):
            Log.info("session \(id.prefix(8)) removed")
            phone?.push(.sessionRemoved(id: id))
        case let .pending(.opened(r)):
            Log.info("request \(r.id) opened: \(r.kind.rawValue) \(r.toolName) (session \(r.sessionId.prefix(8)))")
            phone?.push(.request(r))
        case let .pending(.resolved(id, by)):
            Log.info("request \(id) resolved by \(by.rawValue)")
            phone?.push(.requestResolved(id: id, by: by))
        case let .usage(u):
            phone?.push(.usage(u))
        }
    }
}

let relay = ChangeRelay()
let sessionStore = SessionStore(path: runDir + "/sessions.json")
let hub = Hub(onChange: { relay.forward($0) }, persist: { sessionStore.save($0) })
let store = PairingStore(directory: home)
let router = PhoneRouter(hub: hub) { inbox, text in try InboxInjector.inject(text: text, into: inbox) }
let phoneServer = PhoneServer(store: store, router: router, macName: Host.current().localizedName ?? "Mac")
relay.phone = phoneServer

let hookServer = HookServer(path: env["TOUCHYTUA_HOOK_SOCKET"] ?? runDir + "/hook.sock", hub: hub)
do {
    try hookServer.start()
    try phoneServer.start(port: env["TOUCHYTUA_PORT"].flatMap(UInt16.init) ?? PhoneServer.port)
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
    await hub.restore(sessionStore.load())
    while true {
        await hub.reap { InboxInjector.isReachable($0) }
        try? await Task.sleep(nanoseconds: UInt64(reapSeconds * 1e9))
    }
}
dispatchMain()
