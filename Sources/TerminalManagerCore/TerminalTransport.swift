import Foundation

public protocol TerminalTransport: Sendable {
    var kind: TerminalTransportKind { get }

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
