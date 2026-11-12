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
                    .lineLimit(2)
                ForEach(connection.state.requests(for: session.id)) { request in
                    if request.kind == .question, !request.questions.isEmpty {
                        QuestionCard(request: request)
                    } else {
                        PermissionCard(request: request)
                    }
                }
                if let round = session.round {
                    RoundView(round: round, waiting: session.state == .waiting)
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
    /// The session is stopped on a request for the person.
    var waiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("This Round")
                    .font(Theme.display(15, .bold))
                    .foregroundStyle(Theme.green)
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(round.caption(now: timeline.date, waiting: waiting))
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
            if let summary = round.summary, !summary.isEmpty {
                MarkdownView(text: summary)
            } else if round.endedAt == nil, !waiting {
                Text("Working…")
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
