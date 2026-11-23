import Foundation

/// The folders a session may be started in from the phone, and whether
/// starting is allowed at all. Kept in a file the command line edits too.
public struct FolderBook: Codable, Equatable, Sendable {
    /// How many folders are remembered.
    public static let limit = 30
    /// Scratch space is not a project.
    static let scratch = ["/tmp", "/private/tmp", "/private/var", "/var/folders"]

    /// Where sessions ran, most recent first.
    private var seen: [String] = []
    /// Added on the Mac by hand.
    private var added: [String] = []
    /// Taken out on the Mac by hand: not offered again until added back.
    private var removed: [String] = []
    /// Off: the phone cannot start sessions.
    public var enabled = true

    public init() {}

    public var folders: [StartFolder] {
        var paths = seen
        for path in added where !paths.contains(path) { paths.append(path) }
        return paths.map { StartFolder(path: $0, name: ($0 as NSString).lastPathComponent) }
    }

    public func allows(_ path: String) -> Bool {
        folders.contains { $0.path == path }
    }

    /// A session ran here.
    public mutating func note(_ cwd: String) {
        guard let path = Self.project(cwd), !removed.contains(path), !added.contains(path) else { return }
        seen.removeAll { $0 == path }
        seen.insert(path, at: 0)
        if seen.count + added.count > Self.limit { seen.removeLast(seen.count + added.count - Self.limit) }
    }

    public mutating func add(_ path: String) {
        guard let path = Self.project(path) else { return }
        removed.removeAll { $0 == path }
        if !seen.contains(path), !added.contains(path) { added.append(path) }
    }

    public mutating func remove(_ path: String) {
        let path = (path as NSString).standardizingPath
        seen.removeAll { $0 == path }
        added.removeAll { $0 == path }
        if !removed.contains(path) { removed.append(path) }
    }

    /// The folder's path in one spelling, or nil when it is no project.
    static func project(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let clean = (path as NSString).standardizingPath
        guard clean != "/", !scratch.contains(where: { clean == $0 || clean.hasPrefix($0 + "/") }) else { return nil }
        return clean
    }

    public static func load(from path: String) -> FolderBook {
        guard let data = FileManager.default.contents(atPath: path),
              let book = try? JSONDecoder().decode(FolderBook.self, from: data) else { return FolderBook() }
        return book
    }

    public func save(to path: String) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

/// Starting a Claude Code session on the Mac at the phone's request.
public enum SessionLaunch {
    public enum Refusal: String, Error, Equatable, Sendable {
        case disabled = "start_disabled"
        case unknownFolder = "start_unknown_folder"
        case emptyPrompt = "start_empty_prompt"
        case tooMany = "start_too_many"
        case failed = "start_failed"
    }

    public struct Request: Equatable, Sendable {
        public let folder: String
        public let prompt: String
        public let name: String?

        public init(folder: String, prompt: String, name: String?) {
            self.folder = folder
            self.prompt = prompt
            self.name = name
        }
    }

    /// How many sessions the phone may start in a minute.
    public static let perMinute = 5

    /// What may be started, or why not. The phone only ever picks a folder
    /// from the list the Mac gave it.
    public static func check(
        folder: String, prompt: String, name: String?, book: FolderBook,
        recent: [Date], now: Date, exists: (String) -> Bool
    ) -> Result<Request, Refusal> {
        guard book.enabled else { return .failure(.disabled) }
        guard book.allows(folder), exists(folder) else { return .failure(.unknownFolder) }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failure(.emptyPrompt) }
        guard recent.filter({ now.timeIntervalSince($0) < 60 }).count < perMinute else { return .failure(.tooMany) }
        return .success(Request(folder: folder, prompt: prompt, name: sessionName(name)))
    }

