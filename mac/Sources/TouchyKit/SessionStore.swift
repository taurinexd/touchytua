import Foundation

/// The session registry on disk (mode 0600: it holds inbox credentials),
/// so a restarted daemon still knows the sessions that are idle and will
/// not announce themselves again.
public struct SessionStore: Sendable {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    public func load() -> [Session] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([Session].self, from: data)) ?? []
    }

    public func save(_ sessions: [Session]) {
        guard let data = try? JSONEncoder().encode(sessions.sorted { $0.id < $1.id }) else { return }
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp, path) != 0 { unlink(tmp) }
    }
}
