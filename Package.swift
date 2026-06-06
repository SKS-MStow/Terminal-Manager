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
        )
    ],
    targets: [
        .target(
            name: "TerminalManagerCore"
        ),
        .executableTarget(
            name: "TerminalManagerSelfCheck",
            dependencies: ["TerminalManagerCore"]
        )
    ]
)
