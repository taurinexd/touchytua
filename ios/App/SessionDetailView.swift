import SwiftUI
import TouchyClient
import TouchyProtocol

struct SessionDetailView: View {
    @Environment(ConnectionManager.self) private var connection
    let sessionId: String

    private var session: Session? {
        connection.state.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                Text("This session has ended.")
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
    }

    private func content(_ session: Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(session.headline)
                    .font(Theme.display(20, .bold))
                    .foregroundStyle(Theme.text)
                ForEach(connection.state.requests(for: session.id)) { request in
                    if request.kind == .question, !request.questions.isEmpty {
                        QuestionCard(request: request)
                    } else {
                        PermissionCard(request: request)
                    }
                }
                if let round = session.round {
                    RoundView(round: round)
                } else {
                    Text("Nothing has happened in this session yet.")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { PromptBar(sessionId: session.id) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    StatusDot(color: session.state.color)
                    Text(session.state.label)
                        .font(Theme.display(12, .bold))
                        .tracking(0.8)
                        .foregroundStyle(session.state.color)
                }
            }
        }
    }
}

/// "This Round": how long, how much, and what Claude said.
struct RoundView: View {
    let round: Round

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("This Round")
                    .font(Theme.display(15, .bold))
                    .foregroundStyle(Theme.green)
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(round.caption(now: timeline.date))
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
            if let summary = round.summary, !summary.isEmpty {
                Text(Self.rendered(summary))
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            } else if round.endedAt == nil {
                Text("Working…")
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Inline Markdown only (bold, italics, code, links), line breaks kept.
    private static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// The text prompt at the bottom of a session.
struct PromptBar: View {
    @Environment(ConnectionManager.self) private var connection
    let sessionId: String
    @State private var text = ""

    private var connected: Bool {
        if case .connected = connection.status { return true }
        return false
    }

    private var canSend: Bool {
        connected && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = connection.notice {
                Text(notice)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.red)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Claude", text: $text, axis: .vertical)
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .card(radius: 20)
                Button {
                    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    text = ""
                    Task { await connection.prompt(sessionId: sessionId, text: prompt) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: 42, height: 42)
                        .background(Theme.green, in: Circle())
                }
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.35)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.background)
    }
}
