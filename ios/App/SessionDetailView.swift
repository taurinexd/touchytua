import SwiftUI
import TouchyClient
import TouchyProtocol

struct SessionDetailView: View {
    @Environment(ConnectionManager.self) private var connection
    let sessionId: String
    /// The request whose own-answer field has the keyboard.
    @State private var answering: String?

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
        let sent = connection.outbox.waiting(in: session.id)
        return ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(session.headline)
                        .font(Theme.display(20, .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    ForEach(connection.state.requests(for: session.id)) { request in
                        if request.kind == .question, !request.questions.isEmpty {
                            QuestionCard(request: request, answering: $answering)
                                .id(request.id)
                        } else {
                            PermissionCard(request: request)
                        }
                    }
                    if let round = session.round {
                        RoundView(
                            round: round, prompt: session.roundPrompt, waiting: session.state == .waiting,
                            answerable: !connection.state.requests(for: session.id).isEmpty)
                    } else if sent.isEmpty {
                        Text("Nothing has happened in this session yet.")
                            .font(Theme.body(15))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if !sent.isEmpty {
                        SentPromptsView(prompts: sent, busy: session.state == .working || session.state == .waiting)
                            .id("sent")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            // The card's own Send must stay above the keyboard: wait for
            // the keyboard to be up, then bring the card's end into view.
            .onChange(of: answering) { _, request in
                guard let request else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(.snappy(duration: 0.25)) { scroll.scrollTo(request, anchor: .bottom) }
                }
            }
            .onChange(of: sent.count) { before, now in
                if now > before { withAnimation(.snappy(duration: 0.25)) { scroll.scrollTo("sent", anchor: .bottom) } }
            }
        }
        // While an answer is being typed in a card the prompt field steps
        // aside: two fields over one keyboard hide the card's Send. It
        // stays in the view, so a draft in it is not lost.
        .safeAreaInset(edge: .bottom) {
            PromptBar(sessionId: session.id, project: session.cwd)
                .frame(maxHeight: answering == nil ? nil : 0)
                .clipped()
                .allowsHitTesting(answering == nil)
                .accessibilityHidden(answering != nil)
        }
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
    /// What the person asked for in this round, unless the title says it.
    var prompt: String?
    /// The session is stopped on a request for the person.
    var waiting = false
    /// That request is on this screen, to be answered here.
    var answerable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("This Round")
                    .font(Theme.display(15, .bold))
                    .foregroundStyle(Theme.green)
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(round.caption(now: timeline.date, waiting: waiting, answerable: answerable))
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
            if let prompt {
                Text(prompt)
                    .font(Theme.display(17, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
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

/// What was sent from this phone and Claude has not started on yet.
struct SentPromptsView: View {
    let prompts: [Outbox.Prompt]
    /// The session is in the middle of something: the prompt has to wait.
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Sent")
                    .font(Theme.display(15, .bold))
                    .foregroundStyle(Theme.textSecondary)
                Text(busy ? "Claude reads it after this step" : "On its way to Claude")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(prompts) { prompt in
                Text(prompt.text)
                    .font(Theme.display(17, .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
