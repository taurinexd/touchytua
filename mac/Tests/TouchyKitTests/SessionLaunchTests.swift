import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

@Suite struct FolderBookTests {
    @Test func foldersWhereSessionsRanAreOfferedMostRecentFirst() {
        var book = FolderBook()
        book.note("/p/shop")
        book.note("/p/blog/")
        book.note("/p/shop")
        #expect(book.folders.map(\.path) == ["/p/shop", "/p/blog"])
        #expect(book.folders.first?.name == "shop")
    }

    @Test func aFolderCanBeAddedByHand() {
        var book = FolderBook()
        book.note("/p/shop")
        book.add("/p/new-idea")
        #expect(book.folders.map(\.path) == ["/p/shop", "/p/new-idea"])
        #expect(book.allows("/p/new-idea"))
    }

    @Test func aFolderTakenOutIsNotOfferedAgain() {
        var book = FolderBook()
        book.note("/p/shop")
        book.remove("/p/shop")
        book.note("/p/shop")
        #expect(book.folders.isEmpty)
        #expect(!book.allows("/p/shop"))
        book.add("/p/shop")
        #expect(book.allows("/p/shop"))
    }

    @Test func onlyRealProjectFoldersAreKept() {
        var book = FolderBook()
        for path in ["", "/", "relative/path", "/private/tmp/scratch", "/tmp/x", "/var/folders/ab/T/x"] { book.note(path) }
        #expect(book.folders.isEmpty)
    }

    @Test func theListDoesNotGrowWithoutEnd() {
        var book = FolderBook()
        for index in 0..<60 { book.note("/p/project-\(index)") }
        #expect(book.folders.count == FolderBook.limit)
        #expect(book.folders.first?.path == "/p/project-59")
    }

    @Test func itSurvivesOnDisk() throws {
        let path = NSTemporaryDirectory() + "tt-folders-" + UUID().uuidString + ".json"
        var book = FolderBook()
        book.note("/p/shop")
        book.enabled = false
        try book.save(to: path)
        #expect(FolderBook.load(from: path) == book)
        #expect(FolderBook.load(from: path + ".missing") == FolderBook())
    }
}

@Suite struct SessionLaunchTests {
    private var book: FolderBook {
        var book = FolderBook()
        book.note("/p/shop")
        return book
    }

    private func check(
        folder: String = "/p/shop", prompt: String = "Fix the cart", name: String? = nil,
        book: FolderBook? = nil, recent: [Date] = [], exists: Bool = true
    ) -> Result<SessionLaunch.Request, SessionLaunch.Refusal> {
        SessionLaunch.check(
            folder: folder, prompt: prompt, name: name, book: book ?? self.book,
            recent: recent, now: Date(timeIntervalSince1970: 1000)) { _ in exists }
    }

    @Test func aKnownFolderAndAPromptStartASession() {
        #expect(check(prompt: "  Fix the cart\n", name: " cart fix ") == .success(
            .init(folder: "/p/shop", prompt: "Fix the cart", name: "cart fix")))
    }

    /// The phone picks from the list the Mac gave it: it cannot name a path.
    @Test func aFolderNotOnTheListIsRefused() {
        #expect(check(folder: "/etc") == .failure(.unknownFolder))
        #expect(check(folder: "/p/shop/../../etc") == .failure(.unknownFolder))
    }

    @Test func aFolderThatIsGoneIsRefused() {
        #expect(check(exists: false) == .failure(.unknownFolder))
    }

    @Test func anEmptyPromptIsRefused() {
        #expect(check(prompt: " \n ") == .failure(.emptyPrompt))
    }

    @Test func startingIsRefusedWhenSwitchedOffOnTheMac() {
        var off = book
        off.enabled = false
        #expect(check(book: off) == .failure(.disabled))
    }

    @Test func tooManyStartsInAMinuteAreRefused() {
        let now = Date(timeIntervalSince1970: 1000)
        let busy = (0..<SessionLaunch.perMinute).map { now.addingTimeInterval(-Double($0) * 5) }
        #expect(check(recent: busy) == .failure(.tooMany))
        #expect(check(recent: busy.map { $0.addingTimeInterval(-120) }) != .failure(.tooMany))
    }

    @Test func aNameIsKeptToWhatASessionNameCanBe() {
        guard case let .success(request) = check(name: "--dangerously\nskip: permissions! " + String(repeating: "x", count: 80)) else {
            Issue.record("expected a request")
            return
        }
        #expect(request.name?.hasPrefix("dangerously skip permissions") == true)
        #expect((request.name?.count ?? 0) <= 60)
        #expect(check(name: " -- ") == .success(.init(folder: "/p/shop", prompt: "Fix the cart", name: nil)))
    }

    /// The session asks for permissions, whatever the Mac's own default
    /// is, and neither the name nor the prompt can pass for an option.
    @Test func theCommandAsksForPermissionsAndTakesThePromptAsWords() {
        let named = SessionLaunch.arguments(for: .init(folder: "/p/shop", prompt: "--version", name: "cart fix"))
        #expect(named == ["--bg", "--permission-mode", "default", "--name=cart fix", "--", "--version"])
        let bare = SessionLaunch.arguments(for: .init(folder: "/p/shop", prompt: "Fix the cart", name: nil))
        #expect(bare == ["--bg", "--permission-mode", "default", "--", "Fix the cart"])
    }

    @Test func claudeIsLookedForWhereItIsInstalled() {
        let found = SessionLaunch.claudePath(candidates: ["/a/claude", "/b/claude", "/c/claude"]) { $0 == "/b/claude" || $0 == "/c/claude" }
        #expect(found == "/b/claude")
        #expect(SessionLaunch.claudePath(candidates: ["/a/claude"]) { _ in false } == nil)
    }
}

