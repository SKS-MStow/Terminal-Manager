import Foundation
import TerminalManagerCore

enum SSHSmokeFailure: Error, CustomStringConvertible {
    case assertion(String)
    case invalidEnvironment(String)
    case missingExecutable(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        case .invalidEnvironment(let message):
            return message
        case .missingExecutable(let path):
            return "Missing executable: \(path)"
        }
    }
}

@main
struct TerminalManagerSSHSmoke {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("Terminal Manager SSH smoke failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        #if os(macOS)
        guard let live = try liveConfigurationFromEnvironment() else {
            print("Terminal Manager SSH smoke skipped: TERMINAL_MANAGER_SSH_HOST is not set")
            return
        }

        let shell = OpenSSHRemoteShell(host: live.host, configuration: live.shellConfiguration)
        let sessionName = "terminal-manager-ssh-\(UUID().uuidString.prefix(8))"
        let escapedName = shellQuote(sessionName)
        let marker = "terminal-manager-ssh-smoke"
        var createdSession = false

        do {
            _ = try checked(try await shell.run("tmux new-session -d -s '\(escapedName)' 'zsh'"), command: "ssh tmux new-session")
            createdSession = true
            _ = try checked(try await shell.run("tmux send-keys -t '\(escapedName)' -l -- 'printf \(marker)'"), command: "ssh tmux send marker")
            _ = try checked(try await shell.run("tmux send-keys -t '\(escapedName)' Enter"), command: "ssh tmux send enter")
            try await Task.sleep(nanoseconds: 300_000_000)

            let tmux = TmuxService(shell: shell)
            let terminalTransport = OpenSSHTerminalTransport(configuration: live.terminalConfiguration)
            let pipeline = TerminalPipeline(host: live.host, tmux: tmux, transport: terminalTransport)
            let snapshot = try await pipeline.discoverSessions()
            guard let session = snapshot.terminalSessions.first(where: { $0.tmuxSessionName == sessionName }) else {
                throw SSHSmokeFailure.assertion("remote tmux session was not discovered over SSH")
            }

            let history = try await pipeline.capturedHistory(for: session, lineCount: 100)
            try expect(history.contains(marker), "remote tmux history did not include marker")
            try await assertTerminalTransportStreamsMarker(marker, pipeline: pipeline, session: session, transport: terminalTransport)
            await cleanupRemoteTmuxSession(named: escapedName, shell: shell)
        } catch {
            if createdSession {
                await cleanupRemoteTmuxSession(named: escapedName, shell: shell)
            }
            throw error
        }

        print("Terminal Manager SSH smoke passed")
        #else
        print("Terminal Manager SSH smoke skipped: OpenSSH smoke is macOS-only")
        #endif
    }

    #if os(macOS)
    private struct LiveSSHConfiguration {
        var host: HostProfile
        var shellConfiguration: OpenSSHConfiguration
        var terminalConfiguration: OpenSSHConfiguration
    }

    private static func liveConfigurationFromEnvironment() throws -> LiveSSHConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        guard let hostname = environment["TERMINAL_MANAGER_SSH_HOST"], !hostname.isEmpty else {
            return nil
        }

