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
    @Published private(set) var terminalSize: TerminalSize
    @Published var connectionSheetOpen: Bool
    @Published var connectionDraft: SavedSSHConnectionDraft
    @Published var connectionStatusText: String

    private var runtime: any TerminalAppRuntime
    private let connectionStore: SavedSSHConnectionStore
    private var terminalBuffer: TerminalScrollbackBuffer
    private var terminalStreamTask: Task<Void, Never>?

    init(
        host: HostProfile = PreviewFixtures.host,
        sessions: [TerminalSession] = PreviewFixtures.sessions,
        selectedSession: TerminalSession? = nil,
        terminalLines: [String] = PreviewFixtures.terminalLines,
        sidecarCards: [CompactedAgentActivityCard] = PreviewFixtures.sidecarCards,
        pendingAttachments: [PendingAttachment] = [],
        connectionStore: SavedSSHConnectionStore = .shared,
        runtime: (any TerminalAppRuntime)? = nil
    ) {
        self.connectionStore = connectionStore
        self.host = host
        self.sessions = sessions
        self.selectedSession = selectedSession ?? sessions.first ?? Self.placeholderSession(for: host)
        self.terminalLines = terminalLines
        self.terminalBuffer = TerminalScrollbackBuffer(lines: terminalLines)
        self.sidecarCards = sidecarCards
        self.pendingAttachments = pendingAttachments
        self.composerText = ""
        self.sidecarOpen = false
        self.tmuxDrawerOpen = false
        self.statusText = "tmux"
        self.terminalSize = TerminalSize()
        self.connectionSheetOpen = false
        self.connectionDraft = connectionStore.load().map { saved in
            SavedSSHConnectionDraft(saved: saved, password: (try? connectionStore.loadPassword(for: saved)) ?? "")
        } ?? SavedSSHConnectionDraft()
        self.connectionStatusText = "Saved SSH overrides the demo fixture. Env smoke settings still win."
        self.runtime = runtime ?? TerminalAppRuntimeFactory.makeDefaultRuntime(connectionStore: connectionStore)

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
        if tmuxDrawerOpen {
            Task {
                await refreshTmuxSessions()
            }
        }
    }

    func updateTerminalSize(_ size: TerminalSize) {
        guard size.columns > 0, size.rows > 0, size != terminalSize else {
            return
        }

        terminalSize = size
        terminalBuffer.resize(to: size)
        terminalLines = terminalBuffer.lines
        Task {
            await resizeTerminal(to: size)
        }
    }

    func openConnectionSettings() {
        if let saved = connectionStore.load() {
            connectionDraft = SavedSSHConnectionDraft(
                saved: saved,
                password: (try? connectionStore.loadPassword(for: saved)) ?? ""
            )
            connectionStatusText = "Saved profile: \(saved.username)@\(saved.hostname):\(saved.port)"
        } else {
            connectionDraft = SavedSSHConnectionDraft()
            connectionStatusText = "Add one SSH host. tmux sessions are discovered after connect."
        }
        connectionSheetOpen = true
    }

    func saveConnectionAndConnect() async {
        do {
            let saved = try connectionStore.save(connectionDraft)
            connectionSheetOpen = false
            resetTerminalLines(["Connecting to \(saved.username)@\(saved.hostname):\(saved.port) ..."])
            statusText = "connecting"
            rebuildRuntime()
            await bootstrapRuntime()
        } catch {
            connectionStatusText = Self.connectionMessage(for: error)
        }
    }

    func refreshTmuxSessions() async {
        do {
            let previousSelectedName = selectedSession.tmuxSessionName
            let refreshedSessions = try await runtime.refreshSessions()
            sessions = refreshedSessions
            guard !refreshedSessions.isEmpty else {
                selectedSession = Self.placeholderSession(for: host)
                statusText = "0 tmux"
                return
            }

            if let selected = refreshedSessions.first(where: { $0.tmuxSessionName == selectedSession.tmuxSessionName }) {
                selectedSession = selected
            } else if let first = refreshedSessions.first {
                selectedSession = first
            }
            statusText = "\(refreshedSessions.count) tmux"

            if selectedSession.tmuxSessionName != previousSelectedName {
                await attachSelectedSession()
            }
        } catch {
            statusText = "refresh failed"
            appendTerminalText("tmux refresh failed: \(error)\n")
        }
    }

    func sendComposerText() {
        let text = composerText
        guard !text.isEmpty else {
            return
        }

        composerText = ""
        Task {
            await sendToTerminal(text)
        }
    }

    func sendTerminalKey(_ key: TerminalInputKey) {
        Task {
            await sendRawTerminalBytes(key.bytes)
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
            resetTerminalLines(bootstrap.terminalLines)
            sidecarCards = bootstrap.sidecarCards
            statusText = "\(bootstrap.sessions.count) tmux"
            await attachSelectedSession()
        } catch {
            statusText = "offline"
            appendTerminalText("Terminal Manager runtime failed: \(error)\n")
        }
    }

    private func rebuildRuntime() {
        terminalStreamTask?.cancel()
        let oldRuntime = runtime
        Task {
            await oldRuntime.disconnect()
        }
        runtime = TerminalAppRuntimeFactory.makeDefaultRuntime(connectionStore: connectionStore)
        startTerminalStream()
    }

    private func attachSelectedSession() async {
        do {
            statusText = "attaching"
            try await runtime.attach(to: selectedSession, size: terminalSize)
            statusText = "\(sessions.count) tmux"
        } catch {
            statusText = "attach failed"
            appendTerminalText("Attach failed: \(error)\n")
        }
    }

    private func resizeTerminal(to size: TerminalSize) async {
        do {
            try await runtime.resizeTerminal(to: size)
        } catch TerminalTransportError.notConnected {
            // The first attach sends the current size. Ignore early geometry
            // measurements taken before the SSH PTY exists.
        } catch {
            appendTerminalText("Resize failed: \(error)\n")
        }
    }

    private func sendToTerminal(_ text: String) async {
        do {
            try await runtime.sendUserText(text)
        } catch {
            appendTerminalText("Send failed: \(error)\n")
        }
    }

    private func sendRawTerminalBytes(_ bytes: Data) async {
        do {
            try await runtime.sendTerminalBytes(bytes)
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
        terminalBuffer.append(text)
        terminalLines = terminalBuffer.lines
    }

    private func resetTerminalLines(_ lines: [String]) {
        terminalBuffer.reset(lines: lines)
        terminalLines = terminalBuffer.lines
    }

    private static func placeholderSession(for host: HostProfile) -> TerminalSession {
        TerminalSession(
            hostId: host.id,
            tmuxSessionName: "no-session",
            title: "No Session",
            workingDirectory: nil
        )
    }

    private static func connectionMessage(for error: Error) -> String {
        switch error {
        case SavedSSHConnectionStoreError.missingHostname:
            return "Host is required."
        case SavedSSHConnectionStoreError.missingUsername:
            return "Username is required."
        case SavedSSHConnectionStoreError.invalidPort:
            return "Port must be between 1 and 65535."
        case SavedSSHConnectionStoreError.missingHostKeyTrust:
            return "Add a pinned SHA256 host key fingerprint or allow local/dev unsafe host-key trust."
        case SavedSSHConnectionStoreError.missingPassword:
            return "Password is required for the current Citadel SSH bridge."
        case SavedSSHConnectionStoreError.keychainReadFailed(let status):
            return "Could not read password from Keychain (\(status))."
        case SavedSSHConnectionStoreError.keychainWriteFailed(let status):
            return "Could not save password to Keychain (\(status))."
        case SavedSSHConnectionStoreError.keychainDeleteFailed(let status):
            return "Could not delete password from Keychain (\(status))."
        default:
            return "Connection setup failed: \(error)"
        }
    }
}
