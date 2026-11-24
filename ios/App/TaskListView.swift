import SwiftUI
import TouchyClient
import TouchyProtocol
import UIKit

/// The session's task list, drawn as Claude Code draws it in the terminal:
/// the same five tasks, marks and line about the rest. The heading folds
/// it away, as Ctrl+T does there; the line about the rest opens the whole
/// list, which the terminal has no room for.
struct TaskListView: View {
    let tasks: [SessionTask]
    @AppStorage("taskListOpen") private var open = true
    /// Held sideways there is no room for it unless asked.
    @State private var openWhenShort = false
    @State private var whole = false
    @State private var watch = CompletedWatch()
    @State private var now = Date()
    @State private var keyboardUp = false
    @Environment(\.verticalSizeClass) private var height

    private let rowHeight: CGFloat = 24
    private let footHeight: CGFloat = 28

    private func listHeight(_ picture: TaskListPicture) -> CGFloat {
        let rows = CGFloat(picture.rows.count) * rowHeight
        return whole ? min(rows, height == .compact ? 120 : 264) : rows
    }

    private func bodyHeight(_ picture: TaskListPicture) -> CGFloat {
        let foot = picture.more != nil || (whole && tasks.count > TaskListPicture.shownAtATime)
        return listHeight(picture) + (foot ? footHeight : 0) + 6
    }

    private var unfolded: Bool {
        !keyboardUp && (height == .compact ? openWhenShort : open)
    }

    var body: some View {
        let picture = TaskListPicture(
            tasks: tasks, justCompleted: watch.justCompleted(at: now),
            limit: whole ? nil : TaskListPicture.shownAtATime)
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            heading(picture)
            // Always there, at its height or none: the heading rides on
            // top of it, so the rows slide away under the prompt bar and
            // come back from there, never there or gone at once.
            VStack(alignment: .leading, spacing: 0) {
                if whole {
                    ScrollView { rows(picture) }
                        .frame(height: listHeight(picture))
                } else {
                    rows(picture)
                }
                if let more = picture.more {
                    foot(more) { whole = true }
                } else if whole, tasks.count > TaskListPicture.shownAtATime {
                    foot("… show less") { whole = false }
                }
            }
            // The five rows and the whole list change places at once; it
            // is the room around them that grows or shrinks.
            .id(whole)
            .transition(.identity)
            .modifier(Reveal(height: unfolded ? bodyHeight(picture) : 0))
            .opacity(unfolded ? 1 : 0)
            .accessibilityHidden(!unfolded)
        }
        .background(Theme.background)
        .animation(.snappy(duration: 0.28), value: unfolded)
        .animation(.snappy(duration: 0.28), value: whole)
        .onChange(of: tasks, initial: true) {
            watch.observe(tasks, at: Date())
            now = Date()
        }
        // A task just completed leaves the top of the list by itself.
        .task(id: watch) {
            while let next = watch.nextChange(after: Date()) {
                try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow + 0.05)))
                if Task.isCancelled { return }
                now = Date()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
    }

    private func heading(_ picture: TaskListPicture) -> some View {
        Button {
            if height == .compact { openWhenShort.toggle() } else { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                (Text("\(picture.done)").bold() + Text("/\(picture.total) \(picture.total == 1 ? "task" : "tasks") done")
                    + Text(picture.inProgress.map { " · \($0)" } ?? ""))
                    .font(Theme.body(13))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer()
                Image(systemName: unfolded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(keyboardUp)
        .accessibilityLabel(picture.heading + (picture.inProgress.map { ", \($0)" } ?? ""))
        .accessibilityHint(unfolded ? "Hides the task list" : "Shows the task list")
    }

    private func rows(_ picture: TaskListPicture) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(picture.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    mark(row.task.status)
                        .frame(width: 12)
                    (subject(row) + Text(row.waitingFor.map { " \($0)" } ?? "").foregroundStyle(Theme.textTertiary))
                        .font(Theme.body(14))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: rowHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(row))
            }
        }
    }

    /// The terminal's marks: a tick, a filled square, an empty square.
    @ViewBuilder private func mark(_ status: SessionTask.Status) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.green)
        case .inProgress:
            Image(systemName: "square.fill")
                .font(.system(size: 8))
                .foregroundStyle(Theme.orange)
        case .pending:
            Image(systemName: "square")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.text)
        }
    }

    /// Bold while it is being done, struck through once done, dimmed when
    /// done or waiting for another.
    private func subject(_ row: TaskListPicture.Row) -> Text {
        let done = row.task.status == .completed
        return Text(row.task.subject)
            .fontWeight(row.task.status == .inProgress ? .bold : .regular)
            .strikethrough(done)
            .foregroundStyle(done || !row.openBlockers.isEmpty ? Theme.textTertiary : Theme.text)
    }

    private func spoken(_ row: TaskListPicture.Row) -> String {
        let status = switch row.task.status {
        case .completed: "done"
        case .inProgress: "in progress"
        case .pending: row.openBlockers.isEmpty ? "open" : "waiting for task " + row.openBlockers.joined(separator: ", ")
        }
        return "\(row.task.subject), \(status)"
    }

    private func foot(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 36)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, minHeight: footHeight, maxHeight: footHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A height that is laid out anew at every step of an animation, with what
/// is inside kept at the top and cut at the bottom. A plain frame animates
/// the views around it one by one, and they drift apart on the way.
private struct Reveal: ViewModifier, @preconcurrency Animatable {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(height: max(0, height), alignment: .top)
            .clipped()
    }
}
