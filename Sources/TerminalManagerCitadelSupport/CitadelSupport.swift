@preconcurrency import Citadel
import Foundation
import NIO
import NIOSSH
import TerminalManagerCore

public enum CitadelSupportError: Error, Equatable {
    case unsupportedAuthentication(SSHAuthenticationReference)
    case unsupportedHostKeyPolicy(SSHHostKeyPolicy)
    case passwordNotAvailable(service: String, account: String)
    case unsafeHostKeyPolicyNotAllowed
    case invalidPrivateKey(path: String)
    case missingPrivateKey(path: String)
    case notConnected
    case ptyStartupFailed
    case ptyStartupTimedOut
}

public protocol CitadelPasswordProvider: Sendable {
    func password(service: String, account: String) throws -> String
}

public struct CitadelConnectionFactory: Sendable {
    public var allowUnsafeHostKeyPolicy: Bool
    private let passwordProvider: (any CitadelPasswordProvider)?

    public init(
        allowUnsafeHostKeyPolicy: Bool = false,
        passwordProvider: (any CitadelPasswordProvider)? = nil
    ) {
        self.allowUnsafeHostKeyPolicy = allowUnsafeHostKeyPolicy
        self.passwordProvider = passwordProvider
    }

    public func settings(for profile: SSHConnectionProfile) throws -> SSHClientSettings {
        let validator = try hostKeyValidator(for: profile.hostKeyPolicy)
        let authenticationMethod = try authenticationMethodProvider(for: profile)
        return SSHClientSettings(
            host: profile.host.hostname,
            port: profile.host.port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: validator
        )
    }

    private func authenticationMethodProvider(for profile: SSHConnectionProfile) throws -> @Sendable () -> SSHAuthenticationMethod {
        switch profile.authentication {
        case .none, .agent:
            throw CitadelSupportError.unsupportedAuthentication(profile.authentication)
        case .passwordKeychain(let service, let account):
            guard let passwordProvider else {
                throw CitadelSupportError.passwordNotAvailable(service: service, account: account)
            }

            let username = profile.host.username
            let password = try passwordProvider.password(service: service, account: account)
            return {
                .passwordBased(username: username, password: password)
            }
        case .privateKeyFile(let path, _):
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw CitadelSupportError.missingPrivateKey(path: path)
            }
            throw CitadelSupportError.invalidPrivateKey(path: path)
        }
    }

    private func hostKeyValidator(for policy: SSHHostKeyPolicy) throws -> SSHHostKeyValidator {
        switch policy {
        case .knownHosts, .pinnedSHA256:
            throw CitadelSupportError.unsupportedHostKeyPolicy(policy)
        case .acceptAnyForSmokeOnly:
            guard allowUnsafeHostKeyPolicy else {
                throw CitadelSupportError.unsafeHostKeyPolicyNotAllowed
            }
            return .acceptAnything()
        }
    }
}

public final actor CitadelRemoteShell: RemoteShell {
    private let profile: SSHConnectionProfile
    private let factory: CitadelConnectionFactory

    public init(profile: SSHConnectionProfile, factory: CitadelConnectionFactory = CitadelConnectionFactory()) {
        self.profile = profile
        self.factory = factory
    }

    public func run(_ command: String) async throws -> RemoteCommandResult {
        let client = try await SSHClient.connect(to: try factory.settings(for: profile))
        do {
            let result = try await execute(command, using: client)
            try await client.close()
            return result
        } catch {
            try? await client.close()
            throw error
        }
    }

    private func execute(_ command: String, using client: SSHClient) async throws -> RemoteCommandResult {
        let stream = try await client.executeCommandStream(command)
        var stdout = ""
        var stderr = ""

        do {
            for try await output in stream {
                switch output {
                case .stdout(var buffer):
                    stdout += buffer.readString(length: buffer.readableBytes) ?? ""
                case .stderr(var buffer):
                    stderr += buffer.readString(length: buffer.readableBytes) ?? ""
                }
            }
            return RemoteCommandResult(exitCode: 0, stdout: stdout, stderr: stderr)
        } catch let error as SSHClient.CommandFailed {
            return RemoteCommandResult(exitCode: Int32(error.exitCode), stdout: stdout, stderr: stderr)
        }
    }
}

