import SwiftUI
import TerminalManagerCore

@main
struct TerminalManagerIOSApp: App {
    var body: some Scene {
        WindowGroup {
            TerminalDashboardView()
        }
    }
}

struct TerminalDashboardView: View {
    private let placeholderHost = HostProfile(
        displayName: "Mark's Mac",
        hostname: "marks-mac.tailnet.ts.net",
        username: "mark"
    )

    var body: some View {
        NavigationStack {
            List {
                Section("Host") {
                    LabeledContent("Name", value: placeholderHost.displayName)
                    LabeledContent("Transport", value: placeholderHost.preferredTransport.rawValue.uppercased())
                }

                Section("Next") {
                    Text("Wire SSH/Mosh transport, tmux discovery, and SwiftTerm rendering.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(TerminalManagerCore.productName)
        }
    }
}
