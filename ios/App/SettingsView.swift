import SwiftUI
import TouchyClient

struct SettingsView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false
    @State private var scanning = false
    @AppStorage(DictationSettings.holdToSend) private var holdToSend = false
    @AppStorage(DictationSettings.language) private var language = ""
    @State private var languages: [DictationLanguage.Name] = []
    /// The language dictation uses when none is chosen.
    @State private var automatic: String?

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
                    VStack(alignment: .leading, spacing: 10) {
                        section(connection.macs.count > 1 ? "Macs" : "Mac") {
                            ForEach(connection.macs) { mac in
                                if mac.id != connection.macs.first?.id { divider }
                                macRow(mac)
                            }
                        }
                        if connection.macs.count > 1 {
                            Text("Tap a Mac to see its sessions.")
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        if let update = connection.macUpdate {
                            Text(update.explanation(macName: connection.macName ?? "Your Mac"))
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.yellow)
                            Text(MacUpdate.steps + " " + MacUpdate.keepUpdated)
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Add a Mac") {
                            connection.clearPairingProblem()
                            scanning = true
                        }
                        .buttonStyle(ActionButtonStyle(color: Theme.green, filled: false))
                        .disabled(connection.macBeingAdded != nil)
                        if let name = connection.macBeingAdded {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Connecting to \(name)…")
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        if let problem = connection.pairingProblem {
                            Text(problem)
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.red)
                        }
                        Text("Run /pair in Claude Code on the Mac to add, then scan the code it shows.")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textTertiary)
                        Button(connection.macs.count > 1 ? "Unpair \(connection.macName ?? "this Mac")" : "Unpair") {
                            confirmingUnpair = true
                        }
                        .buttonStyle(ActionButtonStyle(color: Theme.red, filled: false))
                        .padding(.top, 6)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        section("Dictation") {
                            Menu {
                                Picker("Language", selection: $language) {
                                    Text(automatic.map { "Automatic · \($0)" } ?? "Automatic").tag("")
                                    ForEach(languages) { Text($0.name).tag($0.id) }
                                }
                            } label: {
                                row("Language", languageName, chevron: true)
                            }
                            .accessibilityLabel("Dictation language")
                            divider
                            Toggle(isOn: $holdToSend) {
                                Text("Hold to talk")
                                    .font(Theme.body(16))
                                    .foregroundStyle(Theme.text)
                            }
                            .tint(Theme.greenDeep)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                        }
                        Text(holdToSend
                            ? "Hold the microphone while you speak. Releasing sends the prompt right away; slide your finger away to cancel."
                            : "Tap the microphone to start and again to stop. Your words go into the message, where you can fix them before sending.")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textTertiary)
                        Text("Speech is turned into text on this iPhone. Audio is never sent anywhere.")
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
        .task {
            languages = DictationLanguage.names(for: await SystemSpeechEngine.supportedLocales())
            let device = await SystemSpeechEngine.supportedLocale(equivalentTo: DictationSettings.deviceLocale)
            automatic = DictationLanguage.names(for: [device].compactMap { $0 }).first?.name
        }
        .sheet(isPresented: $scanning) { ScannerSheet() }
        .confirmationDialog(
            "Unpair \(connection.macName ?? "this Mac")?", isPresented: $confirmingUnpair, titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                connection.unpair()
                // With no Mac left the pairing screen takes over.
                if connection.macs.isEmpty { dismiss() }
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

    private var languageName: String {
        if language.isEmpty { return automatic.map { "Automatic · \($0)" } ?? "Automatic" }
        return languages.first { $0.id == language }?.name ?? language
    }

    private func row(_ name: String, _ value: String, chevron: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(Theme.body(16))
                .foregroundStyle(Theme.text)
            Spacer()
            Text(value)
                .font(Theme.body(16))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.trailing)
            if chevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
    }

    /// The Mac in use says how it is connected; the others are a tap away.
    private func macRow(_ mac: PairedMac) -> some View {
        let inUse = mac.id == connection.macInUse
        return Button {
            connection.use(mac.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.green)
                    .opacity(inUse ? 1 : 0)
                Text(mac.name)
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                Spacer()
                if inUse {
                    // Hung up for the time another Mac is being added.
                    Text(connection.macBeingAdded == nil ? statusText : "Not connected")
                        .font(Theme.body(16))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inUse ? "\(mac.name), in use, \(statusText)" : mac.name)
        .accessibilityHint(inUse ? "" : "Shows this Mac's sessions")
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
