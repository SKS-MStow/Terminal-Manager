import Foundation

public struct HostProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var preferredTransport: TerminalTransportKind

    public init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        port: Int = 22,
        username: String,
        preferredTransport: TerminalTransportKind = .mosh
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.preferredTransport = preferredTransport
    }
}

public enum TerminalTransportKind: String, Codable, CaseIterable, Sendable {
    case ssh
    case mosh
}

public struct TerminalSize: Codable, Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int = 100, rows: Int = 32) {
        self.columns = columns
        self.rows = rows
    }
}

public struct TerminalSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var hostId: UUID
    public var tmuxSessionName: String
    public var windowIndex: Int?
    public var paneId: String?
    public var title: String
    public var workingDirectory: String?
    public var agent: AgentKind?
    public var transcript: TranscriptLink?
    public var lastActivityAt: Date?

    public init(
        id: UUID = UUID(),
        hostId: UUID,
        tmuxSessionName: String,
        windowIndex: Int? = nil,
        paneId: String? = nil,
        title: String,
        workingDirectory: String? = nil,
        agent: AgentKind? = nil,
        transcript: TranscriptLink? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.hostId = hostId
        self.tmuxSessionName = tmuxSessionName
        self.windowIndex = windowIndex
        self.paneId = paneId
        self.title = title
        self.workingDirectory = workingDirectory
        self.agent = agent
        self.transcript = transcript
        self.lastActivityAt = lastActivityAt
    }
}

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public struct TranscriptLink: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var remotePath: String
    public var confidence: TranscriptConfidence

    public init(agent: AgentKind, remotePath: String, confidence: TranscriptConfidence) {
        self.agent = agent
        self.remotePath = remotePath
        self.confidence = confidence
    }
}

public enum TranscriptConfidence: String, Codable, Sendable {
    case automatic
    case likely
    case manual
}

public enum AgentActivityKind: String, Codable, CaseIterable, Sendable {
    case userMessage
    case assistantMessage
    case thinking
    case toolCall
    case plan
    case approval
    case file
    case system
}

public struct AgentActivityBlock: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: AgentActivityKind
    public var title: String
    public var body: String
    public var metadata: [String: String]
    public var createdAt: Date?

    public init(
        id: UUID = UUID(),
        kind: AgentActivityKind,
        title: String,
        body: String,
        metadata: [String: String] = [:],
        createdAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.metadata = metadata
        self.createdAt = createdAt
    }
}
