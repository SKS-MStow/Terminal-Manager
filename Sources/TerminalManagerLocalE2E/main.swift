import Foundation
import TerminalManagerCore

enum LocalE2EFailure: Error, CustomStringConvertible {
    case assertion(String)
    case missingTool(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        case .missingTool(let tool):
            return "Missing required tool: \(tool)"
        }
    }
}

@main
struct TerminalManagerLocalE2E {
    static func main() async throws {
        #if os(macOS)
        let shell = LocalShell()
        try await requireTool("tmux", shell: shell)

        let sessionName = "terminal-manager-e2e-\(UUID().uuidString.prefix(8))"
        let cwd = FileManager.default.currentDirectoryPath
        let escapedName = shellQuote(sessionName)
        let escapedCwd = shellQuote(cwd)

        defer {
            Task {
                _ = try? await shell.run("tmux kill-session -t '\(escapedName)'")
            }
        }

        _ = try checked(try await shell.run("tmux new-session -d -s '\(escapedName)' -c '\(escapedCwd)' 'zsh'"), command: "tmux new-session")
        _ = try checked(try await shell.run("tmux send-keys -t '\(escapedName)' -l -- 'printf terminal-manager-e2e'"), command: "tmux send-keys literal")
        _ = try checked(try await shell.run("tmux send-keys -t '\(escapedName)' Enter"), command: "tmux send-keys enter")
        try await Task.sleep(nanoseconds: 300_000_000)

        let host = HostProfile(displayName: "Local Mac", hostname: "localhost", username: NSUserName(), preferredTransport: .ssh)
        let tmux = TmuxService(shell: shell)
        let transport = RecordingTerminalTransport()
        let pipeline = TerminalPipeline(host: host, tmux: tmux, transport: transport)

        let snapshot = try await pipeline.discoverSessions()
        guard let session = snapshot.terminalSessions.first(where: { $0.tmuxSessionName == sessionName }) else {
            throw LocalE2EFailure.assertion("temporary tmux session was not discovered")
        }

        let history = try await pipeline.capturedHistory(for: session, lineCount: 100)
        try expect(history.contains("terminal-manager-e2e"), "captured history did not include marker")

        try await pipeline.attach(to: session, size: TerminalSize(columns: 100, rows: 32))
        let writes = await transport.recordedWrites().compactMap { String(data: $0, encoding: .utf8) }
        try expect(writes.first == "tmux attach-session -t '\(sessionName)'\r", "pipeline did not emit expected attach command")

        try await checkShellProcessTransport(host: host)

        _ = try checked(try await shell.run("tmux kill-session -t '\(escapedName)'"), command: "tmux kill-session")
        print("Terminal Manager local tmux E2E passed")
        #else
        throw LocalE2EFailure.assertion("local tmux E2E is macOS-only")
        #endif
    }

    #if os(macOS)
    private static func checkShellProcessTransport(host: HostProfile) async throws {
        let transport = ShellProcessTerminalTransport(executablePath: "/bin/cat", arguments: [])
        let stream = transport.screenBytes()
        let marker = "terminal-manager-transport-e2e"

        let reader = Task<String, Error> {
            var collected = ""
            for try await chunk in stream {
                if let text = String(data: chunk, encoding: .utf8) {
                    collected += text
                    if collected.contains(marker) {
                        return collected
                    }
                }
            }
            return collected
        }

        try await transport.connect(to: host, size: TerminalSize(columns: 100, rows: 32))
        try await transport.send(Data("\(marker)\n".utf8))
        try await Task.sleep(nanoseconds: 200_000_000)
        await transport.disconnect()

        let output = try await reader.value
        try expect(output.contains(marker), "shell process transport did not stream marker")
    }

    private static func requireTool(_ tool: String, shell: LocalShell) async throws {
        let result = try await shell.run("command -v \(tool)")
        guard result.exitCode == 0 else {
            throw LocalE2EFailure.missingTool(tool)
        }
    }

    private static func checked(_ result: RemoteCommandResult, command: String) throws -> RemoteCommandResult {
        guard result.exitCode == 0 else {
            throw RemoteShellError.commandFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }
    #endif

    private static func shellQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw LocalE2EFailure.assertion(message)
        }
    }
}
