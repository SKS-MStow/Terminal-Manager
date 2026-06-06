import Foundation

#if os(macOS)
public struct OpenSSHConfiguration: Equatable, Sendable {
    public var executablePath: String
    public var connectTimeoutSeconds: Int
    public var batchMode: Bool
    public var strictHostKeyChecking: String?
    public var extraOptions: [String]

    public init(
        executablePath: String = "/usr/bin/ssh",
        connectTimeoutSeconds: Int = 5,
        batchMode: Bool = true,
        strictHostKeyChecking: String? = "accept-new",
        extraOptions: [String] = []
    ) {
        self.executablePath = executablePath
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.batchMode = batchMode
        self.strictHostKeyChecking = strictHostKeyChecking
        self.extraOptions = extraOptions
    }
}

public enum OpenSSHCommandBuilder {
    public static func remoteShellArguments(for host: HostProfile, configuration: OpenSSHConfiguration = OpenSSHConfiguration()) -> [String] {
        var arguments = commonArguments(for: host, configuration: configuration)
        arguments.append("-T")
        arguments.append(destination(for: host))
        return arguments
    }

    public static func terminalArguments(for host: HostProfile, configuration: OpenSSHConfiguration = OpenSSHConfiguration(batchMode: false)) -> [String] {
        var arguments = commonArguments(for: host, configuration: configuration)
        arguments.append("-tt")
        arguments.append(destination(for: host))
        return arguments
    }

    private static func commonArguments(for host: HostProfile, configuration: OpenSSHConfiguration) -> [String] {
        var arguments: [String] = [
            "-p", "\(host.port)",
            "-o", "ConnectTimeout=\(configuration.connectTimeoutSeconds)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2"
        ]

        if configuration.batchMode {
            arguments.append(contentsOf: ["-o", "BatchMode=yes"])
        }

        if let strictHostKeyChecking = configuration.strictHostKeyChecking {
            arguments.append(contentsOf: ["-o", "StrictHostKeyChecking=\(strictHostKeyChecking)"])
        }

        arguments.append(contentsOf: configuration.extraOptions)
        return arguments
    }

    private static func destination(for host: HostProfile) -> String {
        "\(host.username)@\(host.hostname)"
    }
}

public final actor OpenSSHRemoteShell: RemoteShell {
    private let host: HostProfile
    private let configuration: OpenSSHConfiguration

    public init(host: HostProfile, configuration: OpenSSHConfiguration = OpenSSHConfiguration()) {
        self.host = host
        self.configuration = configuration
    }

    public func run(_ command: String) async throws -> RemoteCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: configuration.executablePath)
            process.arguments = OpenSSHCommandBuilder.remoteShellArguments(for: host, configuration: configuration) + [command]

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

public final actor OpenSSHTerminalTransport: TerminalTransport {
    public nonisolated let kind: TerminalTransportKind = .ssh

    private let configuration: OpenSSHConfiguration
    private var process: Process?
    private var stdinPipe: Pipe?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    public init(configuration: OpenSSHConfiguration = OpenSSHConfiguration(batchMode: false)) {
        self.configuration = configuration

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        self.stream = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
    }

    public func connect(to host: HostProfile, size: TerminalSize) async throws {
        guard process == nil else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = OpenSSHCommandBuilder.terminalArguments(for: host, configuration: configuration)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [continuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [continuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }

        process.terminationHandler = { [continuation] _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
        }

        try process.run()
        self.process = process
        self.stdinPipe = stdinPipe
    }

    public func disconnect() async {
        process?.terminate()
        process = nil
        stdinPipe = nil
        continuation.finish()
    }

    public func send(_ bytes: Data) async throws {
        guard let stdinPipe else {
            throw TerminalTransportError.notConnected
        }

        try stdinPipe.fileHandleForWriting.write(contentsOf: bytes)
    }

    public func resize(to size: TerminalSize) async throws {
        guard process != nil else {
            throw TerminalTransportError.notConnected
        }

        // OpenSSH CLI has no post-connect window-change API through Process pipes.
        // The iOS Citadel transport must map this to SSH channel window-change.
    }

    public nonisolated func screenBytes() -> AsyncThrowingStream<Data, Error> {
        stream
    }
}
#endif
