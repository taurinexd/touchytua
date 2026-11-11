import SwiftUI
import TouchyClient
import TouchyProtocol

struct SessionListView: View {
    @Environment(ConnectionManager.self) private var connection
    @Binding var path: [String]
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ConnectionBanner()
            if connection.state.sessions.isEmpty {
                empty
            } else {
                list
            }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    private var header: some View {
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
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
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
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        List(connection.state.sessions) { session in
            Button {
                path.append(session.id)
            } label: {
                SessionRow(session: session)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if let request = quickRequest(for: session) {
                    Button("Approve") {
                        Task { await connection.decide(request.id, allow: true) }
                    }
                    .tint(Theme.greenDeep)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if let request = quickRequest(for: session) {
                    Button("Deny") {
                        Task { await connection.decide(request.id, allow: false) }
                    }
                    .tint(Theme.redDeep)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.default, value: connection.state.sessions)
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
