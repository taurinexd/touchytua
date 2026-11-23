import SwiftUI
import TouchyClient

/// An answer from Claude: headings, lists and code blocks laid out, the rest
/// as running text with inline Markdown (bold, italics, code, links).
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    Text(Self.inline(text))
                        .font(Theme.display(level <= 1 ? 20 : level == 2 ? 18 : 16, .bold))
                        .foregroundStyle(Theme.text)
                        .padding(.top, 4)
                case let .paragraph(text):
                    running(text)
                case let .item(marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .font(Theme.body(16))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                            .frame(minWidth: 18, alignment: .trailing)
                        running(text)
                    }
                case let .code(text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1) }
                case let .table(header, rows):
                    table(header: header, rows: rows)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// A table on a narrow screen: one block per row, its first cell as
    /// the title and each other cell under the name of its column. Columns
    /// side by side would leave a few characters per line.
    private func table(header: [String], rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 8) {
                    if let title = row.first, !title.isEmpty {
                        Text(Self.inline(title))
                            .font(Theme.display(16, .bold))
                            .foregroundStyle(Theme.text)
                    }
                    ForEach(Array(row.enumerated().dropFirst()), id: \.offset) { column, cell in
                        if !cell.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.inline(column < header.count ? header[column] : ""))
                                    .font(Theme.display(11, .bold))
                                    .tracking(0.6)
                                    .textCase(.uppercase)
                                    .foregroundStyle(Theme.textTertiary)
                                running(cell)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                if index < rows.count - 1 {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1) }
    }

    private func running(_ text: String) -> some View {
        Text(Self.inline(text))
            .font(Theme.body(16))
            .foregroundStyle(Theme.text)
            .lineSpacing(4)
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var styled = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        // The system monospaced face runs wide next to Geist: set inline code a little smaller.
        for run in styled.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = .system(size: 14.5, design: .monospaced)
        }
        return styled
    }
}
