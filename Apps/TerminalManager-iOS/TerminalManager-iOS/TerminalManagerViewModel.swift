import Combine
import Foundation
import TerminalManagerCore

@MainActor
final class TerminalManagerViewModel: ObservableObject {
    @Published var host: HostProfile
    @Published var sessions: [TerminalSession]
    @Published var selectedSession: TerminalSession
    @Published var terminalLines: [String]
    @Published var sidecarCards: [CompactedAgentActivityCard]
    @Published var pendingAttachments: [PendingAttachment]
    @Published var composerText: String
    @Published var sidecarOpen: Bool

    init(
        host: HostProfile = PreviewFixtures.host,
        sessions: [TerminalSession] = PreviewFixtures.sessions,
        selectedSession: TerminalSession = PreviewFixtures.sessions[0],
        terminalLines: [String] = PreviewFixtures.terminalLines,
        sidecarCards: [CompactedAgentActivityCard] = PreviewFixtures.sidecarCards,
        pendingAttachments: [PendingAttachment] = []
    ) {
        self.host = host
        self.sessions = sessions
        self.selectedSession = selectedSession
        self.terminalLines = terminalLines
        self.sidecarCards = sidecarCards
        self.pendingAttachments = pendingAttachments
        self.composerText = ""
        self.sidecarOpen = true
    }

    func select(_ session: TerminalSession) {
        selectedSession = session
    }

    func toggleSidecar() {
        sidecarOpen.toggle()
    }

    func sendComposerText() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        terminalLines.append("> \(trimmed)")
        composerText = ""
    }

    func queuePlaceholderAttachment(kind: AttachmentKind) {
        let filename: String
        switch kind {
        case .image:
            filename = "photo.jpg"
        case .audio:
            filename = "voice-note.m4a"
        case .file:
            filename = "attachment.dat"
        }

        let attachment = PendingAttachment(
            localURL: URL(fileURLWithPath: "/tmp/\(filename)"),
            kind: kind
        )
        pendingAttachments.append(attachment)
    }
}
