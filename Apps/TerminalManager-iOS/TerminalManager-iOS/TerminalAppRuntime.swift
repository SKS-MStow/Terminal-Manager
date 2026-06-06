import Foundation
import TerminalManagerCitadelSupport
import TerminalManagerCore

struct TerminalAppBootstrap: Sendable {
    var host: HostProfile
    var sessions: [TerminalSession]
    var selectedSession: TerminalSession
    var terminalLines: [String]
    var sidecarCards: [CompactedAgentActivityCard]
}

protocol TerminalAppRuntime: Sendable {
    func bootstrap() async throws -> TerminalAppBootstrap
    func refreshSessions() async throws -> [TerminalSession]
    func attach(to session: TerminalSession, size: TerminalSize) async throws
    func resizeTerminal(to size: TerminalSize) async throws
    func sendUserText(_ text: String) async throws
    func sendTerminalBytes(_ bytes: Data) async throws
    func terminalTextStream() -> AsyncThrowingStream<String, Error>
    func disconnect() async
}

enum TerminalAppRuntimeFactory {
    static func makeDefaultRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        connectionStore: SavedSSHConnectionStore = .shared
    ) -> any TerminalAppRuntime {
        if let configuration = LiveSSHTerminalAppRuntime.Configuration(environment: environment) {
            return LiveSSHTerminalAppRuntime(
                configuration: configuration,
                passwordProvider: StaticCitadelPasswordProvider(password: configuration.inlinePassword ?? "")
            )
        }

        if let savedConnection = connectionStore.load(),
           let configuration = LiveSSHTerminalAppRuntime.Configuration(savedConnection: savedConnection) {
            return LiveSSHTerminalAppRuntime(
                configuration: configuration,
                passwordProvider: KeychainPasswordProvider()
            )
        }

        return FixtureTerminalAppRuntime()
    }
}

private struct StaticCitadelPasswordProvider: CitadelPasswordProvider {
    var password: String

    func password(service: String, account: String) throws -> String {
        password
    }
}

