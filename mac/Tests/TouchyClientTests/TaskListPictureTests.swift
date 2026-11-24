import Foundation
import Testing
@testable import TouchyClient
import TouchyProtocol

/// The task list as the terminal draws it: which five tasks, in what
/// order, and what the line about the others says.
@Suite struct TaskListPictureTests {
    private func task(_ id: Int, _ status: SessionTask.Status, blockedBy: [Int] = []) -> SessionTask {
        SessionTask(id: String(id), subject: "Task \(id)", status: status, blockedBy: blockedBy.map(String.init))
    }

    @Test func aShortListIsShownWholeInItsOrder() {
        let tasks = [task(3, .pending), task(1, .completed), task(2, .inProgress)]
        let picture = TaskListPicture(tasks: tasks)
        #expect(picture.rows.map(\.task.id) == ["1", "2", "3"])
        #expect(picture.more == nil)
    }

    /// The list in the terminal this was drawn from: 45 tasks, two in
    /// progress, five open of which two wait for another.
    @Test func aLongListShowsWhatIsBeingDoneThenWhatCanBeStarted() {
        var tasks = (1...45).map { task($0, .completed) }
        for id in [22, 35] { tasks[id - 1] = task(id, .inProgress) }
        for id in [14, 53, 54] { tasks.append(task(id, .pending)) }
        tasks.removeAll { $0.id == "14" && $0.status == .completed }
        tasks[18] = task(19, .pending, blockedBy: [14, 18])
        tasks[19] = task(20, .pending, blockedBy: [19])
        tasks = tasks.filter { Int($0.id)! != 53 && Int($0.id)! != 54 || $0.status == .pending }

        let picture = TaskListPicture(tasks: tasks)

        #expect(picture.rows.map(\.task.id) == ["22", "35", "14", "53", "54"])
        #expect(picture.more == "… +\(tasks.count - 5) tasks (2 open, \(tasks.count - 7) done)")
    }

    @Test func aTaskJustCompletedStaysOnTopForAWhile() {
        let tasks = [task(1, .completed), task(2, .completed), task(3, .inProgress), task(4, .pending),
                     task(5, .pending), task(6, .pending), task(7, .pending)]
        let picture = TaskListPicture(tasks: tasks, justCompleted: ["2"])
        #expect(picture.rows.map(\.task.id) == ["2", "3", "4", "5", "6"])
        #expect(picture.more == "… +2 tasks (1 open, 1 done)")
    }

    @Test func aTaskWaitingForAnotherComesAfterTheOnesThatCanStart() {
        let tasks = [task(1, .pending, blockedBy: [6]), task(2, .pending, blockedBy: [9]), task(3, .pending),
                     task(4, .pending), task(5, .pending), task(6, .pending), task(9, .completed)]
        let picture = TaskListPicture(tasks: tasks)
        // 2 waits for a task already done: it can start.
        #expect(picture.rows.map(\.task.id) == ["2", "3", "4", "5", "6"])
        #expect(picture.more == "… +2 tasks (1 open, 1 done)")
    }

    @Test func theLineAboutTheOthersNamesOnlyWhatIsThere() {
        let done = (1...8).map { task($0, .completed) }
        #expect(TaskListPicture(tasks: done).more == "… +3 tasks (done)")
        let six = (1...6).map { task($0, .inProgress) }
        #expect(TaskListPicture(tasks: six).more == "… +1 task (in progress)")
        let mixed = (1...6).map { task($0, .inProgress) } + [task(7, .pending), task(8, .completed)]
        #expect(TaskListPicture(tasks: mixed).more == "… +3 tasks (1 in progress, 1 open, 1 done)")
    }

    @Test func aRowSaysWhatItStillWaitsFor() {
        let tasks = [task(1, .completed), task(2, .pending), task(10, .pending), task(3, .pending, blockedBy: [10, 1, 2])]
        let row = TaskListPicture(tasks: tasks).rows.first { $0.task.id == "3" }
        #expect(row?.openBlockers == ["2", "10"])
        #expect(row?.waitingFor == "› blocked by #2, #10")
        #expect(TaskListPicture(tasks: tasks).rows.first?.waitingFor == nil)
    }

    @Test func theWholeListIsInTheOrderOfItsNumbers() {
        let tasks = (1...9).map { task($0, $0 == 9 ? .inProgress : .completed) }
        let picture = TaskListPicture(tasks: tasks, limit: nil)
        #expect(picture.rows.map(\.task.id) == (1...9).map(String.init))
        #expect(picture.more == nil)
    }

    @Test func theHeadingCountsWhatIsDone() {
        let tasks = [task(1, .completed), task(2, .inProgress), task(3, .pending)]
        let picture = TaskListPicture(tasks: tasks)
        #expect(picture.done == 1)
        #expect(picture.heading == "1/3 tasks done")
        #expect(picture.inProgress == "1 in progress")
        #expect(TaskListPicture(tasks: [task(1, .completed)]).heading == "1/1 task done")
        #expect(TaskListPicture(tasks: [task(1, .completed)]).inProgress == nil)
    }

    // MARK: what was just completed

    @Test func whatWasDoneBeforeLookingIsNotNews() {
        let start = Date(timeIntervalSince1970: 1000)
        var watch = CompletedWatch()
        watch.observe([task(1, .completed), task(2, .inProgress)], at: start)
        #expect(watch.justCompleted(at: start).isEmpty)
    }

    @Test func aTaskCompletedWhileLookingIsNewsForHalfAMinute() {
        let start = Date(timeIntervalSince1970: 1000)
        var watch = CompletedWatch()
        watch.observe([task(1, .completed), task(2, .inProgress)], at: start)
        watch.observe([task(1, .completed), task(2, .completed)], at: start + 5)

        #expect(watch.justCompleted(at: start + 6) == ["2"])
        #expect(watch.nextChange(after: start + 6) == start + 35)
        #expect(watch.justCompleted(at: start + 35).isEmpty)
        #expect(watch.nextChange(after: start + 35) == nil)
    }

    @Test func aTaskReopenedIsNoLongerNews() {
        let start = Date(timeIntervalSince1970: 1000)
        var watch = CompletedWatch()
        watch.observe([task(1, .inProgress)], at: start)
        watch.observe([task(1, .completed)], at: start + 1)
        watch.observe([task(1, .inProgress)], at: start + 2)
        watch.observe([task(1, .completed)], at: start + 20)
        #expect(watch.justCompleted(at: start + 40) == ["1"])
    }
}
