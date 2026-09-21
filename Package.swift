// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "isync",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "isync", targets: ["isync"]),
        .library(name: "ISyncCore", targets: ["ISyncCore"]),
    ],
    targets: [
        // Pure engine: scanning, planning, copying, verifying. No terminal code.
        // Kept separate so a SwiftUI front end can reuse it later.
        .target(name: "ISyncCore", path: "Sources/ISyncCore"),
        // Command-line front end: argument parsing + live terminal UI.
        .executableTarget(name: "isync", dependencies: ["ISyncCore"], path: "Sources/isync"),
        .testTarget(name: "ISyncCoreTests", dependencies: ["ISyncCore"], path: "Tests/ISyncCoreTests"),
    ]
)
