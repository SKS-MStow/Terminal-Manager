import Foundation
import TerminalManagerCore

enum SelfCheckFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

@main
struct TerminalManagerSelfCheck {
    static func main() async throws {
        try await checkTmuxSessionParsing()
        try await checkTmuxPaneParsing()
        try await checkCaptureHistory()
        try checkStartAgentCommand()
        try checkTranscriptParser()
        try checkTranscriptCorrelation()
        try checkAttachmentPath()
        try await checkRecordingTransport()
        print("Terminal Manager self-check passed")
    }

    private static func checkTmuxSessionParsing() async throws {
        let shell = StubRemoteShell(responses: [
            "tmux list-sessions -F '#S\\t#{session_windows}\\t#{session_attached}'": RemoteCommandResult(
                exitCode: 0,
                stdout: "codex-sks\t2\t1\nclaude-solar\t1\t0\n"
            )
        ])
        let service = TmuxService(shell: shell)
        let sessions = try await service.listSessions()

        try expect(sessions.count == 2, "expected two tmux sessions")
        try expect(sessions[0].name == "codex-sks", "expected first session name")
        try expect(sessions[0].windowCount == 2, "expected window count")
        try expect(sessions[0].attachedCount == 1, "expected attached count")
    }

    private static func checkTmuxPaneParsing() async throws {
        let shell = StubRemoteShell(responses: [
            "tmux list-panes -a -F '#S\\t#I\\t#D\\t#T\\t#{pane_current_command}\\t#{pane_current_path}'": RemoteCommandResult(
                exitCode: 0,
                stdout: "codex-sks\t0\t%1\tEditor\tcodex\t/Users/mark/Github/sks-submissions\n"
            )
        ])
        let service = TmuxService(shell: shell)
        let panes = try await service.listPanes()

        try expect(panes.count == 1, "expected one pane")
        try expect(panes[0].paneId == "%1", "expected pane id")
        try expect(panes[0].currentCommand == "codex", "expected pane command")
        try expect(panes[0].currentPath == "/Users/mark/Github/sks-submissions", "expected pane cwd")
    }

    private static func checkCaptureHistory() async throws {
        let expectedCommand = "tmux capture-pane -p -t '%1' -S -250"
        let shell = StubRemoteShell(responses: [
            expectedCommand: RemoteCommandResult(exitCode: 0, stdout: "hello terminal\n")
        ])
        let service = TmuxService(shell: shell)
        let history = try await service.captureHistory(paneId: "%1", lineCount: 250)

        try expect(history == "hello terminal\n", "expected captured history")
    }

    private static func checkStartAgentCommand() throws {
        let service = TmuxService(shell: StubRemoteShell())
        let command = service.startAgentSessionCommand(
            agent: .codex,
            sessionName: "codex-sks",
            workingDirectory: "/Users/mark/Github/sks-submissions",
            initialPrompt: "fix the bug"
        )

        try expect(command.contains("tmux new-session -d -s 'codex-sks'"), "expected tmux new-session")
        try expect(command.contains("-c '/Users/mark/Github/sks-submissions'"), "expected cwd")
        try expect(command.contains("'codex'"), "expected codex launch")
        try expect(command.contains("tmux send-keys -t 'codex-sks' -- 'fix the bug' Enter"), "expected prompt send")
    }

    private static func checkTranscriptParser() throws {
        let lines = [
            #"{"type":"response_item","role":"assistant","item_type":"message","text":"I can do that."}"#,
            #"{"type":"response_item","item_type":"tool_call","item":{"name":"exec_command"}}"#,
            #"{"type":"event_msg","message":"thinking through approach"}"#
        ].joined(separator: "\n")
        let blocks = try CodexTranscriptParser().parse(Data(lines.utf8), agent: .codex)

        try expect(blocks.count == 3, "expected three parsed blocks")
        try expect(blocks[0].kind == .assistantMessage, "expected assistant block")
        try expect(blocks[1].kind == .toolCall, "expected tool block")
        try expect(blocks[2].kind == .thinking, "expected thinking block")
    }

    private static func checkTranscriptCorrelation() throws {
        let pane = TmuxPane(
            sessionName: "agent",
            windowIndex: 0,
            paneId: "%2",
            title: "Codex",
            currentCommand: "codex",
            currentPath: "/Users/mark/Github/Terminal-Manager"
        )
        let claude = TranscriptLink(agent: .claude, remotePath: "~/.claude/projects/session.jsonl", confidence: .likely)
        let codex = TranscriptLink(agent: .codex, remotePath: "~/.codex/sessions/rollout.jsonl", confidence: .likely)
        let match = TranscriptCorrelator().bestMatch(for: pane, candidates: [claude, codex])

        try expect(match == codex, "expected codex transcript match")
    }

    private static func checkAttachmentPath() throws {
        let session = TerminalSession(
            hostId: UUID(),
            tmuxSessionName: "codex/sks quotes",
            title: "Codex"
        )
        let attachment = PendingAttachment(
            localURL: URL(fileURLWithPath: "/tmp/site photo 1.png"),
            kind: .image
        )
        let path = AttachmentPathBuilder().remotePath(for: attachment, session: session)

        try expect(path == "~/TerminalManager/attachments/codex-sks-quotes/site-photo-1.png", "expected sanitized attachment path")
    }

    private static func checkRecordingTransport() async throws {
        let transport = RecordingTerminalTransport()
        let host = HostProfile(displayName: "Mac", hostname: "mac.tailnet.ts.net", username: "mark")

        do {
            try await transport.send(Data("hello".utf8))
            throw SelfCheckFailure.assertion("send should fail before connect")
        } catch TerminalTransportError.notConnected {
            // expected
        }

        try await transport.connect(to: host, size: TerminalSize(columns: 120, rows: 40))
        try await transport.send(Data("hello".utf8))

        let writes = await transport.recordedWrites()
        let size = await transport.currentSize()

        try expect(writes == [Data("hello".utf8)], "expected recorded transport write")
        try expect(size == TerminalSize(columns: 120, rows: 40), "expected transport size")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SelfCheckFailure.assertion(message)
        }
    }
}
