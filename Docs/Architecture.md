# Architecture

## Principles

- **tmux is truth.** Desktop and iPhone attach to the same session.
- **Terminal output is not rewritten.** Compaction happens only in a separate AI sidecar.
- **Mac owns execution.** The phone never runs agents or receives filesystem credentials beyond SSH/Mosh access.
- **Tailscale first.** No relay server for MVP.
- **Personal app first.** Optimize for Mark's iPhone and Mac before generic host management.

## Components

### iOS App

SwiftUI app named `Terminal Manager`.

Responsibilities:

- host terminal renderer,
- manage host profile and credentials in Keychain,
- show tmux session dashboard,
- attach to tmux sessions through SSH/Mosh,
- record voice notes and transcribe them locally/on-device where possible,
- upload attachments,
- render the AI sidecar drawer.

### TerminalManagerCore

Shared Swift library.

Responsibilities:

- host and session models,
- terminal transport interfaces,
- tmux command construction/parsing,
- transcript parsing and correlation,
- attachment remote path rules.

### Mac

No helper daemon in MVP.

Required tools:

- Tailscale,
- SSH server reachable from iPhone on the tailnet,
- Mosh server for the preferred transport,
- tmux,
- Codex and/or Claude CLIs.

## Transport

`TerminalTransport` abstracts live terminal I/O:

- `ssh` is acceptable as the first working spike.
- `mosh` is the target for the snappy roaming experience.
- both must support writes, resize, and byte streams into the renderer.

## AI Sidecar

The sidecar reads transcript files rather than terminal output:

- Codex: `~/.codex/sessions/*.jsonl`
- Claude: local Claude transcript/session files when available

Correlation uses:

- current pane command,
- pane working directory,
- transcript path,
- timestamps,
- manual link/unlink fallback.

The sidecar emits raw parsed blocks and compacted cards. Raw parsed blocks preserve
the transcript detail; compacted cards give the iOS drawer short expandable rows.
Terminal scrollback is never folded, rewritten, or hidden by this process.

Raw parsed block kinds:

- thinking,
- tool call,
- plan,
- approval,
- user message,
- assistant message,
- file,
- system.

## Attachment Flow

1. User picks camera, photo library, or file.
2. App uploads to `~/TerminalManager/attachments/<tmux-session>/`.
3. App inserts the remote path into the terminal composer.
4. The agent can read the file from the Mac filesystem.

## Out of Scope for MVP

- Public App Store distribution.
- Hosted relay.
- Mac helper daemon.
- Terminal folding that changes rendered scrollback.
- Multi-user or generic enterprise host management.
