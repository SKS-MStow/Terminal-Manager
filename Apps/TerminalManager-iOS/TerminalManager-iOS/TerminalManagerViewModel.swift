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
    @Published var tmuxDrawerOpen: Bool
    @Published var statusText: String

    private let runtime: any TerminalAppRuntime
    private var terminalStreamTask: Task<Void, Never>?

    init(
        host: HostProfile = PreviewFixtures.host,
        sessions: [TerminalSession] = PreviewFixtures.sessions,
        selectedSession: TerminalSession? = nil,
        terminalLines: [String] = PreviewFixtures.terminalLines,
        sidecarCards: [CompactedAgentActivityCard] = PreviewFixtures.sidecarCards,
        pendingAttachments: [PendingAttachment] = [],
        runtime: any TerminalAppRuntime = TerminalAppRuntimeFactory.makeDefaultRuntime()
    ) {
        self.host = host
        self.sessions = sessions
        self.selectedSession = selectedSession ?? sessions.first ?? Self.placeholderSession(for: host)
        self.terminalLines = terminalLines
        self.sidecarCards = sidecarCards
        self.pendingAttachments = pendingAttachments
        self.composerText = ""
        self.sidecarOpen = false
        self.tmuxDrawerOpen = false
        self.statusText = "tmux"
        self.runtime = runtime

        startTerminalStream()
        Task {
            await bootstrapRuntime()
        }
    }

    func select(_ session: TerminalSession) {
        selectedSession = session
        tmuxDrawerOpen = false
        Task {
            await attachSelectedSession()
        }
    }

    func toggleSidecar() {
        sidecarOpen.toggle()
    }

    func toggleTmuxDrawer() {
        tmuxDrawerOpen.toggle()
    }

    func sendComposerText() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        composerText = ""
        Task {
            await sendToTerminal(trimmed)
        }
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

    private func bootstrapRuntime() async {
        do {
            let bootstrap = try await runtime.bootstrap()
            host = bootstrap.host
            sessions = bootstrap.sessions
            selectedSession = bootstrap.selectedSession
            terminalLines = bootstrap.terminalLines
            sidecarCards = bootstrap.sidecarCards
            statusText = "\(bootstrap.sessions.count) tmux"
            await attachSelectedSession()
        } catch {
            statusText = "offline"
            appendTerminalText("Terminal Manager runtime failed: \(error)\n")
        }
    }

    private func attachSelectedSession() async {
        do {
            statusText = "attaching"
            try await runtime.attach(to: selectedSession, size: TerminalSize(columns: 100, rows: 32))
            statusText = "\(sessions.count) tmux"
        } catch {
            statusText = "attach failed"
            appendTerminalText("Attach failed: \(error)\n")
        }
    }

    private func sendToTerminal(_ text: String) async {
        do {
            try await runtime.sendUserText(text)
        } catch {
            appendTerminalText("Send failed: \(error)\n")
        }
    }

    private func startTerminalStream() {
        terminalStreamTask?.cancel()
        terminalStreamTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                for try await text in self.runtime.terminalTextStream() {
                    await MainActor.run {
                        self.appendTerminalText(text)
                    }
                }
            } catch {
                await MainActor.run {
                    self.appendTerminalText("Terminal stream ended: \(error)\n")
                }
            }
        }
    }

    private func appendTerminalText(_ text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let incoming = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !incoming.isEmpty else {
            return
        }

        terminalLines.append(contentsOf: incoming)
        if terminalLines.count > 1_000 {
            terminalLines.removeFirst(terminalLines.count - 1_000)
        }
    }

    private static func placeholderSession(for host: HostProfile) -> TerminalSession {
        TerminalSession(
            hostId: host.id,
            tmuxSessionName: "no-session",
            title: "No Session",
            workingDirectory: nil
        )
    }
}
