import Foundation
import Testing
@testable import TouchyKit
@testable import TouchyProtocol

@Suite struct ActivityTests {
    @Test func aCommandIsNamedByItsOwnDescription() {
        #expect(Activity.line(tool: "Bash", input: ["command": .string("swift test"), "description": .string("Run the test suite")]) == "Run the test suite")
        #expect(Activity.line(tool: "Bash", input: ["command": .string("ls")]) == "Running a command")
    }

    @Test func aFileIsNamedWithoutItsFolders() {
        #expect(Activity.line(tool: "Read", input: ["file_path": .string("/p/shop/Sources/Cart.swift")]) == "Reading Cart.swift")
        #expect(Activity.line(tool: "Edit", input: ["file_path": .string("/p/shop/Cart.swift")]) == "Editing Cart.swift")
        #expect(Activity.line(tool: "Write", input: ["file_path": .string("/p/shop/README.md")]) == "Writing README.md")
        #expect(Activity.line(tool: "Read", input: [:]) == "Reading a file")
    }

    @Test func searchesAndTheWebAreNamedPlainly() {
        #expect(Activity.line(tool: "Grep", input: ["pattern": .string("TODO")]) == "Searching the code")
        #expect(Activity.line(tool: "Glob", input: ["pattern": .string("**/*.swift")]) == "Searching the code")
        #expect(Activity.line(tool: "WebSearch", input: ["query": .string("x")]) == "Searching the web")
        #expect(Activity.line(tool: "WebFetch", input: ["url": .string("https://docs.example.com/a/b?c=1")]) == "Reading docs.example.com")
    }

    @Test func anAgentIsNamedByItsTask() {
        #expect(Activity.line(tool: "Agent", input: ["description": .string("Review the diff")]) == "Review the diff")
        #expect(Activity.line(tool: "Agent", input: [:]) == "Running an agent")
    }

    @Test func aConnectorIsNamedByItsServer() {
        #expect(Activity.line(tool: "mcp__claude_ai_Docs__update", input: [:]) == "Using claude ai Docs")
        #expect(Activity.line(tool: "Skill", input: ["skill": .string("code-review")]) == "Using code-review")
        #expect(Activity.line(tool: "LSP", input: [:]) == "Using LSP")
    }

    @Test func bookkeepingSaysNothing() {
        for tool in ["TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TodoWrite", "AskUserQuestion"] {
            #expect(Activity.line(tool: tool, input: [:]) == nil)
        }
    }

    @Test func aLongDescriptionIsCut() {
        let line = Activity.line(tool: "Bash", input: ["description": .string(String(repeating: "word ", count: 40))])
        #expect((line?.count ?? 0) <= 80)
        #expect(line?.hasSuffix("…") == true)
    }
}

@Suite struct TaskBoardTests {
    private func created(_ id: String, form: String?) -> (String, [String: JSONValue], JSONValue?) {
        var input: [String: JSONValue] = ["subject": .string("Subject \(id)")]
        if let form { input["activeForm"] = .string(form) }
        return ("TaskCreate", input, .object(["task": .object(["id": .string(id)])]))
    }

    @Test func theTaskInProgressNamesTheWork() {
        var board = TaskBoard()
        let (tool, input, response) = created("7", form: "Writing the draft")
        board.note(tool: tool, input: input, response: response)
        #expect(board.current == nil)
        board.note(tool: "TaskUpdate", input: ["taskId": .string("7"), "status": .string("in_progress")], response: nil)
        #expect(board.current == "Writing the draft")
    }

    @Test func aTaskWithoutAnActiveFormUsesItsSubject() {
        var board = TaskBoard()
        let (tool, input, response) = created("7", form: nil)
        board.note(tool: tool, input: input, response: response)
        board.note(tool: "TaskUpdate", input: ["taskId": .string("7"), "status": .string("in_progress")], response: nil)
        #expect(board.current == "Subject 7")
    }

    @Test func finishingTheTaskClearsIt() {
        var board = TaskBoard()
        let (tool, input, response) = created("7", form: "Writing the draft")
        board.note(tool: tool, input: input, response: response)
        board.note(tool: "TaskUpdate", input: ["taskId": .string("7"), "status": .string("in_progress")], response: nil)
        board.note(tool: "TaskUpdate", input: ["taskId": .string("7"), "status": .string("completed")], response: nil)
        #expect(board.current == nil)
    }

    @Test func finishingAnotherTaskLeavesTheCurrentOne() {
        var board = TaskBoard()
        for id in ["7", "8"] {
            let (tool, input, response) = created(id, form: "Doing \(id)")
            board.note(tool: tool, input: input, response: response)
        }
        board.note(tool: "TaskUpdate", input: ["taskId": .string("8"), "status": .string("in_progress")], response: nil)
        board.note(tool: "TaskUpdate", input: ["taskId": .string("7"), "status": .string("completed")], response: nil)
        #expect(board.current == "Doing 8")
    }

    @Test func anUpdateCanRenameTheWork() {
        var board = TaskBoard()
        board.note(tool: "TaskUpdate", input: [
            "taskId": .string("3"), "status": .string("in_progress"), "activeForm": .string("Running the tests"),
        ], response: nil)
        #expect(board.current == "Running the tests")
    }

    /// A daemon restarted mid-session never saw the task being created.
    @Test func aTaskNeverSeenNamesNothing() {
        var board = TaskBoard()
        board.note(tool: "TaskUpdate", input: ["taskId": .string("3"), "status": .string("in_progress")], response: nil)
        #expect(board.current == nil)
    }

    @Test func theOlderTodoListWorksToo() {
        var board = TaskBoard()
        board.note(tool: "TodoWrite", input: ["todos": .array([
            .object(["content": .string("One"), "status": .string("completed"), "activeForm": .string("Doing one")]),
            .object(["content": .string("Two"), "status": .string("in_progress"), "activeForm": .string("Doing two")]),
        ])], response: nil)
        #expect(board.current == "Doing two")
    }
}
