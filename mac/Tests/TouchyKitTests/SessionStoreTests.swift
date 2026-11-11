import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

@Suite struct SessionStoreTests {
    private func tempPath() -> String {
        let d = NSTemporaryDirectory() + "tt-store-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d + "/sessions.json"
    }

    /// The registry survives a daemon restart, inbox credentials included:
    /// an idle session sends no event that could re-announce it.
    @Test func roundTripsSessionsWithCredentialsIn0600() {
        let path = tempPath()
        let store = SessionStore(path: path)
        let s = Session(id: "s1", title: "t", cwd: "/p", state: .done,
                        round: Round(startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 20), tokens: 5, summary: "ok"),
                        lastEventAt: Date(timeIntervalSince1970: 20))
        let stored = StoredSession(session: s, inbox: InboxCredentials(socket: "/tmp/x.sock", token: "tok"))
        store.save([stored])
        #expect(store.load() == [stored])
        let mode = ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int) ?? -1
        #expect(mode == 0o600)
    }

    @Test func missingOrCorruptFileLoadsEmpty() {
        let path = tempPath()
        #expect(SessionStore(path: path).load().isEmpty)
        try? Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        #expect(SessionStore(path: path).load().isEmpty)
    }

    @Test func hubRestoresSavedSessionsWithoutOverwritingLiveOnes() async {
        let hub = Hub()
        _ = await hub.handle(HookEnvelope(v: 1, capturedAt: 50, event: [
            "hook_event_name": .string("UserPromptSubmit"), "session_id": .string("live"), "cwd": .string("/p/app")]))
        let saved = [
            StoredSession(session: Session(id: "live", title: "stale", cwd: "/p", state: .done, lastEventAt: Date(timeIntervalSince1970: 1)),
                          inbox: InboxCredentials(socket: "/tmp/old.sock", token: "old")),
            StoredSession(session: Session(id: "idle", title: "idle", cwd: "/p", state: .done, lastEventAt: Date(timeIntervalSince1970: 2)),
                          inbox: InboxCredentials(socket: "/tmp/i.sock", token: "tok")),
        ]
        await hub.restore(saved)
        #expect(await hub.sessions["live"]?.state == .working)
        #expect(await hub.inbox["live"] == nil)
        #expect(await hub.sessions["idle"]?.title == "idle")
        #expect(await hub.inbox["idle"]?.token == "tok")
    }

    @Test func hubPersistsOnVisibleChangesOnly() async {
        let path = tempPath()
        let store = SessionStore(path: path)
        let hub = Hub(persist: { store.save($0) })
        func event(_ name: String, at: Double) -> HookEnvelope {
            HookEnvelope(v: 1, capturedAt: at, event: [
                "hook_event_name": .string(name), "session_id": .string("s1"), "cwd": .string("/p/app")],
                         messagingSocket: "/tmp/a.sock", messagingToken: "tok")
        }
        _ = await hub.handle(event("UserPromptSubmit", at: 1))
        #expect(store.load().first?.inbox?.token == "tok")
        let written = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        _ = await hub.handle(event("PreToolUse", at: 2))
        #expect((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) == written)
        _ = await hub.handle(event("SessionEnd", at: 3))
        #expect(store.load().isEmpty)
    }
}
