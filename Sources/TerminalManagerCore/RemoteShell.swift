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
