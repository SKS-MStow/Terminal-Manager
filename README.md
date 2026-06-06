# Terminal Manager

Terminal Manager is a native iOS front end for real tmux-based terminal sessions on your Mac.

The app is intentionally **terminal first**:

- Your Mac keeps running `tmux`, `mosh`, `ssh`, Codex, Claude, and local tools.
- The iPhone connects over Tailscale and attaches to the same tmux sessions you use in Ghostty.
- The rendered terminal stays raw and faithful.
- AI-specific niceties live in a sidecar overlay that reads agent transcript files instead of mutating terminal output.

## Current shape

This repo is a clean start and does not reuse the old `Agent-Manager` codebase.

```
Terminal-Manager/
├── Apps/
│   └── TerminalManager-iOS/      # SwiftUI app shell
├── Sources/
│   └── TerminalManagerCore/      # Shared models, tmux service, transcript sidecar
├── Tests/
│   └── TerminalManagerCoreTests/
└── Docs/
```

## MVP architecture

1. iPhone connects to your Mac over Tailscale.
2. Terminal transport uses Mosh as the target protocol, with SSH as the first validation path.
3. tmux is the durable session layer.
4. `SwiftTerm` is the intended terminal renderer for the iOS app.
5. Codex/Claude transcript files power the collapsible AI sidecar.
6. Voice notes transcribe on iPhone first, then the edited text is sent into the terminal.
7. Images and files upload to `~/TerminalManager/attachments/<tmux-session>/` and the path is pasted into the active terminal.

## Local build

The shared package builds with Command Line Tools. This Mac's Command Line Tools
do not currently expose `Testing` or `XCTest`, so the repo includes a self-check
executable instead of a Swift test target for now:

```sh
swift build
swift run terminal-manager-selfcheck
```

The iOS app target needs full Xcode selected, not only Command Line Tools:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## First validation target

The first working slice should:

- list tmux sessions on the Mac,
- attach to one session from iPhone,
- render the live terminal,
- send text into the session,
- read tmux history,
- show parsed Codex/Claude transcript blocks in a sidecar drawer.
