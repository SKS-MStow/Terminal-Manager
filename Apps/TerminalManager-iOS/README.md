# TerminalManager-iOS

SwiftUI app shell for Terminal Manager.

Current source files:

- `project.yml`: XcodeGen spec for a real iOS app target.
- `TerminalManagerIOSApp.swift`: app entry point.
- `TerminalDashboardView.swift`: session dashboard, black terminal surface, AI sidecar, and composer controls.
- `TerminalManagerViewModel.swift`: UI state backed by real `TerminalManagerCore` model types.
- `PreviewFixtures.swift`: deterministic mock host, tmux sessions, terminal lines, and compacted AI cards.

The package in `Sources/TerminalManagerCore` builds under Command Line Tools.
A runnable iOS target still needs full Xcode selected and an Xcode project or
workspace generated around these sources.

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
