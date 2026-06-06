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
        .library(
            name: "TerminalManagerCitadelSupport",
            targets: ["TerminalManagerCitadelSupport"]
        ),
        .executable(
            name: "terminal-manager-selfcheck",
            targets: ["TerminalManagerSelfCheck"]
        ),
        .executable(
            name: "terminal-manager-local-e2e",
            targets: ["TerminalManagerLocalE2E"]
        ),
        .executable(
            name: "terminal-manager-ssh-smoke",
            targets: ["TerminalManagerSSHSmoke"]
        ),
        .executable(
            name: "terminal-manager-citadel-selfcheck",
            targets: ["TerminalManagerCitadelSelfCheck"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1")
    ],
    targets: [
        .target(
            name: "TerminalManagerCore"
        ),
        .target(
            name: "TerminalManagerCitadelSupport",
            dependencies: [
                "TerminalManagerCore",
                .product(name: "Citadel", package: "Citadel")
            ]
        ),
        .executableTarget(
            name: "TerminalManagerSelfCheck",
            dependencies: ["TerminalManagerCore"]
        ),
        .executableTarget(
            name: "TerminalManagerLocalE2E",
            dependencies: ["TerminalManagerCore"]
        ),
        .executableTarget(
            name: "TerminalManagerSSHSmoke",
            dependencies: ["TerminalManagerCore"]
        ),
        .executableTarget(
            name: "TerminalManagerCitadelSelfCheck",
            dependencies: ["TerminalManagerCitadelSupport"]
        )
    ]
)
