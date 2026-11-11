import SwiftUI
import TouchyClient
import TouchyProtocol

/// A tool Claude wants to run: what it is, and Deny / Approve.
struct PermissionCard: View {
    @Environment(ConnectionManager.self) private var connection
    let request: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Waiting on you")
                    .font(Theme.display(15, .bold))
                    .foregroundStyle(Theme.yellow)
                Spacer()
                Text(request.toolName)
                    .font(Theme.display(13, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            if request.truncated {
                Text("Long input was shortened. The full text is on your Mac.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 10) {
                Button("Deny") {
                    Task { await connection.decide(request.id, allow: false) }
                }
                .buttonStyle(ActionButtonStyle(color: Theme.red, filled: false))
                Button("Approve") {
                    Task { await connection.decide(request.id, allow: true) }
                }
                .buttonStyle(ActionButtonStyle(color: Theme.green))
            }
        }
        .padding(14)
        .card(glow: Theme.yellow)
    }
}

/// A question from Claude with its options as A / B / C cards.
struct QuestionCard: View {
    @Environment(ConnectionManager.self) private var connection
    let request: PendingRequest
    /// Picked labels, by question text.
    @State private var picked: [String: Set<String>] = [:]

    var body: some View {
        let questions = request.questions
        VStack(alignment: .leading, spacing: 16) {
            Text("Waiting on you")
                .font(Theme.display(15, .bold))
                .foregroundStyle(Theme.yellow)
            ForEach(questions, id: \.text) { question in
                VStack(alignment: .leading, spacing: 10) {
                    Text(question.text)
                        .font(Theme.body(16))
                        .foregroundStyle(Theme.text)
                    if question.multiSelect {
                        Text("Pick one or more")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        optionRow(question, index: index, option: option)
                    }
                }
            }
            Button("Send") {
                guard let answers = Question.answers(to: questions, picked: picked) else { return }
                Task { await connection.answer(request.id, answers: answers) }
            }
            .buttonStyle(ActionButtonStyle(color: Theme.yellow))
            .disabled(Question.answers(to: questions, picked: picked) == nil)
            .accessibilityLabel("Send answer")
        }
        .padding(14)
        .card()
    }

    private func optionRow(_ question: Question, index: Int, option: Question.Option) -> some View {
        let isPicked = picked[question.text]?.contains(option.label) == true
        return Button {
            var labels = picked[question.text] ?? []
            if question.multiSelect {
                if isPicked { labels.remove(option.label) } else { labels.insert(option.label) }
            } else {
                labels = [option.label]
            }
            picked[question.text] = labels
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Self.letter(index))
                    .font(Theme.display(14, .bold))
                    .foregroundStyle(Theme.yellow)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(Theme.display(16, .medium))
                        .foregroundStyle(Theme.text)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isPicked ? Theme.yellow : Theme.border, lineWidth: isPicked ? 1.5 : 1)
            }
            .shadow(color: isPicked ? Theme.yellow.opacity(0.4) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    /// A, B, C… then numbers once the alphabet runs out.
    private static func letter(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : String(index + 1)
    }
}
