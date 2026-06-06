# MVP Build Plan

## M0 - Repo and Core

- Swift package compiles.
- Core models exist for host, tmux session, terminal session, transcript links, and activity blocks.
- tmux list/capture/start command handling is unit-tested.
- Attachment paths are deterministic and shell-safe.

## M1 - Local SSH Slice

- Add an SSH transport implementation.
- Connect to the Mac over Tailscale.
- List tmux sessions.
- Attach to a selected session.
- Render bytes through SwiftTerm in a simple iOS screen.
- Send typed text and resize events.

## M2 - Mosh Slice

- Add Mosh transport behind the same `TerminalTransport` interface.
- Verify roaming/reconnect by switching networks and backgrounding the app.
- Keep SSH as fallback.

## M3 - tmux Dashboard

- Session list with running/attached state.
- Start Codex/Claude session from selected project.
- Attach to existing sessions.
- Capture/search scrollback using `tmux capture-pane`.

## M4 - AI Sidecar

- Read Codex transcript files.
- Add Claude transcript support.
- Correlate transcript to tmux pane.
- Parse raw activity blocks and render compacted, collapsible sidecar cards.
- Allow manual transcript link/unlink.
- Never fold or rewrite the terminal renderer; compaction is sidecar-only.

## M5 - Rich Input

- Voice note recording and on-iPhone transcription.
- Camera/photo/file picker.
- SFTP upload into `~/TerminalManager/attachments`.
- Paste remote file path into the terminal.

## Acceptance

- A Codex session visible in Ghostty is attachable from iPhone without forking.
- Desktop and iPhone see the same tmux session.
- Sidecar can hide thinking/tool noise while terminal remains unchanged.
- Phone can send voice-transcribed text and image paths into the active agent session.
