import Foundation
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
