# TerminalManager-iOS

SwiftUI app shell for Terminal Manager.

Current source files:

- `project.yml`: XcodeGen spec for a real iOS app target.
- `TerminalManagerIOSApp.swift`: app entry point.
- `TerminalDashboardView.swift`: terminal-first tmux surface, tmux session drawer, AI sidecar, and composer controls.
- `TerminalManagerViewModel.swift`: UI state backed by a runtime client and real `TerminalManagerCore` model types.
- `TerminalAppRuntime.swift`: fixture runtime that exercises tmux discover/attach/send plumbing for simulator development.
- `PreviewFixtures.swift`: deterministic mock host, tmux sessions, terminal lines, and compacted AI cards.

The package in `Sources/TerminalManagerCore` builds under Command Line Tools.
The iOS project is generated with XcodeGen and can be run in Simulator or on a
signed iPhone target.

Phone-test prerequisites:

```sh
brew install xcodegen
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Generate and open the project:

```sh
cd Apps/TerminalManager-iOS
xcodegen generate
open TerminalManager.xcodeproj
```

In Xcode, select the `Terminal Manager` target, choose Mark's Apple Developer
team for automatic signing, connect the iPhone, and run the app on the device.

On-device SSH setup:

1. Launch Terminal Manager.
2. Tap the server button in the top bar.
3. Enter the SSH host, username, port, and password.
4. Keep `Allow local/dev unsafe host key` enabled for now.
5. Tap `Save & Connect`.

The app stores host, username, port, and display name in `UserDefaults`. The
password is stored in the iOS Keychain. After saving, the app rebuilds the live
SSH runtime, discovers tmux sessions, and attaches to the selected session.

Live SSH tmux smoke mode is opt-in. Set these environment variables in the
Xcode scheme, or prefix them with `SIMCTL_CHILD_` when launching from `simctl`:

```sh
TERMINAL_MANAGER_LIVE_SSH_ENABLED=1
TERMINAL_MANAGER_LIVE_SSH_HOST=<mac-or-hostname>
TERMINAL_MANAGER_LIVE_SSH_USER=<ssh-user>
TERMINAL_MANAGER_LIVE_SSH_PASSWORD=<ssh-password>
TERMINAL_MANAGER_LIVE_SSH_ALLOW_UNSAFE_HOST_KEY=1
```

Environment smoke settings override saved iPhone settings. If the env vars are
not set, the app uses the saved SSH profile. If no saved profile exists, it uses
the fixture runtime for simulator/demo work.

The unsafe host-key flag is required because the current Citadel bridge only
supports the smoke-only host-key policy. Keep this for local testing only; the
next production path needs known-host or pinned-key support plus Keychain-backed
credential entry.
