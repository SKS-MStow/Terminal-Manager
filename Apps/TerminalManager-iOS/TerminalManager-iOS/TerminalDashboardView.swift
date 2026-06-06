import SwiftUI
import TerminalManagerCore

struct TerminalDashboardView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var viewModel = TerminalManagerViewModel()

    private var compactLayout: Bool {
        horizontalSizeClass == .compact
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                appBody
                    .background(AppColor.background)

                if viewModel.sidecarOpen {
                    SidecarPanel(cards: viewModel.sidecarCards)
                        .frame(width: sidecarWidth(in: geometry.size.width))
                        .frame(maxHeight: .infinity)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .shadow(color: .black.opacity(0.35), radius: 18, x: -8, y: 0)
                }

                if viewModel.tmuxDrawerOpen {
                    TmuxSessionDrawer(
                        sessions: viewModel.sessions,
                        selectedSession: viewModel.selectedSession,
                        onSelect: viewModel.select
                    )
                    .frame(maxHeight: drawerHeight(in: geometry.size.height))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: -8)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.connectionSheetOpen) {
            ConnectionSetupSheet(
                draft: $viewModel.connectionDraft,
                statusText: viewModel.connectionStatusText,
                onSave: {
                    Task {
                        await viewModel.saveConnectionAndConnect()
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }

            Task {
                await viewModel.refreshTmuxSessions()
            }
        }
    }

    @ViewBuilder
    private var appBody: some View {
        VStack(spacing: 0) {
            AppTopBar(
                host: viewModel.host,
                statusText: viewModel.statusText,
                session: viewModel.selectedSession,
                sessionCount: viewModel.sessions.count,
                onShowSessions: {
                    withAnimation(.snappy) {
                        viewModel.toggleTmuxDrawer()
                    }
                },
                onShowConnectionSettings: {
                    viewModel.openConnectionSettings()
                },
                onToggleSidecar: {
                    withAnimation(.snappy) {
                        viewModel.toggleSidecar()
                    }
                }
            )

            TerminalWorkspace(viewModel: viewModel)
        }
    }

    private func sidecarWidth(in containerWidth: CGFloat) -> CGFloat {
        let regularWidth: CGFloat = compactLayout ? 324 : 380
        return min(regularWidth, max(260, containerWidth - 32))
    }

    private func drawerHeight(in containerHeight: CGFloat) -> CGFloat {
        min(compactLayout ? 360 : 420, max(260, containerHeight * 0.48))
    }
}

private struct AppTopBar: View {
    var host: HostProfile
    var statusText: String
    var session: TerminalSession
    var sessionCount: Int
    var onShowSessions: () -> Void
    var onShowConnectionSettings: () -> Void
    var onToggleSidecar: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HostStatusView(host: host, statusText: statusText)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColor.primaryText)
                    .lineLimit(1)
                Text(session.tmuxSessionName)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                withAnimation(.snappy) {
                    onShowSessions()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.fill")
                    Text("\(sessionCount)")
                        .font(.caption.weight(.bold))
                }
                .frame(height: 34)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColor.primaryText)
            .background(AppColor.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("tmux sessions")

            Button(action: onShowConnectionSettings) {
                Image(systemName: "server.rack")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColor.primaryText)
            .accessibilityLabel("SSH connection")

            Button(action: onToggleSidecar) {
                Image(systemName: "sparkles.rectangle.stack")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColor.primaryText)
            .accessibilityLabel("AI sidecar")
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(AppColor.header)
    }
}

private struct HostStatusView: View {
    var host: HostProfile
    var statusText: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AppColor.online)
                .frame(width: 8, height: 8)
            Text(statusText.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColor.secondaryText)
        }
        .accessibilityLabel("\(host.displayName), \(statusText)")
    }
}

