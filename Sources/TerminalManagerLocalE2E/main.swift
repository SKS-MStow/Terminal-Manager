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

        do {
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
            try await checkAttachmentUpload(pipeline: pipeline, session: session)
            let writes = await transport.recordedWrites().compactMap { String(data: $0, encoding: .utf8) }
            try expect(writes.first == "tmux attach-session -t '\(sessionName)'\r", "pipeline did not emit expected attach command")
            try expect(writes.last == "~/TerminalManager/attachments/\(sessionName)/e2e-photo.png\r", "pipeline did not emit expected uploaded attachment path")

            try await checkControllerRuntime(host: host, shell: shell, sessionName: sessionName)
            try await checkShellProcessTransport(host: host)
            try await checkEnvGatedOpenSSH()
            try await cleanupTmuxSession(named: escapedName, shell: shell)
        } catch {
            try await cleanupTmuxSession(named: escapedName, shell: shell)
            throw error
        }

        print("Terminal Manager local tmux E2E passed")
        #else
        throw LocalE2EFailure.assertion("local tmux E2E is macOS-only")
        #endif
    }

    #if os(macOS)
    private static func checkEnvGatedOpenSSH() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let hostname = environment["TERMINAL_MANAGER_SSH_HOST"], !hostname.isEmpty else {
            return
        }

        let username = environment["TERMINAL_MANAGER_SSH_USER"] ?? NSUserName()
        let port = environment["TERMINAL_MANAGER_SSH_PORT"].flatMap(Int.init) ?? 22
        let host = HostProfile(
            displayName: "Live SSH",
            hostname: hostname,
            port: port,
            username: username,
            preferredTransport: .ssh
        )
        let shell = OpenSSHRemoteShell(host: host)
        let result = try await shell.run("tmux list-sessions -F '#S'")
        let checkedResult = try checked(result, command: "ssh tmux list-sessions")
        try expect(!checkedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "live SSH tmux session list was empty")
    }

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

    private static func checkControllerRuntime(host: HostProfile, shell: LocalShell, sessionName: String) async throws {
        let transport = RecordingTerminalTransport()
        let controller = TerminalSessionController(
            pipeline: TerminalPipeline(
                host: host,
                tmux: TmuxService(shell: shell),
                transport: transport
            )
        )
        let stream = controller.screenBytes()
        let marker = "terminal-manager-controller-e2e"
        let reader = Task<String, Error> {
            var collected = ""
            for try await chunk in stream {
                collected += String(data: chunk, encoding: .utf8) ?? ""
                if collected.contains(marker) {
                    return collected
                }
            }
            return collected
        }

        let snapshot = try await controller.discoverSessions()
        guard let session = snapshot.terminalSessions.first(where: { $0.tmuxSessionName == sessionName }) else {
            throw LocalE2EFailure.assertion("controller did not discover temporary tmux session")
        }

        try await controller.attach(to: session, size: TerminalSize(columns: 100, rows: 32))
        try await controller.resizeTerminal(to: TerminalSize(columns: 120, rows: 36))
        try await controller.sendUserText(marker)

        let output = try await reader.value
        let writes = await transport.recordedWrites().compactMap { String(data: $0, encoding: .utf8) }
        let size = await transport.currentSize()

        try expect(output.contains("tmux attach-session -t '\(sessionName)'"), "controller stream did not include attach command")
        try expect(output.contains(marker), "controller stream did not include sent marker")
        try expect(size == TerminalSize(columns: 120, rows: 36), "controller resize did not update transport size")
        try expect(writes == [
            "tmux attach-session -t '\(sessionName)'\r",
            "\(marker)\r"
        ], "controller did not emit expected writes")
    }

    private static func checkAttachmentUpload(
        pipeline: TerminalPipeline,
        session: TerminalSession
    ) async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("terminal-manager-local-upload-\(UUID().uuidString)")
        let localFile = tempRoot.appendingPathComponent("local/e2e photo.png")
        let remoteRoot = tempRoot.appendingPathComponent("remote")

        try fileManager.createDirectory(at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local-e2e-attachment".utf8).write(to: localFile)
        defer {
            try? fileManager.removeItem(at: tempRoot)
        }

        let uploader = LocalFilesystemAttachmentUploader(remoteRoot: remoteRoot)
        let uploaded = try await pipeline.uploadAttachmentAndSendReference(
            PendingAttachment(localURL: localFile, kind: .image),
            in: session,
            using: uploader
        )
        let remotePath = uploaded.remotePath ?? ""
        let copiedFile = remoteRoot
            .appendingPathComponent(session.tmuxSessionName)
            .appendingPathComponent("e2e-photo.png")

        try expect(remotePath == "~/TerminalManager/attachments/\(session.tmuxSessionName)/e2e-photo.png", "local E2E uploaded remote path was wrong")
        try expect(fileManager.fileExists(atPath: copiedFile.path), "local E2E attachment was not copied")
        let copiedBytes = try Data(contentsOf: copiedFile)
        try expect(copiedBytes == Data("local-e2e-attachment".utf8), "local E2E copied bytes were wrong")
    }

    private static func requireTool(_ tool: String, shell: LocalShell) async throws {
        let result = try await shell.run("command -v \(tool)")
        guard result.exitCode == 0 else {
            throw LocalE2EFailure.missingTool(tool)
        }
    }

    private static func cleanupTmuxSession(named escapedName: String, shell: LocalShell) async throws {
        let result = try await shell.run("tmux kill-session -t '\(escapedName)' 2>/dev/null || true")
        guard result.exitCode == 0 else {
            throw RemoteShellError.commandFailed(command: "tmux kill-session", exitCode: result.exitCode, stderr: result.stderr)
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