@available(iOS 17.0, *)
final actor LiveSSHTerminalAppRuntime: TerminalAppRuntime {
    struct Configuration: Sendable, Equatable {
        var host: HostProfile
        var passwordService: String
        var passwordAccount: String
        var inlinePassword: String?
        var allowUnsafeHostKeyPolicy: Bool
        var pinnedHostKeySHA256: String?

        init?(
            environment: [String: String],
            prefix: String = "TERMINAL_MANAGER_LIVE_SSH_"
        ) {
            guard environment[prefix + "ENABLED"] == "1" else {
                return nil
            }

            guard
                let hostname = environment[prefix + "HOST"],
                !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }

            let username = environment[prefix + "USER"]
                ?? environment["USER"]
                ?? "mark"
            let password = environment[prefix + "PASSWORD"] ?? ""
            guard !password.isEmpty else {
                return nil
            }

            let allowUnsafeHostKeyPolicy = environment[prefix + "ALLOW_UNSAFE_HOST_KEY"] == "1"
            let pinnedHostKeySHA256 = environment[prefix + "PINNED_SHA256"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowUnsafeHostKeyPolicy || !(pinnedHostKeySHA256?.isEmpty ?? true) else {
                return nil
            }

            self.host = HostProfile(
                displayName: environment[prefix + "NAME"] ?? hostname,
                hostname: hostname,
                port: environment[prefix + "PORT"].flatMap(Int.init) ?? 22,
                username: username,
                preferredTransport: .ssh
            )
            self.passwordService = "TerminalManagerLiveSSH"
            self.passwordAccount = "\(username)@\(hostname)"
            self.inlinePassword = password
            self.allowUnsafeHostKeyPolicy = allowUnsafeHostKeyPolicy
            self.pinnedHostKeySHA256 = pinnedHostKeySHA256?.isEmpty == false ? pinnedHostKeySHA256 : nil
        }

        init?(savedConnection: SavedSSHConnection) {
            let pinnedHostKeySHA256 = savedConnection.pinnedHostKeySHA256?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard savedConnection.allowUnsafeHostKeyPolicy || !(pinnedHostKeySHA256?.isEmpty ?? true) else {
                return nil
            }

            self.host = savedConnection.host
            self.passwordService = SavedSSHConnectionStore.passwordService
            self.passwordAccount = SavedSSHConnectionStore.passwordAccount(for: savedConnection.host)
            self.inlinePassword = nil
            self.allowUnsafeHostKeyPolicy = savedConnection.allowUnsafeHostKeyPolicy
            self.pinnedHostKeySHA256 = pinnedHostKeySHA256?.isEmpty == false ? pinnedHostKeySHA256 : nil
        }
    }

    private let configuration: Configuration
    private let controller: TerminalSessionController

    init(configuration: Configuration, passwordProvider: any CitadelPasswordProvider) {
        self.configuration = configuration
        let profile = SSHConnectionProfile(
            host: configuration.host,
            authentication: .passwordKeychain(
                service: configuration.passwordService,
                account: configuration.passwordAccount
            ),
            hostKeyPolicy: Self.hostKeyPolicy(for: configuration)
        )
        let factory = CitadelConnectionFactory(
            allowUnsafeHostKeyPolicy: configuration.allowUnsafeHostKeyPolicy,
            passwordProvider: passwordProvider
        )
        self.controller = TerminalSessionController(
            pipeline: TerminalPipeline(
                host: configuration.host,
                tmux: TmuxService(shell: CitadelRemoteShell(profile: profile, factory: factory)),
                transport: CitadelTerminalTransport(profile: profile, factory: factory)
            )
        )
    }

    private static func hostKeyPolicy(for configuration: Configuration) -> SSHHostKeyPolicy {
        if let pinnedHostKeySHA256 = configuration.pinnedHostKeySHA256,
           !pinnedHostKeySHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .pinnedSHA256(pinnedHostKeySHA256)
        }
        if configuration.allowUnsafeHostKeyPolicy {
            return .acceptAnyForSmokeOnly
        }
        return .knownHosts
    }

    nonisolated func terminalTextStream() -> AsyncThrowingStream<String, Error> {
        decodedTerminalTextStream(from: controller.screenBytes())
    }

    func bootstrap() async throws -> TerminalAppBootstrap {
        let snapshot = try await controller.discoverSessions()
        let sessions = snapshot.terminalSessions
        let selectedSession = sessions.first ?? TerminalSession(
            hostId: configuration.host.id,
            tmuxSessionName: "no-session",
            title: "No tmux sessions",
            workingDirectory: nil
        )
        return TerminalAppBootstrap(
            host: snapshot.host,
            sessions: sessions,
            selectedSession: selectedSession,
            terminalLines: [
                "Terminal Manager live SSH runtime",
                "Connected to \(configuration.host.username)@\(configuration.host.hostname)",
                "Discovered \(sessions.count) tmux sessions"
            ],
            sidecarCards: PreviewFixtures.sidecarCards
        )
    }

    func refreshSessions() async throws -> [TerminalSession] {
        try await controller.discoverSessions().terminalSessions
    }

    func attach(to session: TerminalSession, size: TerminalSize) async throws {
        guard !session.tmuxSessionName.isEmpty, session.tmuxSessionName != "no-session" else {
            return
        }

        try await controller.attach(to: session, size: size)
    }

    func resizeTerminal(to size: TerminalSize) async throws {
        try await controller.resizeTerminal(to: size)
    }

    func sendUserText(_ text: String) async throws {
        try await controller.sendUserText(text)
    }

    func sendTerminalBytes(_ bytes: Data) async throws {
        try await controller.sendTerminalBytes(bytes)
    }

    func disconnect() async {
        await controller.disconnect()
    }
}

