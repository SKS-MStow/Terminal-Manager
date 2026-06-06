import Foundation

public struct RemoteCommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol RemoteShell: Sendable {
    func run(_ command: String) async throws -> RemoteCommandResult
}

public enum RemoteShellError: Error, Equatable {
    case commandFailed(command: String, exitCode: Int32, stderr: String)
}

public final actor StubRemoteShell: RemoteShell {
    private var responses: [String: RemoteCommandResult]
    private(set) public var commands: [String]

    public init(responses: [String: RemoteCommandResult] = [:]) {
        self.responses = responses
        self.commands = []
    }

    public func setResponse(_ result: RemoteCommandResult, for command: String) {
        responses[command] = result
    }

    public func run(_ command: String) async throws -> RemoteCommandResult {
        commands.append(command)
        if let result = responses[command] {
            return result
        }

        return RemoteCommandResult(exitCode: 0, stdout: "")
    }
}

#if os(macOS)
public final actor LocalShell: RemoteShell {
    public init() {}

    public func run(_ command: String) async throws -> RemoteCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: RemoteCommandResult(
                        exitCode: process.terminationStatus,
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? ""
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
#endif
