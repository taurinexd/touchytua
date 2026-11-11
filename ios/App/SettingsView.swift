import SwiftUI
import TouchyClient

struct SettingsView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section("Mac") {
                    LabeledContent("Name", value: connection.macName ?? "—")
                    LabeledContent("Connection", value: statusText)
                }
                Section {
                    Button("Unpair", role: .destructive) { confirmingUnpair = true }
                } footer: {
                    Text("To pair again, run /pair in Claude Code on your Mac.")
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Text("Set in Space Grotesk and Geist, used under the SIL Open Font License 1.1.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Unpair this Mac?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    connection.unpair()
                    dismiss()
                }
            }
        }
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
