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
