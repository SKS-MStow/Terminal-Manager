import Foundation
import TerminalManagerCore

enum PreviewFixtures {
    static let host = HostProfile(
        displayName: "Mark's Mac",
        hostname: "marks-mac.tailnet.ts.net",
        username: "mark",
        preferredTransport: .mosh
    )

    static let sessions: [TerminalSession] = [
        TerminalSession(
            hostId: host.id,
            tmuxSessionName: "codex-terminal-manager",
            windowIndex: 0,
            paneId: "%1",
            title: "Terminal Manager",
            workingDirectory: "/Users/mark/Github/Terminal-Manager",
            agent: .codex,
            transcript: TranscriptLink(
                agent: .codex,
                remotePath: "~/.codex/sessions/terminal-manager.jsonl",
                confidence: .automatic
            ),
            lastActivityAt: Date(timeIntervalSince1970: 1_781_236_800)
        ),
        TerminalSession(
            hostId: host.id,
            tmuxSessionName: "codex-sks-submissions",
            windowIndex: 1,
            paneId: "%2",
            title: "SKS Submissions",
            workingDirectory: "/Users/mark/Github/sks-submissions",
            agent: .codex,
            lastActivityAt: Date(timeIntervalSince1970: 1_781_235_400)
        ),
        TerminalSession(
            hostId: host.id,
            tmuxSessionName: "shell-admin",
            windowIndex: 0,
            paneId: "%3",
            title: "Mac Admin",
            workingDirectory: "/Users/mark",
            agent: nil,
            lastActivityAt: Date(timeIntervalSince1970: 1_781_230_000)
        )
    ]

    static let terminalLines = [
        "mark@Marks-MacBook-Air Terminal-Manager % tmux attach -t codex-terminal-manager",
        "",
        "codex",
        "> continue implementing terminal manager",
        "",
        "- reading Swift package and iOS shell",
        "- updating transcript compaction",
        "- running tmux E2E checks",
        "",
        "Terminal Manager local tmux E2E passed",
        "Terminal Manager self-check passed",
        "",
        "mark@Marks-MacBook-Air Terminal-Manager %"
    ]

    static let sidecarCards: [CompactedAgentActivityCard] = [
        CompactedAgentActivityCard(
            kind: .thinking,
            title: "Thinking",
            preview: "Checked the current tmux pipeline and chose a sidecar-only compaction path.",
            blockCount: 3,
            sourceBlockIds: [UUID(), UUID(), UUID()],
            metadata: [
                "hiddenBlockCount": "2",
                "sourceKinds": "thinking"
            ]
        ),
        CompactedAgentActivityCard(
            kind: .toolCall,
            title: "exec_command",
            preview: "swift run terminal-manager-local-e2e\n\nTerminal Manager local tmux E2E passed",
            blockCount: 2,
            sourceBlockIds: [UUID(), UUID()],
            metadata: [
                "callId": "call_7",
                "status": "completed",
                "toolNames": "exec_command",
                "hiddenCharacterCount": "0"
            ]
        ),
        CompactedAgentActivityCard(
            kind: .assistantMessage,
            title: "Assistant",
            preview: "The core sidecar compaction path is merged and verified.",
            blockCount: 1,
            sourceBlockIds: [UUID()]
        )
    ]
}
