import SwiftUI
import TouchyClient

/// Says so when the picture on screen may be stale, and what to do about it.
struct ConnectionBanner: View {
    @Environment(ConnectionManager.self) private var connection
    @State private var scanning = false

    var body: some View {
        Group {
            switch connection.status {
            case .connected, .unpaired:
                EmptyView()
            case .connecting:
                line("Connecting to \(connection.macName ?? "your Mac")…", busy: true)
            case .reconnecting:
                line("Reconnecting to \(connection.macName ?? "your Mac")…", busy: true)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 12) {
                    Text(message)
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.red)
                    Button("Scan code") { scanning = true }
                        .buttonStyle(ActionButtonStyle(color: Theme.green, filled: false))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $scanning) { ScannerSheet() }
    }

    private func line(_ text: String, busy: Bool) -> some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            Text(text)
                .font(Theme.body(14))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