@Suite struct LaunchDeskTests {
    private final class Spawned: @unchecked Sendable {
        var requests: [SessionLaunch.Request] = []
        var fails = false
    }

    private func desk(_ spawned: Spawned, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1000) }) -> LaunchDesk {
        LaunchDesk(path: NSTemporaryDirectory() + "tt-desk-" + UUID().uuidString + ".json", now: now, exists: { _ in true }) { request in
            if spawned.fails { throw SessionLaunch.Refusal.failed }
            spawned.requests.append(request)
        }
    }

    @Test func aSessionIsStartedInAFolderWhereOneRan() {
        let spawned = Spawned()
        let desk = desk(spawned)
        desk.note(cwd: "/p/shop")
        #expect(desk.folders().items.map(\.path) == ["/p/shop"])
        #expect(desk.start(folder: "/p/shop", prompt: "Fix the cart", name: nil) == nil)
        #expect(spawned.requests == [.init(folder: "/p/shop", prompt: "Fix the cart", name: nil)])
    }

    @Test func aRefusalStartsNothing() {
        let spawned = Spawned()
        let desk = desk(spawned)
        #expect(desk.start(folder: "/p/shop", prompt: "Fix the cart", name: nil) == .unknownFolder)
        #expect(spawned.requests.isEmpty)
    }

    @Test func aSessionThatCannotBeStartedIsReported() {
        let spawned = Spawned()
        spawned.fails = true
        let desk = desk(spawned)
        desk.note(cwd: "/p/shop")
        #expect(desk.start(folder: "/p/shop", prompt: "Fix the cart", name: nil) == .failed)
    }

    @Test func startsAreCountedAgainstTheLimit() {
        let spawned = Spawned()
        let desk = desk(spawned)
        desk.note(cwd: "/p/shop")
        for _ in 0..<SessionLaunch.perMinute { #expect(desk.start(folder: "/p/shop", prompt: "Go", name: nil) == nil) }
        #expect(desk.start(folder: "/p/shop", prompt: "Go", name: nil) == .tooMany)
        #expect(spawned.requests.count == SessionLaunch.perMinute)
    }

    /// The command line on the Mac edits the same file: what it changes
    /// counts at once, without restarting the daemon.
    @Test func changesMadeOnTheMacCountAtOnce() throws {
        let spawned = Spawned()
        let path = NSTemporaryDirectory() + "tt-desk-" + UUID().uuidString + ".json"
        let desk = LaunchDesk(path: path, now: { Date(timeIntervalSince1970: 1000) }, exists: { _ in true }) { spawned.requests.append($0) }
        desk.note(cwd: "/p/shop")
        var book = FolderBook.load(from: path)
        book.enabled = false
        try book.save(to: path)
        #expect(desk.folders().enabled == false)
        #expect(desk.start(folder: "/p/shop", prompt: "Go", name: nil) == .disabled)
    }
}