public final actor CitadelAttachmentUploader: AttachmentUploader {
    private let profile: SSHConnectionProfile
    private let factory: CitadelConnectionFactory

    public init(profile: SSHConnectionProfile, factory: CitadelConnectionFactory = CitadelConnectionFactory()) {
        self.profile = profile
        self.factory = factory
    }

    public func upload(_ attachment: PendingAttachment, to remotePath: String) async throws -> PendingAttachment {
        guard FileManager.default.fileExists(atPath: attachment.localURL.path) else {
            throw AttachmentUploadError.sourceMissing(attachment.localURL.path)
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: attachment.localURL.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            throw AttachmentUploadError.sourceIsDirectory(attachment.localURL.path)
        }

        let data = try Data(contentsOf: attachment.localURL)
        let client = try await SSHClient.connect(to: try factory.settings(for: profile))
        do {
            try await client.withSFTP { [self] sftp in
                let sftpPath = try await self.resolveSFTPPath(remotePath, using: sftp)
                try await self.createParentDirectories(for: sftpPath, using: sftp)
                try await sftp.withFile(
                    filePath: sftpPath,
                    flags: [.write, .create, .truncate]
                ) { file in
                    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    try await file.write(buffer)
                }
            }

            try await client.close()
            var uploaded = attachment
            uploaded.remotePath = remotePath
            return uploaded
        } catch {
            try? await client.close()
            throw error
        }
    }

    private func resolveSFTPPath(_ remotePath: String, using sftp: SFTPClient) async throws -> String {
        if remotePath == "~" {
            return try await sftp.getRealPath(atPath: "~")
        }

        if remotePath.hasPrefix("~/") {
            let home = try await sftp.getRealPath(atPath: "~")
            return "\(home)/\(remotePath.dropFirst(2))"
        }

        return remotePath
    }

    private func createParentDirectories(for remotePath: String, using sftp: SFTPClient) async throws {
        let parts = remotePath.split(separator: "/").map(String.init)
        guard parts.count > 1 else {
            return
        }

        var current = remotePath.hasPrefix("/") ? "/" : ""
        for part in parts.dropLast() {
            current = current.isEmpty || current == "/"
                ? "\(current)\(part)"
                : "\(current)/\(part)"
            do {
                try await sftp.createDirectory(atPath: current)
            } catch {
                // SFTP servers differ in how they report an existing directory.
                // Continue here so upload remains idempotent; openFile still fails
                // if the path is actually unusable.
            }
        }
    }
}

@available(macOS 15.0, iOS 17.0, *)
public final actor CitadelTerminalTransport: TerminalTransport {
    public nonisolated let kind: TerminalTransportKind = .ssh

    private let profile: SSHConnectionProfile
    private let factory: CitadelConnectionFactory
    private var client: SSHClient?
    private let writerBox = CitadelTTYWriterBox()
    private var task: Task<Void, Error>?
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    public init(profile: SSHConnectionProfile, factory: CitadelConnectionFactory = CitadelConnectionFactory()) {
        self.profile = profile
        self.factory = factory

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        self.stream = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
    }

    public func connect(to host: HostProfile, size: TerminalSize) async throws {
        guard client == nil else {
            return
        }

        let client = try await SSHClient.connect(to: try factory.settings(for: profile))
        self.client = client
        let continuation = self.continuation
        let writerBox = self.writerBox
        task = Task {
            do {
                try await client.withPTY(
                    SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true,
                        term: "xterm-256color",
                        terminalCharacterWidth: size.columns,
                        terminalRowHeight: size.rows,
                        terminalPixelWidth: 0,
                        terminalPixelHeight: 0,
                        terminalModes: .init([:])
                    )
                ) { inbound, outbound in
                    writerBox.set(outbound)
                    for try await output in inbound {
                        switch output {
                        case .stdout(var buffer), .stderr(var buffer):
                            if let data = buffer.readData(length: buffer.readableBytes) {
                                continuation.yield(data)
                            }
                        }
                    }
                }
                continuation.finish()
            } catch {
                writerBox.fail()
                continuation.finish(throwing: error)
            }
        }

        for _ in 0..<100 {
            if writerBox.current() != nil {
                return
            }

            if writerBox.didFail {
                throw CitadelSupportError.ptyStartupFailed
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        throw CitadelSupportError.ptyStartupTimedOut
    }

    public func disconnect() async {
        task?.cancel()
        task = nil
        writerBox.clear()
        try? await client?.close()
        client = nil
        continuation.finish()
    }

    public func send(_ bytes: Data) async throws {
        guard let writer = writerBox.current() else {
            throw TerminalTransportError.notConnected
        }

        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await writer.write(buffer)
    }

    public func resize(to size: TerminalSize) async throws {
        guard let writer = writerBox.current() else {
            throw TerminalTransportError.notConnected
        }

        try await writer.changeSize(cols: size.columns, rows: size.rows, pixelWidth: 0, pixelHeight: 0)
    }

    public nonisolated func screenBytes() -> AsyncThrowingStream<Data, Error> {
        stream
    }
}

@available(macOS 15.0, iOS 17.0, *)
private final class CitadelTTYWriterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: TTYStdinWriter?
    private var failed = false

    func set(_ writer: TTYStdinWriter) {
        lock.withLock {
            self.writer = writer
            failed = false
        }
    }

    func current() -> TTYStdinWriter? {
        lock.withLock {
            writer
        }
    }

    func clear() {
        lock.withLock {
            writer = nil
            failed = false
        }
    }

    func fail() {
        lock.withLock {
            writer = nil
            failed = true
        }
    }

    var didFail: Bool {
        lock.withLock {
            failed
        }
    }
}
