import SwiftUI
import TouchyClient

struct PairingView: View {
    @Environment(ConnectionManager.self) private var connection
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text("Pair your Mac")
                .font(Theme.display(34, .bold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 14) {
                step("1", "Install the touchytua plugin in Claude Code.")
                step("2", "Run /pair in any session.")
                step("3", "Scan the code that appears on your Mac.")
            }
            if connection.status == .connecting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting…")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if case let .failed(message) = connection.status {
                Text(message)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.red)
            }
            Spacer()
            Button("Scan code") { scanning = true }
                .buttonStyle(ActionButtonStyle(color: Theme.green))
                .disabled(connection.status == .connecting)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $scanning) { ScannerSheet() }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number)
                .font(Theme.display(15, .bold))
                .foregroundStyle(Theme.green)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(Theme.body(17))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