        let username = environment["TERMINAL_MANAGER_SSH_USER"] ?? NSUserName()
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SSHSmokeFailure.invalidEnvironment("TERMINAL_MANAGER_SSH_USER must not be empty")
        }

        let port: Int
        if let portText = environment["TERMINAL_MANAGER_SSH_PORT"] {
            guard let parsedPort = Int(portText), parsedPort > 0, parsedPort <= 65_535 else {
                throw SSHSmokeFailure.invalidEnvironment("TERMINAL_MANAGER_SSH_PORT must be a valid TCP port")
            }
            port = parsedPort
        } else {
            port = 22
        }

        let executablePath = environment["TERMINAL_MANAGER_SSH_EXECUTABLE"] ?? "/usr/bin/ssh"
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw SSHSmokeFailure.missingExecutable(executablePath)
        }

        let identityFile = try readableFilePath(from: environment["TERMINAL_MANAGER_SSH_IDENTITY_FILE"], name: "TERMINAL_MANAGER_SSH_IDENTITY_FILE")
        let configFile = try readableFilePath(from: environment["TERMINAL_MANAGER_SSH_CONFIG_FILE"], name: "TERMINAL_MANAGER_SSH_CONFIG_FILE")
        let knownHostsFile = environment["TERMINAL_MANAGER_SSH_KNOWN_HOSTS_FILE"] ?? defaultSmokeKnownHostsPath()
        let strictHostKeyChecking = environment["TERMINAL_MANAGER_SSH_STRICT_HOST_KEY_CHECKING"] ?? "accept-new"
        let extraOptions = try parseExtraOptions(environment["TERMINAL_MANAGER_SSH_EXTRA_OPTIONS"])

        let host = HostProfile(
            displayName: "Live SSH",
            hostname: hostname,
            port: port,
            username: username,
            preferredTransport: .ssh
        )
        let shellConfig = OpenSSHConfiguration.smokeTest(
            userKnownHostsFile: knownHostsFile,
            identityFile: identityFile,
            configFile: configFile,
            strictHostKeyChecking: strictHostKeyChecking,
            extraOptions: extraOptions
        )
        let terminalConfig = OpenSSHConfiguration(
            executablePath: executablePath,
            connectTimeoutSeconds: shellConfig.connectTimeoutSeconds,
            batchMode: false,
            hostKeyPolicy: .acceptAnyForSmokeOnly,
            userKnownHostsFile: knownHostsFile,
            identityFile: identityFile,
            configFile: configFile,
            strictHostKeyCheckingOverride: strictHostKeyChecking,
            extraOptions: extraOptions
        )

        return LiveSSHConfiguration(host: host, shellConfiguration: shellConfig, terminalConfiguration: terminalConfig)
    }

    private static func assertTerminalTransportStreamsMarker(
        _ marker: String,
        pipeline: TerminalPipeline,
        session: TerminalSession,
        transport: OpenSSHTerminalTransport
    ) async throws {
        let stream = transport.screenBytes()
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

        try await pipeline.attach(to: session, size: TerminalSize(columns: 100, rows: 32))
        let output = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await reader.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw SSHSmokeFailure.assertion("timed out waiting for SSH terminal bytes")
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }

        try expect(output.contains(marker), "SSH terminal transport did not stream marker")
        await transport.disconnect()
    }

    private static func readableFilePath(from value: String?, name: String) throws -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }

        guard FileManager.default.isReadableFile(atPath: value) else {
            throw SSHSmokeFailure.invalidEnvironment("\(name) is not readable: \(value)")
        }

        return value
    }

    private static func parseExtraOptions(_ value: String?) throws -> [String] {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        return try value
            .split(separator: ",")
            .flatMap { rawOption -> [String] in
                let option = rawOption.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !option.isEmpty, !option.hasPrefix("-") else {
                    throw SSHSmokeFailure.invalidEnvironment("TERMINAL_MANAGER_SSH_EXTRA_OPTIONS must be comma-separated ssh -o options without leading '-'")
                }
                return ["-o", option]
            }
    }

    private static func defaultSmokeKnownHostsPath() -> String {
        NSTemporaryDirectory() + "terminal-manager-ssh-known-hosts-\(NSUserName())"
    }

    private static func cleanupRemoteTmuxSession(named escapedName: String, shell: OpenSSHRemoteShell) async {
        do {
            let result = try await shell.run("tmux kill-session -t '\(escapedName)' 2>/dev/null || true")
            if result.exitCode != 0 {
                fputs("Terminal Manager SSH smoke cleanup failed: \(result.stderr)\n", stderr)
            }
        } catch {
            fputs("Terminal Manager SSH smoke cleanup failed: \(error)\n", stderr)
        }
    }
    #endif

    private static func shellQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func checked(_ result: RemoteCommandResult, command: String) throws -> RemoteCommandResult {
        guard result.exitCode == 0 else {
            throw RemoteShellError.commandFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SSHSmokeFailure.assertion(message)
        }
    }
}
