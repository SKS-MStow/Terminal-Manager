import Foundation

public protocol TerminalTransport: Sendable {
    var kind: TerminalTransportKind { get }

    /// Opens an interactive shell backed by a PTY on the remote host.
    /// Callers may send shell commands, control characters, and resize events
    /// after this succeeds.
    func connect(to host: HostProfile, size: TerminalSize) async throws
    func disconnect() async
    func send(_ bytes: Data) async throws
    func resize(to size: TerminalSize) async throws
    func screenBytes() -> AsyncThrowingStream<Data, Error>
}

public enum TerminalTransportError: Error, Equatable {
    case notConnected
    case unsupported(String)
}

public final actor RecordingTerminalTransport: TerminalTransport {
    public nonisolated let kind: TerminalTransportKind

    private var connectedHost: HostProfile?
    private var terminalSize: TerminalSize
    private var writes: [Data]
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    public init(kind: TerminalTransportKind = .ssh, size: TerminalSize = TerminalSize()) {
        self.kind = kind
        self.terminalSize = size
        self.writes = []

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        self.stream = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
    }

    public func connect(to host: HostProfile, size: TerminalSize) async throws {
        connectedHost = host
        terminalSize = size
    }

    public func disconnect() async {
        connectedHost = nil
        continuation.finish()
    }

    public func send(_ bytes: Data) async throws {
        guard connectedHost != nil else {
            throw TerminalTransportError.notConnected
        }

        writes.append(bytes)
        continuation.yield(bytes)
    }

    public func resize(to size: TerminalSize) async throws {
        guard connectedHost != nil else {
            throw TerminalTransportError.notConnected
        }

        terminalSize = size
    }

    public nonisolated func screenBytes() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    public func recordedWrites() -> [Data] {
        writes
    }

    public func currentSize() -> TerminalSize {
        terminalSize
    }
}

#if os(macOS)
public final actor ShellProcessTerminalTransport: TerminalTransport {
    public nonisolated let kind: TerminalTransportKind = .ssh

    private let executablePath: String
    private let arguments: [String]
    private var process: Process?
    private var stdinPipe: Pipe?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    public init(executablePath: String = "/bin/zsh", arguments: [String] = ["-l"]) {
        self.executablePath = executablePath
        self.arguments = arguments

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
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

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

        // Process pipes do not expose a local PTY resize. Real SSH/Mosh transports
        // must turn this into a remote TTY resize.
    }

    public nonisolated func screenBytes() -> AsyncThrowingStream<Data, Error> {
        stream
    }
}
#endif
