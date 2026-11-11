// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Touchytua",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        // What the iOS app links: wire types, handshake, encrypted channel.
        .library(name: "TouchyProtocol", targets: ["TouchyProtocol"]),
        // The phone side: encrypted link, state, reconnection. Used by the
        // iOS app and by the command-line phone simulator.
        .library(name: "TouchyClient", targets: ["TouchyClient"]),
        .library(name: "TouchyKit", targets: ["TouchyKit"]),
    ],
    targets: [
        // Shared with the iOS app. Nothing here may depend on macOS.
        .target(name: "TouchyProtocol"),
        .target(name: "TouchyClient", dependencies: ["TouchyProtocol"]),
        // The Mac side: hooks, session registry, pairing store, daemon logic.
        .target(name: "TouchyKit", dependencies: ["TouchyProtocol"]),
        // Hook relay: tiny, dependency-free, fast to spawn.
        .executableTarget(name: "touchytua-hook"),
        // Background daemon: hook server, phone server, pending requests.
        .executableTarget(name: "touchytuad", dependencies: ["TouchyKit"]),
        // Chained statusline wrapper (opt-in).
        .executableTarget(name: "touchytua-statusline"),
        // User-facing CLI: pair, doctor, daemon --ensure, statusline.
        .executableTarget(name: "touchytua", dependencies: ["TouchyKit"]),
        // CLI that simulates the phone, for end-to-end verification.
        // Built only on what the iOS app links, so it exercises the same code.
        .executableTarget(name: "touchytua-client", dependencies: ["TouchyClient", "TouchyProtocol"]),
        // The client is tested against the real Mac-side router and hub.
        .testTarget(name: "TouchyClientTests", dependencies: ["TouchyClient", "TouchyKit", "TouchyProtocol"]),
        .testTarget(name: "TouchyKitTests", dependencies: ["TouchyKit", "TouchyProtocol"], exclude: ["Fixtures"]),
    ]
)
