import SwiftUI
import TouchyClient
import UIKit

@main
struct TouchytuaApp: App {
    @State private var connection = ConnectionManager(
        store: KeychainStore(), deviceName: UIDevice.current.name, dial: NWWebSocketTransport.dial)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    Task { await connection.pair(url: url.absoluteString) }
                }
                #if DEBUG
                // Lets a script pair the Simulator, where nothing can tap the
                // system's "Open in touchytua?" confirmation:
                // SIMCTL_CHILD_TOUCHYTUA_PAIR_URL=<link> xcrun simctl launch …
                .task {
                    if let link = ProcessInfo.processInfo.environment["TOUCHYTUA_PAIR_URL"] {
                        await connection.pair(url: link)
                    }
                }
                #endif
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: connection.start()
                    case .background: connection.stop()
                    default: break
                    }
                }
        }
    }
}
