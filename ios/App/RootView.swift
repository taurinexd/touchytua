import SwiftUI
import TouchyClient

/// Pairing until a Mac is paired, the sessions afterwards.
struct RootView: View {
    @Environment(ConnectionManager.self) private var connection
    @State private var path: [String] = []

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if connection.macName == nil {
                PairingView()
            } else {
                NavigationStack(path: $path) {
                    SessionListView(path: $path)
                        .navigationDestination(for: String.self) { SessionDetailView(sessionId: $0) }
                }
            }
        }
        .tint(Theme.green)
        .onChange(of: connection.macName) { _, _ in path = [] }
    }
}
