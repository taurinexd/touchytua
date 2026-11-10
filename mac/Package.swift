// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Touchytua",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .library(name: "TouchyKit", targets: ["TouchyKit"]),
    ],
    targets: [
        // Models, protocol and crypto shared with the iOS app.
        .target(name: "TouchyKit"),
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
        .testTarget(name: "TouchyKitTests", dependencies: ["TouchyKit"], exclude: ["Fixtures"]),
    ]
)
