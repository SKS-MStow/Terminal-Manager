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

    public static func fitting(
        availableWidth: Double,
        availableHeight: Double,
        preferredFontSize: Double = 10,
        characterAspectRatio: Double = 0.62,
        lineHeightMultiplier: Double = 1.35,
        horizontalPadding: Double = 14,
        verticalPadding: Double = 14,
        minimumColumns: Int = 48,
        maximumColumns: Int = 120,
        minimumRows: Int = 18,
        maximumRows: Int = 60
    ) -> TerminalSize {
        let contentWidth = max(1, availableWidth - horizontalPadding * 2)
        let contentHeight = max(1, availableHeight - verticalPadding * 2)
        let characterWidth = max(1, preferredFontSize * characterAspectRatio)
        let lineHeight = max(1, preferredFontSize * lineHeightMultiplier)
        let fittedColumns = Int(contentWidth / characterWidth)
        let fittedRows = Int(contentHeight / lineHeight)

        return TerminalSize(
            columns: min(maximumColumns, max(minimumColumns, fittedColumns)),
            rows: min(maximumRows, max(minimumRows, fittedRows))
        )
    }
}

public struct TerminalGridMetrics: Equatable, Sendable {
    public var terminalSize: TerminalSize
    public var fontSize: Double
    public var characterWidth: Double
    public var lineHeight: Double
    public var horizontalPadding: Double
    public var verticalPadding: Double

    public var gridWidth: Double {
        Double(terminalSize.columns) * characterWidth
    }

    public var gridHeight: Double {
        Double(terminalSize.rows) * lineHeight
    }

    public init(
        terminalSize: TerminalSize,
        fontSize: Double,
        characterWidth: Double,
        lineHeight: Double,
        horizontalPadding: Double,
        verticalPadding: Double
    ) {
        self.terminalSize = terminalSize
        self.fontSize = fontSize
        self.characterWidth = characterWidth
        self.lineHeight = lineHeight
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    public static func fitting(
        terminalSize: TerminalSize,
        availableWidth: Double,
        availableHeight: Double,
        minFontSize: Double = 5,
        maxFontSize: Double = 13,
        characterAspectRatio: Double = 0.62,
        lineHeightMultiplier: Double = 1.35,
        horizontalPadding: Double = 14,
        verticalPadding: Double = 14
    ) -> TerminalGridMetrics {
        let columns = max(1, terminalSize.columns)
        let rows = max(1, terminalSize.rows)
        let contentWidth = max(1, availableWidth - horizontalPadding * 2)
        let contentHeight = max(1, availableHeight - verticalPadding * 2)
        let widthFontSize = contentWidth / Double(columns) / characterAspectRatio
        let heightFontSize = contentHeight / Double(rows) / lineHeightMultiplier
        let fittedFontSize = min(maxFontSize, max(minFontSize, min(widthFontSize, heightFontSize)))
        let characterWidth = fittedFontSize * characterAspectRatio
        let lineHeight = fittedFontSize * lineHeightMultiplier

        return TerminalGridMetrics(
            terminalSize: TerminalSize(columns: columns, rows: rows),
            fontSize: fittedFontSize,
            characterWidth: characterWidth,
            lineHeight: lineHeight,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )
    }
}

public struct TerminalSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var hostId: UUID
    public var tmuxSessionName: String
    public var windowIndex: Int?
    public var windowCount: Int?
    public var attachedCount: Int?
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
        windowCount: Int? = nil,
        attachedCount: Int? = nil,
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
        self.windowCount = windowCount
        self.attachedCount = attachedCount
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

public struct CompactedAgentActivityCard: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: AgentActivityKind
    public var title: String
    public var preview: String
    public var blockCount: Int
    public var sourceBlockIds: [UUID]
    public var metadata: [String: String]
    public var createdAt: Date?

    public init(
        id: UUID = UUID(),
        kind: AgentActivityKind,
        title: String,
        preview: String,
        blockCount: Int,
        sourceBlockIds: [UUID],
        metadata: [String: String] = [:],
        createdAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.preview = preview
        self.blockCount = blockCount
        self.sourceBlockIds = sourceBlockIds
        self.metadata = metadata
        self.createdAt = createdAt
    }
}