final actor FixtureTerminalAppRuntime: TerminalAppRuntime {
    private let host: HostProfile
    private let transport: RecordingTerminalTransport
    private let controller: TerminalSessionController

    init() {
        self.host = PreviewFixtures.host
        self.transport = RecordingTerminalTransport(kind: .ssh)
        let shell = StubRemoteShell(responses: Self.tmuxResponses(for: PreviewFixtures.sessions))
        self.controller = TerminalSessionController(
            pipeline: TerminalPipeline(
                host: host,
                tmux: TmuxService(shell: shell),
                transport: transport
            )
        )
    }

    nonisolated func terminalTextStream() -> AsyncThrowingStream<String, Error> {
        decodedTerminalTextStream(from: transport.screenBytes())
    }

    func bootstrap() async throws -> TerminalAppBootstrap {
        let snapshot = try await controller.discoverSessions()
        let sessions = snapshot.terminalSessions.isEmpty ? PreviewFixtures.sessions : snapshot.terminalSessions
        let selectedSession = sessions.first ?? PreviewFixtures.sessions[0]
        return TerminalAppBootstrap(
            host: snapshot.host,
            sessions: sessions,
            selectedSession: selectedSession,
            terminalLines: PreviewFixtures.terminalLines,
            sidecarCards: PreviewFixtures.sidecarCards
        )
    }

    func refreshSessions() async throws -> [TerminalSession] {
        let snapshot = try await controller.discoverSessions()
        return snapshot.terminalSessions.isEmpty ? PreviewFixtures.sessions : snapshot.terminalSessions
    }

    func attach(to session: TerminalSession, size: TerminalSize) async throws {
        try await controller.attach(to: session, size: size)
    }

    func resizeTerminal(to size: TerminalSize) async throws {
        try await controller.resizeTerminal(to: size)
    }

    func sendUserText(_ text: String) async throws {
        try await controller.sendUserText(text)
    }

    func sendTerminalBytes(_ bytes: Data) async throws {
        try await controller.sendTerminalBytes(bytes)
    }

    func disconnect() async {
        await controller.disconnect()
    }

    private static func tmuxResponses(for sessions: [TerminalSession]) -> [String: RemoteCommandResult] {
        let sessionRows = sessions
            .map { session in
                "\(session.tmuxSessionName)\t1\t\(session.tmuxSessionName == sessions.first?.tmuxSessionName ? "1" : "0")"
            }
            .joined(separator: "\n")

        let paneRows = sessions
            .enumerated()
            .map { index, session in
                let command = session.agent?.rawValue ?? "zsh"
                return [
                    session.tmuxSessionName,
                    "\(session.windowIndex ?? 0)",
                    session.paneId ?? "%\(index + 1)",
                    session.title,
                    command,
                    session.workingDirectory ?? "~",
                    session.tmuxSessionName == sessions.first?.tmuxSessionName ? "1" : "0",
                    "1"
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")

        return [
            "tmux list-sessions -F '#S\t#{session_windows}\t#{session_attached}'": RemoteCommandResult(
                exitCode: 0,
                stdout: sessionRows + "\n"
            ),
            "tmux list-panes -a -F '#S\t#I\t#D\t#T\t#{pane_current_command}\t#{pane_current_path}\t#{window_active}\t#{pane_active}'": RemoteCommandResult(
                exitCode: 0,
                stdout: paneRows + "\n"
            )
        ]
    }
}

private func decodedTerminalTextStream(
    from byteStream: AsyncThrowingStream<Data, Error>
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var decoder = TerminalUTF8StreamDecoder()
            do {
                for try await data in byteStream {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    let text = decoder.append(data)
                    if !text.isEmpty {
                        continuation.yield(text)
                    }
                }

                let remaining = decoder.finish()
                if !remaining.isEmpty {
                    continuation.yield(remaining)
                }
                continuation.finish()
            } catch {
                let remaining = decoder.finish()
                if !remaining.isEmpty {
                    continuation.yield(remaining)
                }
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}
