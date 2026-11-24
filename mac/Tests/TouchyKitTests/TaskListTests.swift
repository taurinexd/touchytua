import Foundation
import Testing
@testable import TouchyKit
import TouchyProtocol

@Suite struct TaskListTests {
    /// A session's task folder as Claude Code writes it: one file per task.
    private func folder(_ files: [String: String]) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tt-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory.path
    }

    @Test func readsTheTasksOfASessionInTheirOrder() throws {
        let directory = try folder([
            "10.json": #"{"id":"10","subject":"Ship it","description":"long","status":"pending","blocks":[],"blockedBy":["2"]}"#,
            "2.json": #"{"id":"2","subject":"Write the tests","activeForm":"Writing the tests","status":"in_progress","blocks":["10"],"blockedBy":[]}"#,
            "1.json": #"{"id":"1","subject":"Read the code","status":"completed","blocks":[],"blockedBy":[]}"#,
            ".lock": "",
            ".highwatermark": "10",
        ])
        defer { try? FileManager.default.removeItem(atPath: directory) }

        #expect(TaskList.read(directory: directory) == [
            SessionTask(id: "1", subject: "Read the code", status: .completed),
            SessionTask(id: "2", subject: "Write the tests", status: .inProgress),
            SessionTask(id: "10", subject: "Ship it", status: .pending, blockedBy: ["2"]),
        ])
    }

    @Test func whatIsNotATaskIsLeftOut() throws {
        let directory = try folder([
            "1.json": #"{"id":"1","subject":"Kept","status":"pending"}"#,
            "2.json": "not json",
            "3.json": #"{"id":"3","subject":"Gone","status":"deleted"}"#,
            "4.json": #"{"id":"4","status":"pending"}"#,
            "notes.txt": "hello",
        ])
        defer { try? FileManager.default.removeItem(atPath: directory) }

        #expect(TaskList.read(directory: directory) == [SessionTask(id: "1", subject: "Kept", status: .pending)])
    }

    @Test func aSessionWithoutATaskFolderHasNoTasks() {
        #expect(TaskList.read(directory: "/nonexistent/\(UUID().uuidString)").isEmpty)
    }

    @Test func aLongSubjectIsClipped() throws {
        let long = String(repeating: "word ", count: 100)
        let directory = try folder(["1.json": #"{"id":"1","subject":"\#(long)","status":"pending"}"#])
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let subject = TaskList.read(directory: directory).first?.subject ?? ""
        #expect(subject.count <= TaskList.longestSubject)
        #expect(subject.hasSuffix("…"))
    }

    @Test func theFolderIsNamedAfterTheSession() {
        #expect(TaskList.directory(sessionId: "abc-123", userHome: "/Users/dev") == "/Users/dev/.claude/tasks/abc-123")
        // A session id is a name, never a way out of the tasks folder.
        #expect(TaskList.directory(sessionId: "../../etc", userHome: "/Users/dev") == nil)
        #expect(TaskList.directory(sessionId: "", userHome: "/Users/dev") == nil)
    }

    @Test func theOlderTodoListReadsAsTasks() {
        let todos: JSONValue = .array([
            .object(["content": .string("Read the code"), "status": .string("completed"), "activeForm": .string("Reading the code")]),
            .object(["content": .string("Write the tests"), "status": .string("in_progress")]),
            .object(["content": .string(""), "status": .string("pending")]),
        ])
        #expect(TaskList.fromTodos(todos) == [
            SessionTask(id: "1", subject: "Read the code", status: .completed),
            SessionTask(id: "2", subject: "Write the tests", status: .inProgress),
        ])
    }
}
