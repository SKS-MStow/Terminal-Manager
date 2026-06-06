# TerminalManager-iOS

SwiftUI app shell for Terminal Manager.

Current source files:

- `TerminalManagerIOSApp.swift`: app entry point.
- `TerminalDashboardView.swift`: session dashboard, black terminal surface, AI sidecar, and composer controls.
- `TerminalManagerViewModel.swift`: UI state backed by real `TerminalManagerCore` model types.
- `PreviewFixtures.swift`: deterministic mock host, tmux sessions, terminal lines, and compacted AI cards.

The package in `Sources/TerminalManagerCore` builds under Command Line Tools.
A runnable iOS target still needs full Xcode selected and an Xcode project or
workspace generated around these sources.

Phone-test prerequisites:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Then create or generate an iOS app target named `Terminal Manager`, add these
Swift files plus `TerminalManagerCore`, select Mark's Apple Developer team, and
run on the connected iPhone.
