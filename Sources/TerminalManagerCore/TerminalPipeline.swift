import Foundation

public struct TerminalPipelineSnapshot: Equatable, Sendable {
    public var host: HostProfile
    public var tmuxSessions: [TmuxSession]
    public var panes: [TmuxPane]
    public var terminalSessions: [TerminalSession]

    public init(
        host: HostProfile,
        tmuxSessions: [TmuxSession],
        panes: [TmuxPane],
        terminalSessions: [TerminalSession]
    ) {
        self.host = host
        self.tmuxSessions = tmuxSessions
        self.panes = panes
        self.terminalSessions = terminalSessions
    }
}

public final class TerminalPipeline: Sendable {
    private let host: HostProfile
    private let tmux: TmuxService
    private let transport: TerminalTransport
    private let transcriptCorrelator: TranscriptCorrelator
    private let attachmentPathBuilder: AttachmentPathBuilder

    public init(
        host: HostProfile,
        tmux: TmuxService,
        transport: TerminalTransport,
        transcriptCorrelator: TranscriptCorrelator = TranscriptCorrelator(),
        attachmentPathBuilder: AttachmentPathBuilder = AttachmentPathBuilder()
    ) {
        self.host = host
        self.tmux = tmux
        self.transport = transport
        self.transcriptCorrelator = transcriptCorrelator
        self.attachmentPathBuilder = attachmentPathBuilder
    }

    public func discoverSessions(transcriptCandidates: [TranscriptLink] = []) async throws -> TerminalPipelineSnapshot {
        async let tmuxSessions = tmux.listSessions()
        async let panes = tmux.listPanes()

        let loadedSessions = try await tmuxSessions
        let loadedPanes = try await panes
        let panesBySession = Dictionary(grouping: loadedPanes, by: \.sessionName)
        let terminalSessions = loadedSessions.map { tmuxSession in
            let pane = Self.representativePane(for: panesBySession[tmuxSession.name] ?? [])
            return TerminalSession(
                hostId: host.id,
                tmuxSessionName: tmuxSession.name,
                windowIndex: pane?.windowIndex,
                windowCount: tmuxSession.windowCount,
                attachedCount: tmuxSession.attachedCount,
                paneId: pane?.paneId,
                title: Self.title(for: tmuxSession, pane: pane),
                workingDirectory: pane?.currentPath,
                agent: pane.flatMap(Self.agentKind(for:)),
                transcript: pane.flatMap { transcriptCorrelator.bestMatch(for: $0, candidates: transcriptCandidates) }
            )
        }

        return TerminalPipelineSnapshot(
            host: host,
            tmuxSessions: loadedSessions,
            panes: loadedPanes,
            terminalSessions: terminalSessions
        )
    }

    public func attach(to session: TerminalSession, size: TerminalSize) async throws {
        try await transport.connect(to: host, size: size)
        let attachCommand = tmux.attachCommand(sessionName: session.tmuxSessionName)
        try await sendLine(attachCommand)
    }

    public func switchClient(to session: TerminalSession) async throws {
        try await transport.send(tmux.switchClientKeySequence(sessionName: session.tmuxSessionName))
    }

    public func sendUserText(_ text: String) async throws {
        try await sendLine(text)
    }

    public func sendTerminalBytes(_ bytes: Data) async throws {
        try await transport.send(bytes)
    }

    public func sendAttachmentReference(_ attachment: PendingAttachment, in session: TerminalSession) async throws -> String {
        let remotePath = attachmentPathBuilder.remotePath(for: attachment, session: session)
        try await sendLine(remotePath)
        return remotePath
    }

    public func uploadAttachment(
        _ attachment: PendingAttachment,
        in session: TerminalSession,
        using uploader: any AttachmentUploader
    ) async throws -> PendingAttachment {
        let remotePath = attachmentPathBuilder.remotePath(for: attachment, session: session)
        return try await uploader.upload(attachment, to: remotePath)
    }

    public func uploadAttachmentAndSendReference(
        _ attachment: PendingAttachment,
        in session: TerminalSession,
        using uploader: any AttachmentUploader
    ) async throws -> PendingAttachment {
        let uploaded = try await uploadAttachment(attachment, in: session, using: uploader)
        guard let remotePath = uploaded.remotePath else {
            return uploaded
        }

        try await sendLine(remotePath)
        return uploaded
    }

    public func resizeTerminal(to size: TerminalSize) async throws {
        try await transport.resize(to: size)
    }

    public func screenBytes() -> AsyncThrowingStream<Data, Error> {
        transport.screenBytes()
    }

    public func disconnect() async {
        await transport.disconnect()
    }

    public func capturedHistory(for session: TerminalSession, lineCount: Int = 5_000) async throws -> String {
        guard let paneId = session.paneId else {
            return ""
        }

        return try await tmux.captureHistory(paneId: paneId, lineCount: lineCount)
    }

    public func compactTranscript(
        _ data: Data,
        agent: AgentKind = .codex,
        parser: any TranscriptParser = CodexTranscriptParser(),
        compactor: AgentActivityCompactor = AgentActivityCompactor()
    ) throws -> [CompactedAgentActivityCard] {
        try compactor.compact(parser.parse(data, agent: agent))
    }

    private func sendLine(_ text: String) async throws {
        try await transport.send(Data((text + "\r").utf8))
    }

    private static func representativePane(for panes: [TmuxPane]) -> TmuxPane? {
        panes.first(where: { $0.isActiveWindow && $0.isActivePane })
            ?? panes.first(where: \.isActivePane)
            ?? panes.first(where: \.isActiveWindow)
            ?? panes.first
    }

    private static func agentKind(for pane: TmuxPane) -> AgentKind? {
        guard let command = pane.currentCommand?.lowercased() else {
            return nil
        }

        if command.contains("codex") {
            return .codex
        }

        if command.contains("claude") {
            return .claude
        }

        return nil
    }

    private static func title(for session: TmuxSession, pane: TmuxPane?) -> String {
        guard let pane, !pane.title.isEmpty else {
            return session.name
        }

        return pane.title
    }
}
