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
let hub = Hub { relay.forward($0) }
let store = PairingStore(directory: home)
let router = PhoneRouter(hub: hub) { session, text in try InboxInjector.inject(text: text, into: session) }
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
dispatchMain()
