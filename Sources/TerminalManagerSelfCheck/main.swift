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
        try checkTranscriptCompaction()
        try checkTranscriptCorrelation()
        try checkAttachmentPath()
        try await checkAttachmentUpload()
        try await checkRecordingTransport()
        try checkTerminalScrollbackBuffer()
        try checkTerminalGridMetrics()
        try await checkTerminalPipelineE2E()
        try await checkTerminalSessionController()
        try checkOpenSSHArguments()
        try checkSSHAuthPolicy()
        print("Terminal Manager self-check passed")
    }

    private static func checkTmuxSessionParsing() async throws {
        let shell = StubRemoteShell(responses: [
            "tmux list-sessions -F '#S\t#{session_windows}\t#{session_attached}'": RemoteCommandResult(
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
            "tmux list-panes -a -F '#S\t#I\t#D\t#T\t#{pane_current_command}\t#{pane_current_path}'": RemoteCommandResult(
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
            initialPrompt: "fix the bug; don't treat C-m as a key"
        )

        try expect(command.contains("tmux new-session -d -s 'codex-sks'"), "expected tmux new-session")
        try expect(command.contains("-c '/Users/mark/Github/sks-submissions'"), "expected cwd")
        try expect(command.contains("'codex'"), "expected codex launch")
        try expect(command.contains(" && tmux send-keys -t 'codex-sks' -l -- 'fix the bug; don'\\''t treat C-m as a key'"), "expected literal prompt send")
        try expect(command.hasSuffix(" && tmux send-keys -t 'codex-sks' Enter"), "expected separate enter send")
    }

    private static func checkTranscriptParser() throws {
        let lines = [
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I can do that."}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_1","arguments":"{\"cmd\":\"pwd\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"/Users/mark/Github/Terminal-Manager"}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"text":"thinking through approach"}]}}"#
        ].joined(separator: "\n")
        let blocks = try CodexTranscriptParser().parse(Data(lines.utf8), agent: .codex)

        try expect(blocks.count == 4, "expected four parsed blocks")
        try expect(blocks[0].kind == .assistantMessage, "expected assistant block")
        try expect(blocks[1].kind == .toolCall, "expected tool block")
        try expect(blocks[1].title == "exec_command", "expected tool title")
        try expect(blocks[1].metadata["callId"] == "call_1", "expected tool call id metadata")
        try expect(blocks[2].kind == .toolCall, "expected tool output block")
        try expect(blocks[2].title == "Tool Output", "expected tool output title")
        try expect(blocks[3].kind == .thinking, "expected thinking block")
    }

    private static func checkTranscriptCompaction() throws {
        let longOutput = String(repeating: "tool-output-", count: 40)
        let lines = [
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"text":"checking repo"}]}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"text":"choosing patch"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_7","arguments":"{\"cmd\":\"pwd\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_7","status":"completed","output":""# + longOutput + #""}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#
        ].joined(separator: "\n")
        let blocks = try CodexTranscriptParser().parse(Data(lines.utf8), agent: .codex)
        let compactor = AgentActivityCompactor(maxPreviewCharacters: 120)
        let cards = compactor.compact(blocks)

        try expect(cards.count == 3, "expected compacted thinking, tool, and assistant cards")
        try expect(cards[0].kind == .thinking, "expected thinking card")
        try expect(cards[0].blockCount == 2, "expected merged thinking blocks")
        try expect(cards[0].preview.contains("checking repo"), "expected first reasoning preview")
        try expect(cards[0].preview.contains("choosing patch"), "expected second reasoning preview")
        try expect(cards[0].metadata["sourceKinds"] == "thinking", "expected thinking source kind metadata")
        try expect(cards[0].metadata["hiddenBlockCount"] == "1", "expected thinking hidden block count")

        try expect(cards[1].kind == .toolCall, "expected tool card")
        try expect(cards[1].title == "exec_command", "expected tool card title")
        try expect(cards[1].blockCount == 2, "expected paired tool call and output")
        try expect(cards[1].metadata["compactionKey"] == "tool:call_7", "expected call id compaction key")
        try expect(cards[1].metadata["callId"] == "call_7", "expected card call id metadata")
        try expect(cards[1].metadata["status"] == "completed", "expected card status metadata")
        try expect(cards[1].metadata["toolNames"] == "exec_command", "expected tool name metadata")
        try expect(cards[1].metadata["sourceKinds"] == "toolCall", "expected tool source kind metadata")
        try expect((Int(cards[1].metadata["hiddenCharacterCount"] ?? "0") ?? 0) > 0, "expected hidden character count")
        try expect(cards[1].preview.hasSuffix("..."), "expected truncated tool preview")
        try expect(cards[1].sourceBlockIds == blocks[2...3].map(\.id), "expected retained source block ids")
        let expandedToolBlocks = compactor.expandedBlocks(for: cards[1], in: blocks)
        try expect(expandedToolBlocks.count == 2, "expected expandable tool block ids")

        try expect(cards[2].kind == .assistantMessage, "expected assistant card")
        try expect(cards[2].blockCount == 1, "expected assistant card to remain separate")

        let pipeline = TerminalPipeline(
            host: HostProfile(displayName: "Mac", hostname: "mac.tailnet.ts.net", username: "mark"),
            tmux: TmuxService(shell: StubRemoteShell()),
            transport: RecordingTerminalTransport()
        )
        let pipelineCards = try pipeline.compactTranscript(Data(lines.utf8), compactor: compactor)
        try expect(pipelineCards.map(\.kind) == cards.map(\.kind), "expected pipeline helper card kinds")
        try expect(pipelineCards.map(\.title) == cards.map(\.title), "expected pipeline helper card titles")
        try expect(pipelineCards.map(\.preview) == cards.map(\.preview), "expected pipeline helper card previews")
        try expect(pipelineCards.map(\.blockCount) == cards.map(\.blockCount), "expected pipeline helper block counts")

        let unkeyedToolBlocks = [
            AgentActivityBlock(kind: .toolCall, title: "exec_command", body: #"{"cmd":"pwd"}"#),
            AgentActivityBlock(kind: .toolCall, title: "Tool Output", body: "/Users/mark/Github/Terminal-Manager"),
            AgentActivityBlock(kind: .toolCall, title: "exec_command", body: #"{"cmd":"date"}"#)
        ]
        let unkeyedToolCards = AgentActivityCompactor().compact(unkeyedToolBlocks)
        try expect(unkeyedToolCards.count == 2, "expected adjacent unkeyed tool output pairing only")
        try expect(unkeyedToolCards[0].blockCount == 2, "expected first unkeyed tool output to pair")
        try expect(unkeyedToolCards[1].blockCount == 1, "expected next unkeyed tool call to remain separate")
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

    private static func checkAttachmentUpload() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("terminal-manager-upload-\(UUID().uuidString)")
        let localSource = tempRoot.appendingPathComponent("local").appendingPathComponent("site photo.png")
        let remoteRoot = tempRoot.appendingPathComponent("remote")

        try fileManager.createDirectory(at: localSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("attachment-bytes".utf8).write(to: localSource)
        defer {
            try? fileManager.removeItem(at: tempRoot)
        }

        let host = HostProfile(displayName: "Mac", hostname: "mac.tailnet.ts.net", username: "mark")
        let session = TerminalSession(hostId: host.id, tmuxSessionName: "codex/sks quotes", title: "Codex")
        let attachment = PendingAttachment(localURL: localSource, kind: .image)
        let uploader = LocalFilesystemAttachmentUploader(remoteRoot: remoteRoot)
        let transport = RecordingTerminalTransport()
        let pipeline = TerminalPipeline(host: host, tmux: TmuxService(shell: StubRemoteShell()), transport: transport)

        try await transport.connect(to: host, size: TerminalSize())
        let uploaded = try await pipeline.uploadAttachmentAndSendReference(attachment, in: session, using: uploader)
        let remotePath = try expect(uploaded.remotePath, "expected uploaded remote path")
        let copiedFile = remoteRoot
            .appendingPathComponent("codex-sks-quotes")
            .appendingPathComponent("site-photo.png")

        try expect(remotePath == "~/TerminalManager/attachments/codex-sks-quotes/site-photo.png", "expected uploaded remote path")
        try expect(fileManager.fileExists(atPath: copiedFile.path), "expected copied attachment file")
        let copiedBytes = try Data(contentsOf: copiedFile)
        try expect(copiedBytes == Data("attachment-bytes".utf8), "expected copied attachment bytes")

        let writes = await transport.recordedWrites().compactMap { String(data: $0, encoding: .utf8) }
        try expect(writes == ["~/TerminalManager/attachments/codex-sks-quotes/site-photo.png\r"], "expected uploaded path terminal write")

        do {
            _ = try await uploader.upload(
                PendingAttachment(localURL: tempRoot.appendingPathComponent("missing.png"), kind: .image),
                to: "~/TerminalManager/attachments/codex-sks-quotes/missing.png"
            )
            throw SelfCheckFailure.assertion("missing upload source should fail")
        } catch AttachmentUploadError.sourceMissing {
            // expected
        }
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

    private static func checkTerminalGridMetrics() throws {
        let metrics = TerminalGridMetrics.fitting(
            terminalSize: TerminalSize(columns: 100, rows: 32),
            availableWidth: 390,
            availableHeight: 620
        )

        try expect(metrics.terminalSize == TerminalSize(columns: 100, rows: 32), "expected grid metrics to preserve tmux size")
        try expect(metrics.fontSize < 13, "expected iPhone-width grid to reduce font size")
        try expect(metrics.gridWidth + metrics.horizontalPadding * 2 <= 390.01, "expected 100 columns to fit available width")
        try expect(metrics.gridHeight + metrics.verticalPadding * 2 <= 620.01, "expected 32 rows to fit available height")
    }

    private static func checkTerminalScrollbackBuffer() throws {
        var redraw = TerminalScrollbackBuffer()
        redraw.append("progress 10%")
        redraw.append("\rprogress 20%")
        try expect(redraw.lines == ["progress 20%"], "expected carriage return to redraw current line")

        redraw.append("\r\u{1B}[2Kdone")
        try expect(redraw.lines == ["done"], "expected ANSI clear-line sequence to be handled")

        var cursor = TerminalScrollbackBuffer()
        cursor.append("abcdef\u{1B}[3DXYZ")
        try expect(cursor.lines == ["abcXYZ"], "expected CSI cursor-left overwrite to be handled")

        var scrollback = TerminalScrollbackBuffer(maxLineCount: 3)
        scrollback.append("one\ntwo\nthree\nfour")
        try expect(scrollback.lines == ["two", "three", "four"], "expected scrollback to stay bounded")
    }

    private static func checkTerminalPipelineE2E() async throws {
        let host = HostProfile(displayName: "Mac", hostname: "mac.tailnet.ts.net", username: "mark")
        let shell = StubRemoteShell(responses: [
            "tmux list-sessions -F '#S\t#{session_windows}\t#{session_attached}'": RemoteCommandResult(
                exitCode: 0,
                stdout: "codex-sks\t1\t1\n"
            ),
            "tmux list-panes -a -F '#S\t#I\t#D\t#T\t#{pane_current_command}\t#{pane_current_path}'": RemoteCommandResult(
                exitCode: 0,
                stdout: """
                codex-sks\t0\t%1\tCodex\tcodex\t/Users/mark/Github/Terminal-Manager
                codex-sks\t1\t%2\tLogs\tzsh\t/Users/mark/Github/Terminal-Manager

                """
            ),
            "tmux capture-pane -p -t '%1' -S -100": RemoteCommandResult(
                exitCode: 0,
                stdout: "codex thinking\ncodex output\n"
            )
        ])
        let tmux = TmuxService(shell: shell)
        let transport = RecordingTerminalTransport()
        let pipeline = TerminalPipeline(host: host, tmux: tmux, transport: transport)
        let transcript = TranscriptLink(
            agent: .codex,
            remotePath: "~/.codex/sessions/rollout.jsonl",
            confidence: .likely
        )

        let snapshot = try await pipeline.discoverSessions(transcriptCandidates: [transcript])

        try expect(snapshot.tmuxSessions.count == 1, "expected E2E tmux session")
        try expect(snapshot.terminalSessions.count == 1, "expected E2E terminal session")
        let session = snapshot.terminalSessions[0]
        try expect(session.agent == .codex, "expected codex agent classification")
        try expect(session.windowCount == 1, "expected tmux window count to carry into terminal session")
        try expect(session.attachedCount == 1, "expected tmux attached count to carry into terminal session")
        try expect(session.transcript == transcript, "expected transcript correlation")

        try await pipeline.attach(to: session, size: TerminalSize(columns: 100, rows: 32))
        try await pipeline.sendUserText("continue")
        let remotePath = try await pipeline.sendAttachmentReference(
            PendingAttachment(localURL: URL(fileURLWithPath: "/tmp/screen shot.png"), kind: .image),
            in: session
        )
        let history = try await pipeline.capturedHistory(for: session, lineCount: 100)
        let writes = await transport.recordedWrites().compactMap { String(data: $0, encoding: .utf8) }

        try expect(remotePath == "~/TerminalManager/attachments/codex-sks/screen-shot.png", "expected E2E attachment path")
        try expect(history.contains("codex output"), "expected E2E captured history")
        try expect(writes == [
            "tmux attach-session -t 'codex-sks'\r",
            "continue\r",
            "~/TerminalManager/attachments/codex-sks/screen-shot.png\r"
        ], "expected E2E terminal writes")
    }

    private static func checkTerminalSessionController() async throws {
        let host = HostProfile(displayName: "Mac", hostname: "mac.tailnet.ts.net", username: "mark")
        let shell = StubRemoteShell(responses: [
            "tmux list-sessions -F '#S\t#{session_windows}\t#{session_attached}'": RemoteCommandResult(
                exitCode: 0,
                stdout: "work\t1\t0\nops\t1\t0\n"
            ),
            "tmux list-panes -a -F '#S\t#I\t#D\t#T\t#{pane_current_command}\t#{pane_current_path}'": RemoteCommandResult(
                exitCode: 0,
                stdout: "work\t0\t%4\tWork\tzsh\t/Users/mark\nops\t0\t%5\tOps\tzsh\t/Users/mark\n"
            )
        ])
        let transport = RecordingTerminalTransport()
        let controller = TerminalSessionController(
            pipeline: TerminalPipeline(
                host: host,
                tmux: TmuxService(shell: shell),
                transport: transport
            )
        )
        let stream = controller.screenBytes()
        let reader = Task<String, Error> {
            var collected = ""
            for try await chunk in stream {
                collected += String(data: chunk, encoding: .utf8) ?? ""
                if collected.contains("hello tmux") {
                    return collected
                }
            }
            return collected
        }

        let snapshot = try await controller.discoverSessions()
        guard
            let session = snapshot.terminalSessions.first(where: { $0.tmuxSessionName == "work" }),
            let secondSession = snapshot.terminalSessions.first(where: { $0.tmuxSessionName == "ops" })
        else {
            throw SelfCheckFailure.assertion("expected controller sessions")
        }

        try await controller.attach(to: session, size: TerminalSize(columns: 120, rows: 40))
        try await controller.attach(to: secondSession, size: TerminalSize(columns: 120, rows: 40))
        try await controller.resizeTerminal(to: TerminalSize(columns: 88, rows: 28))
        try await controller.sendUserText("hello tmux")
        let output = try await reader.value
        let writes = await transport.recordedWrites().compactMap { String(data: $0, encoding: .utf8) }
        let size = await transport.currentSize()

        try expect(output.contains("tmux attach-session -t 'work'"), "expected controller attach stream")
        try expect(output.contains("switch-client -t 'ops'"), "expected controller switch stream")
        try expect(output.contains("hello tmux"), "expected controller send stream")
        try expect(session.windowCount == 1, "expected controller first session window count")
        try expect(session.attachedCount == 0, "expected controller first session attached count")
        try expect(secondSession.windowCount == 1, "expected controller second session window count")
        try expect(secondSession.attachedCount == 0, "expected controller second session attached count")
        try expect(size == TerminalSize(columns: 88, rows: 28), "expected controller resize to reach transport")
        try expect(writes == [
            "tmux attach-session -t 'work'\r",
            "\u{02}:switch-client -t 'ops'\r",
            "hello tmux\r"
        ], "expected controller writes")
    }

    private static func checkOpenSSHArguments() throws {
        #if os(macOS)
        let host = HostProfile(
            displayName: "Mac",
            hostname: "marks-macbook-air.tail79ccb5.ts.net",
            port: 2222,
            username: "mark"
        )

        let shellArgs = OpenSSHCommandBuilder.remoteShellArguments(for: host)
        try expect(shellArgs.contains("-T"), "expected non-PTY remote shell")
        try expect(shellArgs.contains("mark@marks-macbook-air.tail79ccb5.ts.net"), "expected SSH destination")
        try expect(shellArgs.contains("2222"), "expected SSH port")
        try expect(shellArgs.contains("BatchMode=yes"), "expected batch mode")
        try expect(shellArgs.contains("StrictHostKeyChecking=yes"), "expected safe host key policy")

        let terminalArgs = OpenSSHCommandBuilder.terminalArguments(for: host)
        try expect(terminalArgs.contains("-tt"), "expected forced TTY")
        try expect(!terminalArgs.contains("BatchMode=yes"), "expected interactive terminal auth")

        let smokeConfig = OpenSSHConfiguration.smokeTest(
            userKnownHostsFile: "/tmp/terminal-manager-known-hosts",
            identityFile: "/Users/mark/.ssh/id_ed25519",
            configFile: "/Users/mark/.ssh/config",
            extraOptions: ["-o", "LogLevel=ERROR"]
        )
        let smokeArgs = OpenSSHCommandBuilder.remoteShellArguments(for: host, configuration: smokeConfig)
        try expect(smokeArgs.contains("StrictHostKeyChecking=accept-new"), "expected explicit smoke host-key policy")
        try expect(smokeArgs.contains("UserKnownHostsFile=/tmp/terminal-manager-known-hosts"), "expected smoke known-hosts file")
        try expect(smokeArgs.contains("-i"), "expected identity file flag")
        try expect(smokeArgs.contains("/Users/mark/.ssh/id_ed25519"), "expected identity file path")
        try expect(smokeArgs.contains("IdentitiesOnly=yes"), "expected identities-only option")
        try expect(smokeArgs.contains("-F"), "expected config file flag")
        try expect(smokeArgs.contains("/Users/mark/.ssh/config"), "expected config file path")
        try expect(smokeArgs.contains("LogLevel=ERROR"), "expected extra option")
        #endif
    }

    private static func checkSSHAuthPolicy() throws {
        let host = HostProfile(displayName: "Mac", hostname: "mac.tailnet.ts.net", username: "mark")
        let profile = SSHConnectionProfile(host: host)
        try expect(profile.authentication == .agent, "expected agent auth default")
        try expect(profile.hostKeyPolicy == .knownHosts, "expected safe host-key default")
        try expect(!profile.hostKeyPolicy.isUnsafe, "default host-key policy must not be unsafe")
        try expect(SSHHostKeyPolicy.acceptAnyForSmokeOnly.isUnsafe, "smoke-only policy should be marked unsafe")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SelfCheckFailure.assertion(message)
        }
    }

    private static func expect<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw SelfCheckFailure.assertion(message)
        }

        return value
    }
}
