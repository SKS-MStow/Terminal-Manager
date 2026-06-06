import Foundation

public struct TmuxSession: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var windowCount: Int?
    public var attachedCount: Int?
    public var createdAt: Date?

    public init(name: String, windowCount: Int? = nil, attachedCount: Int? = nil, createdAt: Date? = nil) {
        self.name = name
        self.windowCount = windowCount
        self.attachedCount = attachedCount
        self.createdAt = createdAt
    }
}

public struct TmuxPane: Identifiable, Equatable, Sendable {
    public var id: String { paneId }
    public var sessionName: String
    public var windowIndex: Int
    public var paneId: String
    public var title: String
    public var currentCommand: String?
    public var currentPath: String?

    public init(
        sessionName: String,
        windowIndex: Int,
        paneId: String,
        title: String,
        currentCommand: String? = nil,
        currentPath: String? = nil
    ) {
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.paneId = paneId
        self.title = title
        self.currentCommand = currentCommand
        self.currentPath = currentPath
    }
}

public final class TmuxService: Sendable {
    private let shell: RemoteShell

    public init(shell: RemoteShell) {
        self.shell = shell
    }

    public func listSessions() async throws -> [TmuxSession] {
        let format = "#S\\t#{session_windows}\\t#{session_attached}"
        let result = try await shell.run("tmux list-sessions -F '\(format)'")
        try Self.throwIfFailed(result, command: "tmux list-sessions")

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap(Self.parseSessionLine)
    }

    public func listPanes() async throws -> [TmuxPane] {
        let format = "#S\\t#I\\t#D\\t#T\\t#{pane_current_command}\\t#{pane_current_path}"
        let result = try await shell.run("tmux list-panes -a -F '\(format)'")
        try Self.throwIfFailed(result, command: "tmux list-panes")

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap(Self.parsePaneLine)
    }

    public func captureHistory(paneId: String, lineCount: Int = 5_000) async throws -> String {
        let sanitizedPane = Self.singleQuoteEscaped(paneId)
        let sanitizedLineCount = max(1, lineCount)
        let command = "tmux capture-pane -p -t '\(sanitizedPane)' -S -\(sanitizedLineCount)"
        let result = try await shell.run(command)
        try Self.throwIfFailed(result, command: "tmux capture-pane")
        return result.stdout
    }

    public func attachCommand(sessionName: String) -> String {
        "tmux attach-session -t '\(Self.singleQuoteEscaped(sessionName))'"
    }

    public func startAgentSessionCommand(agent: AgentKind, sessionName: String, workingDirectory: String, initialPrompt: String?) -> String {
        let escapedName = Self.singleQuoteEscaped(sessionName)
        let escapedDirectory = Self.singleQuoteEscaped(workingDirectory)
        let agentCommand: String

        switch agent {
        case .codex:
            agentCommand = "codex"
        case .claude:
            agentCommand = "claude"
        }

        let startCommand = "tmux new-session -d -s '\(escapedName)' -c '\(escapedDirectory)' '\(agentCommand)'"
        let promptCommand: String
        if let initialPrompt, !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptCommand = " ; tmux send-keys -t '\(escapedName)' -- '\(Self.singleQuoteEscaped(initialPrompt))' Enter"
        } else {
            promptCommand = ""
        }

        return startCommand + promptCommand
    }

    private static func parseSessionLine(_ line: Substring) -> TmuxSession? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let name = fields.first, !name.isEmpty else {
            return nil
        }

        return TmuxSession(
            name: name,
            windowCount: fields[safe: 1].flatMap(Int.init),
            attachedCount: fields[safe: 2].flatMap(Int.init)
        )
    }

    private static func parsePaneLine(_ line: Substring) -> TmuxPane? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard
            let sessionName = fields[safe: 0],
            let windowIndexText = fields[safe: 1],
            let windowIndex = Int(windowIndexText),
            let paneId = fields[safe: 2],
            !sessionName.isEmpty,
            !paneId.isEmpty
        else {
            return nil
        }

        return TmuxPane(
            sessionName: sessionName,
            windowIndex: windowIndex,
            paneId: paneId,
            title: fields[safe: 3] ?? "",
            currentCommand: fields[safe: 4],
            currentPath: fields[safe: 5]
        )
    }

    private static func throwIfFailed(_ result: RemoteCommandResult, command: String) throws {
        guard result.exitCode == 0 else {
            throw RemoteShellError.commandFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    static func singleQuoteEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