    /// A name with only what a session name is made of: letters, digits,
    /// spaces, dashes inside it. Nil when nothing is left.
    static func sessionName(_ name: String?) -> String? {
        guard let name else { return nil }
        let kept = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : " " }
        let words = String(kept).split(separator: " ").joined(separator: " ")
        let trimmed = String(words.drop { $0 == "-" || $0 == " " }.prefix(60))
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The `claude` arguments. No permission mode is named: the session
    /// starts in the one any session on this Mac starts in, and the phone
    /// can change it afterwards, to bypass too: the flag puts that mode
    /// within reach and grants nothing by itself. After `--` the prompt
    /// is words, however it begins.
    public static func arguments(for request: Request) -> [String] {
        var arguments = ["--bg", "--allow-dangerously-skip-permissions"]
        if let name = request.name { arguments.append("--name=" + name) }
        return arguments + ["--", request.prompt]
    }

    /// The first place where `claude` is installed.
    public static func claudePath(candidates: [String], isExecutable: (String) -> Bool) -> String? {
        candidates.first(where: isExecutable)
    }

    /// Where to look for `claude`: where the command line last found it,
    /// then where its installers put it.
    public static func claudeCandidates(stateDirectory: String, userHome: String) -> [String] {
        let remembered = (try? String(contentsOfFile: stateDirectory + "/" + claudePathFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [remembered, userHome + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// The environment for `claude --bg`: the daemon's own, with the
    /// PATH the command line remembered put first.
    public static func environment(_ base: [String: String], rememberedPath: String?) -> [String: String] {
        var environment = base
        var seen = Set<String>()
        let folders = ((rememberedPath ?? "") + ":" + (base["PATH"] ?? ""))
            .split(whereSeparator: { $0 == ":" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        if !folders.isEmpty { environment["PATH"] = folders.joined(separator: ":") }
        return environment
    }

    /// Holds the PATH of the last session that started the daemon.
    public static let pathFile = "claude-env-path"

    /// Holds the path of `claude`, written by the command line, which
    /// runs where Claude Code is on the PATH; the daemon does not.
    public static let claudePathFile = "claude-path"
    public static let foldersFile = "folders.json"
}

/// Where the daemon keeps the folder list and starts sessions from. Every
/// call reads the file again: the command line on the Mac edits it too.
public final class LaunchDesk: @unchecked Sendable {
    private let path: String
    private let now: @Sendable () -> Date
    private let exists: @Sendable (String) -> Bool
    private let spawn: @Sendable (SessionLaunch.Request) throws -> Void
    private let lock = NSLock()
    private var recent: [Date] = []
    /// The folders already written down in this run: sessions report
    /// themselves many times a minute, the file is touched once each.
    private var noted: Set<String> = []

    public init(
        path: String, now: @escaping @Sendable () -> Date = { Date() },
        exists: @escaping @Sendable (String) -> Bool,
        spawn: @escaping @Sendable (SessionLaunch.Request) throws -> Void
    ) {
        self.path = path
        self.now = now
        self.exists = exists
        self.spawn = spawn
    }

    /// A session ran in this folder.
    public func note(cwd: String) {
        lock.withLock {
            guard noted.insert(cwd).inserted else { return }
            var book = FolderBook.load(from: path)
            let before = book
            book.note(cwd)
            if book != before { try? book.save(to: path) }
        }
    }

    public func folders() -> (items: [StartFolder], enabled: Bool) {
        let book = lock.withLock { FolderBook.load(from: path) }
        return (book.enabled ? book.folders.filter { exists($0.path) } : [], book.enabled)
    }

    /// Starts a session, or says why not.
    public func start(folder: String, prompt: String, name: String?) -> SessionLaunch.Refusal? {
        lock.withLock {
            let checked = SessionLaunch.check(
                folder: folder, prompt: prompt, name: name, book: FolderBook.load(from: path),
                recent: recent, now: now(), exists: exists)
            switch checked {
            case let .failure(refusal):
                return refusal
            case let .success(request):
                do {
                    try spawn(request)
                } catch {
                    return .failed
                }
                recent = recent.filter { now().timeIntervalSince($0) < 60 } + [now()]
                return nil
            }
        }
    }
}
