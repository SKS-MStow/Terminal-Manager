import Foundation

public final actor TerminalSessionController {
    private let pipeline: TerminalPipeline
    private var attachedSession: TerminalSession?

    public init(pipeline: TerminalPipeline) {
        self.pipeline = pipeline
    }

    public nonisolated func screenBytes() -> AsyncThrowingStream<Data, Error> {
        pipeline.screenBytes()
    }

    public func discoverSessions(transcriptCandidates: [TranscriptLink] = []) async throws -> TerminalPipelineSnapshot {
        try await pipeline.discoverSessions(transcriptCandidates: transcriptCandidates)
    }

    public func attach(to session: TerminalSession, size: TerminalSize) async throws {
        if attachedSession == nil {
            try await pipeline.attach(to: session, size: size)
        } else {
            do {
                try await pipeline.switchClient(to: session)
            } catch TerminalTransportError.notConnected {
                attachedSession = nil
                try await pipeline.attach(to: session, size: size)
            }
        }
        attachedSession = session
    }

    public func sendUserText(_ text: String) async throws {
        try await pipeline.sendUserText(text)
    }

    public func sendTerminalBytes(_ bytes: Data) async throws {
        try await pipeline.sendTerminalBytes(bytes)
    }

    public func resizeTerminal(to size: TerminalSize) async throws {
        try await pipeline.resizeTerminal(to: size)
    }

    public func uploadAttachmentAndSendReference(
        _ attachment: PendingAttachment,
        using uploader: any AttachmentUploader
    ) async throws -> PendingAttachment {
        guard let attachedSession else {
            throw TerminalTransportError.notConnected
        }

        return try await pipeline.uploadAttachmentAndSendReference(
            attachment,
            in: attachedSession,
            using: uploader
        )
    }

    public func capturedHistory(lineCount: Int = 5_000) async throws -> String {
        guard let attachedSession else {
            return ""
        }

        return try await pipeline.capturedHistory(for: attachedSession, lineCount: lineCount)
    }

    public func disconnect() async {
        attachedSession = nil
        await pipeline.disconnect()
    }
}
