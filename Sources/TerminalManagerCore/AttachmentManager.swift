import Foundation

public struct PendingAttachment: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var localURL: URL
    public var remotePath: String?
    public var kind: AttachmentKind

    public init(id: UUID = UUID(), localURL: URL, remotePath: String? = nil, kind: AttachmentKind) {
        self.id = id
        self.localURL = localURL
        self.remotePath = remotePath
        self.kind = kind
    }
}

public enum AttachmentKind: String, Codable, CaseIterable, Sendable {
    case image
    case audio
    case file
}

public enum AttachmentUploadError: Error, Equatable {
    case sourceMissing(String)
    case sourceIsDirectory(String)
    case invalidRemotePath(String)
}

public struct AttachmentPathBuilder: Sendable {
    public var root: String

    public init(root: String = "~/TerminalManager/attachments") {
        self.root = root
    }

    public func remoteDirectory(for session: TerminalSession) -> String {
        "\(root)/\(sanitize(session.tmuxSessionName))"
    }

    public func remotePath(for attachment: PendingAttachment, session: TerminalSession) -> String {
        let filename = sanitize(attachment.localURL.lastPathComponent.isEmpty ? "\(attachment.id.uuidString)" : attachment.localURL.lastPathComponent)
        return "\(remoteDirectory(for: session))/\(filename)"
    }

    private func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        })
    }
}

public protocol AttachmentUploader: Sendable {
    func upload(_ attachment: PendingAttachment, to remotePath: String) async throws -> PendingAttachment
}

public struct LocalFilesystemAttachmentUploader: AttachmentUploader {
    public var remoteRoot: URL
    public var pathBuilder: AttachmentPathBuilder

    public init(
        remoteRoot: URL,
        pathBuilder: AttachmentPathBuilder = AttachmentPathBuilder()
    ) {
        self.remoteRoot = remoteRoot
        self.pathBuilder = pathBuilder
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

        let destination = try localURL(forRemotePath: remotePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.copyItem(at: attachment.localURL, to: destination)

        var uploaded = attachment
        uploaded.remotePath = remotePath
        return uploaded
    }

    private func localURL(forRemotePath remotePath: String) throws -> URL {
        let normalizedRoot = pathBuilder.root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard remotePath == pathBuilder.root || remotePath.hasPrefix(pathBuilder.root + "/") else {
            throw AttachmentUploadError.invalidRemotePath(remotePath)
        }

        let relativePath = String(remotePath.dropFirst(pathBuilder.root.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sanitizedRelativePath = relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")

        guard !normalizedRoot.isEmpty, !sanitizedRelativePath.isEmpty else {
            throw AttachmentUploadError.invalidRemotePath(remotePath)
        }

        return remoteRoot.appendingPathComponent(sanitizedRelativePath)
    }
}
