import SwiftUI
import TouchyClient

struct SettingsView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(Theme.display(20, .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Done") { dismiss() }
                    .font(Theme.display(16, .bold))
                    .foregroundStyle(Theme.green)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Mac") {
                        row("Name", connection.macName ?? "—")
                        divider
                        row("Connection", statusText)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Unpair") { confirmingUnpair = true }
                            .buttonStyle(ActionButtonStyle(color: Theme.red, filled: false))
                        Text("To pair again, run /pair in Claude Code on your Mac.")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    section("About") {
                        row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                        divider
                        Text("Set in Space Grotesk and Geist, used under the SIL Open Font License 1.1.")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(14)
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.background)
        .presentationBackground(Theme.background)
        .confirmationDialog("Unpair this Mac?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                connection.unpair()
                dismiss()
            }
        }
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.display(12, .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0, content: rows)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(Theme.body(16))
                .foregroundStyle(Theme.text)
            Spacer()
            Text(value)
                .font(Theme.body(16))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 14)
    }

    private var statusText: String {
        switch connection.status {
        case .unpaired: "Not paired"
        case .connecting: "Connecting"
        case let .connected(via): "Connected over \(via)"
        case .reconnecting: "Reconnecting"
        case .failed: "Not connected"
        }
    }
}