private struct ConnectionSetupSheet: View {
    @Binding var draft: SavedSSHConnectionDraft
    var statusText: String
    var onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("SSH") {
                    TextField("Display name", text: $draft.displayName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Host", text: $draft.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        TextField("Username", text: $draft.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", text: $draft.port)
                            .keyboardType(.numberPad)
                            .frame(width: 72)
                    }
                    SecureField("Password", text: $draft.password)
                        .textContentType(.password)
                }

                Section("Host Key") {
                    Toggle("Allow local/dev unsafe host key", isOn: $draft.allowUnsafeHostKeyPolicy)
                    Text("Required until pinned or known-host validation is implemented in the Citadel bridge.")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }

                Section {
                    Button(action: onSave) {
                        HStack {
                            Image(systemName: "bolt.horizontal.fill")
                            Text("Save & Connect")
                        }
                    }
                    .disabled(!draft.allowUnsafeHostKeyPolicy)
                } footer: {
                    Text(statusText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColor.background)
            .navigationTitle("SSH Connection")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

private struct SessionStrip: View {
    var sessions: [TerminalSession]
    var selectedSession: TerminalSession
    var onSelect: (TerminalSession) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessions) { session in
                    SessionChip(session: session, selected: session.id == selectedSession.id) {
                        onSelect(session)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(AppColor.surface)
    }
}

private struct SessionSidebar: View {
    var sessions: [TerminalSession]
    var selectedSession: TerminalSession
    var onSelect: (TerminalSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sessions")
                .font(.headline)
                .foregroundStyle(AppColor.primaryText)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sessions) { session in
                        SessionRow(session: session, selected: session.id == selectedSession.id) {
                            onSelect(session)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
        }
        .background(AppColor.surface)
    }
}

private struct SessionChip: View {
    var session: TerminalSession
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(session.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? AppColor.inverseText : AppColor.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(selected ? AppColor.accent : AppColor.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    var session: TerminalSession
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(selected ? AppColor.inverseText : AppColor.accent)
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(session.tmuxSessionName)
                        .font(.caption2)
                        .foregroundStyle(selected ? AppColor.inverseText.opacity(0.72) : AppColor.secondaryText)
                        .lineLimit(1)
                }

                Text(session.workingDirectory ?? "~")
                    .font(.caption)
                    .foregroundStyle(selected ? AppColor.inverseText.opacity(0.72) : AppColor.secondaryText)
                    .lineLimit(1)

                if let windowIndex = session.windowIndex {
                    Text("tmux:\(session.tmuxSessionName) window:\(windowIndex)")
                        .font(.caption2)
                        .foregroundStyle(selected ? AppColor.inverseText.opacity(0.68) : AppColor.secondaryText)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? AppColor.inverseText : AppColor.primaryText)
            .padding(12)
            .background(selected ? AppColor.accent : AppColor.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalWorkspace: View {
    @ObservedObject var viewModel: TerminalManagerViewModel

    var body: some View {
        VStack(spacing: 0) {
            TerminalSurface(lines: viewModel.terminalLines, terminalSize: viewModel.terminalSize)
            ComposerBar(
                text: $viewModel.composerText,
                pendingAttachmentCount: viewModel.pendingAttachments.count,
                onSend: viewModel.sendComposerText,
                onVoice: { viewModel.queuePlaceholderAttachment(kind: .audio) },
                onCamera: { viewModel.queuePlaceholderAttachment(kind: .image) },
                onPhotos: { viewModel.queuePlaceholderAttachment(kind: .image) },
                onFiles: { viewModel.queuePlaceholderAttachment(kind: .file) }
            )
        }
        .background(.black)
    }
}

private struct TerminalHeader: View {
    var session: TerminalSession
    var sessionCount: Int
    var onShowSessions: () -> Void
    var onToggleSidecar: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.connected.to.line.below")
                .foregroundStyle(AppColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColor.primaryText)
                    .lineLimit(1)
                Text(session.tmuxSessionName)
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onShowSessions) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.fill")
                    Text("\(sessionCount)")
                        .font(.caption.weight(.bold))
                }
                .frame(height: 36)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColor.primaryText)
            .background(AppColor.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("tmux sessions")

            Button(action: onToggleSidecar) {
                Image(systemName: "sparkles.rectangle.stack")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColor.primaryText)
            .accessibilityLabel("AI sidecar")
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(AppColor.header)
    }
}

private struct TmuxSessionDrawer: View {
    var sessions: [TerminalSession]
    var selectedSession: TerminalSession
    var onSelect: (TerminalSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(AppColor.accent)
                Text("tmux")
                    .font(.headline)
                    .foregroundStyle(AppColor.primaryText)
                Text("\(sessions.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppColor.inverseText)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(AppColor.accent)
                    .clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sessions) { session in
                        SessionRow(session: session, selected: session.id == selectedSession.id) {
                            onSelect(session)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity)
        .background(AppColor.surface)
    }
}

private struct TerminalSurface: View {
    var lines: [String]
    var terminalSize: TerminalSize

    var body: some View {
        GeometryReader { geometry in
            let metrics = TerminalGridMetrics.fitting(
                terminalSize: terminalSize,
                availableWidth: Double(geometry.size.width),
                availableHeight: Double(geometry.size.height)
            )
            let terminalFont = Font.system(size: CGFloat(metrics.fontSize), weight: .regular, design: .monospaced)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(terminalFont)
                                .foregroundStyle(AppColor.terminalText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                                .frame(width: CGFloat(metrics.gridWidth), height: CGFloat(metrics.lineHeight), alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, CGFloat(metrics.horizontalPadding))
                    .padding(.vertical, CGFloat(metrics.verticalPadding))
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
                .background(.black)
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: lines.count) { _, _ in
                    scrollToBottom(proxy)
                }
            }
        }
        .background(.black)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = lines.indices.last else {
            return
        }

        DispatchQueue.main.async {
            withAnimation(.linear(duration: 0.08)) {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }
}

private struct ComposerBar: View {
    @Binding var text: String
    var pendingAttachmentCount: Int
    var onSend: () -> Void
    var onVoice: () -> Void
    var onCamera: () -> Void
    var onPhotos: () -> Void
    var onFiles: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if pendingAttachmentCount > 0 {
                HStack {
                    Image(systemName: "paperclip")
                    Text("\(pendingAttachmentCount) pending")
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColor.secondaryText)
            }

            HStack(spacing: 8) {
                IconButton(systemName: "mic.fill", label: "Voice", action: onVoice)
                IconButton(systemName: "camera.fill", label: "Camera", action: onCamera)
                IconButton(systemName: "photo.on.rectangle", label: "Photos", action: onPhotos)
                IconButton(systemName: "doc.fill", label: "Files", action: onFiles)

                TextField("Send to tmux", text: $text, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(AppColor.primaryText)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AppColor.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(text.isEmpty ? AppColor.secondaryText : AppColor.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
            }
        }
        .padding(10)
        .background(AppColor.header)
    }
}

private struct SidecarPanel: View {
    var cards: [CompactedAgentActivityCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(AppColor.primaryText)
                Spacer()
                Text("\(cards.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColor.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(cards) { card in
                        SidecarCard(card: card)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
        }
        .background(AppColor.surface)
    }
}

private struct SidecarCard: View {
    var card: CompactedAgentActivityCard
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.snappy) {
                expanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColor.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if card.blockCount > 1 {
                        Text("\(card.blockCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppColor.inverseText)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(AppColor.accent)
                            .clipShape(Capsule())
                    }
                }

                Text(card.preview)
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(expanded ? nil : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let status = card.metadata["status"] {
                    Text(status.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppColor.online)
                }
            }
            .padding(12)
            .background(AppColor.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch card.kind {
        case .thinking:
            return "brain.head.profile"
        case .toolCall:
            return "wrench.and.screwdriver"
        case .plan:
            return "checklist"
        case .approval:
            return "hand.raised.fill"
        case .assistantMessage:
            return "text.bubble.fill"
        case .userMessage:
            return "person.fill"
        case .file:
            return "doc.fill"
        case .system:
            return "gearshape.fill"
        }
    }

    private var iconColor: Color {
        switch card.kind {
        case .toolCall:
            return AppColor.warning
        case .thinking, .plan:
            return AppColor.accent
        case .approval:
            return AppColor.danger
        default:
            return AppColor.secondaryText
        }
    }
}

private struct IconButton: View {
    var systemName: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColor.primaryText)
                .frame(width: 34, height: 34)
                .background(AppColor.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private enum AppColor {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.05)
    static let surface = Color(red: 0.08, green: 0.09, blue: 0.09)
    static let elevated = Color(red: 0.13, green: 0.14, blue: 0.14)
    static let header = Color(red: 0.06, green: 0.07, blue: 0.07)
    static let accent = Color(red: 0.24, green: 0.72, blue: 0.62)
    static let online = Color(red: 0.30, green: 0.86, blue: 0.45)
    static let warning = Color(red: 0.95, green: 0.70, blue: 0.30)
    static let danger = Color(red: 0.95, green: 0.36, blue: 0.36)
    static let primaryText = Color.white
    static let inverseText = Color.black
    static let secondaryText = Color.white.opacity(0.64)
    static let terminalText = Color.white.opacity(0.90)
}
