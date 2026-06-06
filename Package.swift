// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TerminalManager",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TerminalManagerCore",
            targets: ["TerminalManagerCore"]
        ),
        .executable(
            name: "terminal-manager-selfcheck",
            targets: ["TerminalManagerSelfCheck"]
        ),
        .executable(
            name: "terminal-manager-local-e2e",
            targets: ["TerminalManagerLocalE2E"]
        )
    ],
    targets: [
        .target(
            name: "TerminalManagerCore"
        ),
        .executableTarget(
            name: "TerminalManagerSelfCheck",
            dependencies: ["TerminalManagerCore"]
        ),
        .executableTarget(
            name: "TerminalManagerLocalE2E",
            dependencies: ["TerminalManagerCore"]
        )
    ]
)
