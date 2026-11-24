import SwiftUI
import TouchyClient
import TouchyProtocol

struct SessionListView: View {
    @Environment(ConnectionManager.self) private var connection
    @Binding var path: [String]
    @State private var showingSettings = false
    @State private var showingNew = false
    /// The sessions put away from this list, kept on this phone.
    @AppStorage("sessionArchive") private var archiveData = Data()

    private var archive: SessionArchive { SessionArchive(data: archiveData) }

    private func waitingOnYou(_ session: Session) -> Bool {
        !connection.state.requests(for: session.id).isEmpty
    }

    private var shown: [Session] {
        let archive = archive
        return connection.state.sessions.filter { !archive.hides($0, waitingOnYou: waitingOnYou($0)) }
    }

    private var archived: Int {
        archive.hidden(among: connection.state.sessions, waitingOnYou: waitingOnYou)
    }

    var body: some View {
        VStack(spacing: 0) {
            if connection.macs.count > 1, let name = connection.macName { whichMac(name) }
            ConnectionBanner()
            if shown.isEmpty {
                empty
            } else {
                list
            }
        }
        .background(Theme.background)
        // In the system's own bar, as the session's screen is: a bar hidden
        // here and shown there makes that screen settle a moment after it
        // has slid in, and held sideways nothing kept this one off the edge.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { heading }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.green)
                }
                .disabled(!connected)
                .accessibilityLabel("New session")
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingNew) { NewSessionView { path.append($0) } }
    }

    /// What the bar says on the left: the usage of the account, or the
    /// app's name until the Mac has said it.
    private var heading: some View {
        HStack(spacing: 14) {
            if let usage = connection.state.usage, usage != Usage() {
                if let cost = usage.totalCostUSD {
                    figure("API", Format.cost(cost), Theme.red)
                }
                if let fiveHour = usage.fiveHourPct {
                    figure("5h", Format.percent(fiveHour), limitColor(fiveHour))
                }
                if let sevenDay = usage.sevenDayPct {
                    figure("7d", Format.percent(sevenDay), limitColor(sevenDay))
                }
            } else {
                Text("touchytua")
                    .font(Theme.display(17, .bold))
                    .foregroundStyle(Theme.text)
            }
        }
        .fixedSize()
    }

    /// With more than one Mac paired, whose sessions these are, and the way
    /// to another: the same menu the settings use for a choice among a few.
    private func whichMac(_ name: String) -> some View {
        HStack {
            Menu {
                Picker("Mac", selection: Binding(
                    get: { connection.macInUse },
                    set: { mac in if let mac { connection.use(mac) } })
                ) {
                    ForEach(connection.macs) { Text($0.name).tag(Optional($0.id)) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(name.uppercased())
                        .font(Theme.display(12, .bold))
                        .tracking(0.8)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 18)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Mac: \(name)")
            .accessibilityHint("Shows the paired Macs")
            Spacer()
        }
    }

    private var connected: Bool {
        if case .connected = connection.status { return true }
        return false
    }

    private func figure(_ name: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(name).foregroundStyle(Theme.text)
            Text(value).foregroundStyle(color)
        }
        .font(Theme.display(15, .medium))
        .monospacedDigit()
    }

    /// How close a rate-limit window is to full.
    private func limitColor(_ percent: Double) -> Color {
        percent >= 90 ? Theme.red : percent >= 75 ? Theme.yellow : Theme.green
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No sessions")
                .font(Theme.display(20, .bold))
                .foregroundStyle(Theme.text)
            Text("Start Claude Code on \(connection.macName ?? "your Mac") and it shows up here.")
                .font(Theme.body(15))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            if archived > 0 { bringBack }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    /// How many sessions are put away, and the way to have them back.
    private var bringBack: some View {
        Button {
            var archive = archive
            archive.bringAllBack()
            archiveData = archive.data
        } label: {
            Text("\(archived) archived · Show")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(DimPressStyle())
        .accessibilityLabel("\(archived) archived sessions")
        .accessibilityHint("Shows them again")
    }

    private var list: some View {
        List {
            ForEach(shown) { session in row(session) }
            if archived > 0 {
                bringBack
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .listRowSpacing(10)
        .contentMargins(.top, 6, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .animation(.default, value: shown)
    }

    private func row(_ session: Session) -> some View {
        Button {
            path.append(session.id)
        } label: {
            SessionRow(session: session)
        }
        .buttonStyle(RowPressStyle())
        // No vertical inset: a swipe action is as tall as its row, and
        // has to line up with the card.
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let request = quickRequest(for: session) {
                Button {
                    Task { await connection.decide(request.id, allow: true) }
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .labelStyle(.iconOnly)
                .tint(Theme.greenDeep)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let request = quickRequest(for: session) {
                Button {
                    Task { await connection.decide(request.id, allow: false) }
                } label: {
                    Label("Deny", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .tint(Theme.redDeep)
            } else if !waitingOnYou(session) {
                // Away from the list until it is asked something new.
                Button {
                    var archive = archive
                    archive.put(away: session, at: Date())
                    archiveData = archive.data
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .labelStyle(.iconOnly)
                .tint(Theme.archive)
            }
        }
    }

    /// The request a swipe settles: only when the session waits on exactly
    /// one permission, so a swipe can never answer something unseen.
    private func quickRequest(for session: Session) -> PendingRequest? {
        let requests = connection.state.requests(for: session.id)
        guard session.state == .waiting, requests.count == 1, requests[0].kind == .permission else { return nil }
        return requests[0]
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: session.state.color)
            Text(session.state.label)
                .font(Theme.display(12, .bold))
                .tracking(0.8)
                .foregroundStyle(session.state.color)
                .frame(width: 74, alignment: .leading)
            Text(session.headline)
                .font(Theme.display(16, .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
        .card(glow: session.state == .waiting ? session.state.color : nil)
        .accessibilityElement(children: .combine)
    }
}
