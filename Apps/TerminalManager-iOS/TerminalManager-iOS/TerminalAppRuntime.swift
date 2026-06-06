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
    func attach(to session: TerminalSession, size: TerminalSize) async throws
    func sendUserText(_ text: String) async throws
    func terminalTextStream() -> AsyncThrowingStream<String, Error>
}

enum TerminalAppRuntimeFactory {
    static func makeDefaultRuntime(environment: [String: String] = ProcessInfo.processInfo.environment) -> any TerminalAppRuntime {
        if let configuration = LiveSSHTerminalAppRuntime.Configuration(environment: environment) {
            return LiveSSHTerminalAppRuntime(configuration: configuration)
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
        var password: String
        var allowUnsafeHostKeyPolicy: Bool

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
            guard allowUnsafeHostKeyPolicy else {
                return nil
            }

            self.host = HostProfile(
                displayName: environment[prefix + "NAME"] ?? hostname,
                hostname: hostname,
                port: environment[prefix + "PORT"].flatMap(Int.init) ?? 22,
                username: username,
                preferredTransport: .ssh
            )
            self.password = password
            self.allowUnsafeHostKeyPolicy = allowUnsafeHostKeyPolicy
        }
    }

    private let configuration: Configuration
    private let controller: TerminalSessionController

    init(configuration: Configuration) {
        self.configuration = configuration
        let profile = SSHConnectionProfile(
            host: configuration.host,
            authentication: .passwordKeychain(
                service: "TerminalManagerLiveSSH",
                account: "\(configuration.host.username)@\(configuration.host.hostname)"
            ),
            hostKeyPolicy: configuration.allowUnsafeHostKeyPolicy ? .acceptAnyForSmokeOnly : .knownHosts
        )
        let factory = CitadelConnectionFactory(
            allowUnsafeHostKeyPolicy: configuration.allowUnsafeHostKeyPolicy,
            passwordProvider: StaticCitadelPasswordProvider(password: configuration.password)
        )
        self.controller = TerminalSessionController(
            pipeline: TerminalPipeline(
                host: configuration.host,
                tmux: TmuxService(shell: CitadelRemoteShell(profile: profile, factory: factory)),
                transport: CitadelTerminalTransport(profile: profile, factory: factory)
            )
        )
    }

    nonisolated func terminalTextStream() -> AsyncThrowingStream<String, Error> {
        let byteStream = controller.screenBytes()
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await data in byteStream {
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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

    func attach(to session: TerminalSession, size: TerminalSize) async throws {
        guard !session.tmuxSessionName.isEmpty, session.tmuxSessionName != "no-session" else {
            return
        }

        try await controller.attach(to: session, size: size)
    }

    func sendUserText(_ text: String) async throws {
        try await controller.sendUserText(text)
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
        let byteStream = transport.screenBytes()
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await data in byteStream {
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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

    func attach(to session: TerminalSession, size: TerminalSize) async throws {
        try await controller.attach(to: session, size: size)
    }

    func sendUserText(_ text: String) async throws {
        try await controller.sendUserText(text)
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
                    session.workingDirectory ?? "~"
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")

        return [
            "tmux list-sessions -F '#S\t#{session_windows}\t#{session_attached}'": RemoteCommandResult(
                exitCode: 0,
                stdout: sessionRows + "\n"
            ),
            "tmux list-panes -a -F '#S\t#I\t#D\t#T\t#{pane_current_command}\t#{pane_current_path}'": RemoteCommandResult(
                exitCode: 0,
                stdout: paneRows + "\n"
            )
        ]
    }
}
