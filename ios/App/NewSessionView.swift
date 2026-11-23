import SwiftUI
import TouchyClient
import TouchyProtocol

/// Starts a Claude Code session on the Mac: a folder from the Mac's own
/// list, and the first prompt.
struct NewSessionView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.dismiss) private var dismiss
    /// Called with the new session's id once it shows up.
    let opened: (String) -> Void

    @State private var folder: String?
    @State private var prompt = ""
    @State private var name = ""
    /// The sessions that were there when Start was tapped: the new one is
    /// the one that is not among them.
    @State private var before: Set<String>?

    private var launcher: Launcher { connection.launcher }
    private var starting: Bool { before != nil }

    private var ready: Bool {
        folder != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !starting
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New session")
                    .font(Theme.display(20, .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(Theme.display(16, .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let problem = launcher.problem {
                        Text(problem)
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    section("Folder on \(connection.macName ?? "your Mac")") {
                        if launcher.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().tint(Theme.textTertiary)
                                Text("Asking your Mac…")
                                    .font(Theme.body(14))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        ForEach(launcher.folders) { item in
                            folderRow(item)
                        }
                    }
                    section("What should it do?") {
                        field("The first prompt", text: $prompt, lines: 3...8)
                    }
                    section("Name, if you like") {
                        field("Named after the folder otherwise", text: $name, lines: 1...1)
                    }
                    Button(starting ? "Starting…" : "Start") { start() }
                        .buttonStyle(ActionButtonStyle(color: Theme.green))
                        .disabled(!ready)
                        .accessibilityLabel("Start session")
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.background)
        .task { await connection.loadFolders() }
        .onChange(of: launcher.folders) { _, folders in
            // The most recent folder is the likely one.
            if folder == nil || !folders.contains(where: { $0.path == folder }) { folder = folders.first?.path }
        }
        // The Mac refused: stay here, with its reason on screen.
        .onChange(of: launcher.problem) { _, problem in
            if problem != nil { before = nil }
        }
        // The session announces itself through its own hooks: open it.
        .onChange(of: connection.state.sessions.map(\.id)) { _, ids in
            guard let before, let new = connection.state.sessions.first(where: { !before.contains($0.id) && $0.cwd == folder }),
                  ids.contains(new.id) else { return }
            dismiss()
            opened(new.id)
        }
    }

    private func start() {
        guard let folder else { return }
        before = Set(connection.state.sessions.map(\.id))
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await connection.startSession(folder: folder, prompt: prompt, name: name.isEmpty ? nil : name)
            // A session that takes long to show up is still on its way:
            // it will be in the list.
            try? await Task.sleep(for: .seconds(20))
            if before != nil { dismiss() }
        }
    }

    private func folderRow(_ item: StartFolder) -> some View {
        let picked = item.path == folder
        return Button {
            folder = item.path
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(Theme.display(16, .medium))
                    .foregroundStyle(Theme.text)
                Text(Self.short(item.path))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(picked ? Theme.green : Theme.border, lineWidth: picked ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Theme.display(11, .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, lines: ClosedRange<Int>) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .font(Theme.body(16))
            .foregroundStyle(Theme.text)
            .lineLimit(lines)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1) }
    }

    /// A path with the home folder written as `~`.
    static func short(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Users" else { return path }
        return "~/" + parts.dropFirst(2).joined(separator: "/")
    }
}
