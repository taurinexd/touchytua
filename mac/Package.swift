// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Touchytua",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        // What the iOS app links: wire types, handshake, encrypted channel.
        .library(name: "TouchyProtocol", targets: ["TouchyProtocol"]),
        .library(name: "TouchyKit", targets: ["TouchyKit"]),
    ],
    targets: [
        // Shared with the iOS app. Nothing here may depend on macOS.
        .target(name: "TouchyProtocol"),
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
        .executableTarget(name: "touchytua-client", dependencies: ["TouchyKit"]),
        .testTarget(name: "TouchyKitTests", dependencies: ["TouchyKit", "TouchyProtocol"], exclude: ["Fixtures"]),
    ]
)
