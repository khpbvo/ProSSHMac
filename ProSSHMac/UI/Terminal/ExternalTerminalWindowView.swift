import SwiftUI
import Metal

struct ExternalTerminalWindowView: View {
    let sessionID: UUID?

    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TransparencyManager.backgroundOpacityKey) private var terminalBackgroundOpacityPercent = TransparencyManager.defaultBackgroundOpacityPercent
    @AppStorage("terminal.ui.fontSize") private var terminalUIFontSize = 12.0
    @AppStorage("terminal.ui.fontFamily") private var terminalUIFontFamily = FontManager.platformDefaultFontFamily
    @AppStorage("terminal.renderer.useMetal") private var useMetalRenderer = true
    @StateObject private var selectionCoordinator = TerminalSelectionCoordinator()

    private var session: Session? {
        guard let sessionID else { return nil }
        return sessionManager.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    sessionHeader(for: session)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    if session.state == .connected {
                        terminalSurface(for: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        disconnectedPlaceholder(for: session)
                    }
                }
            } else {
                noSessionPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if session == nil {
                dismiss()
            }
        }
    }

    // MARK: - Header

    private func sessionHeader(for session: Session) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if session.isLocal {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .foregroundStyle(.secondary)
                        Text("Local Terminal")
                            .font(.headline)
                    }
                    let shellName = session.shellPath.map { ($0 as NSString).lastPathComponent } ?? "shell"
                    Text("\(session.username)@localhost (\(shellName))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(session.hostLabel)
                            .font(.headline)
                        if session.usesAgentForwarding {
                            Label("Agent Fwd", systemImage: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundStyle(.teal)
                        }
                    }
                    Text("\(session.username)@\(session.hostname):\(session.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(session.state.rawValue.capitalized)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(stateColor(for: session.state).opacity(0.15), in: Capsule())
                .foregroundStyle(stateColor(for: session.state))
        }
    }

    // MARK: - Terminal Surface

    @ViewBuilder
    private func terminalSurface(for session: Session) -> some View {
        let snapshotNonce = sessionManager.gridSnapshotNonceBySessionID[session.id, default: 0]

        if useMetalRenderer, MTLCreateSystemDefaultDevice() != nil {
            MetalTerminalSessionSurface(
                sessionID: session.id,
                snapshotProvider: { sessionManager.gridSnapshot(for: session.id) },
                snapshotNonce: snapshotNonce,
                fontSize: terminalUIFontSize,
                fontFamily: terminalUIFontFamily,
                backgroundOpacityPercent: terminalBackgroundOpacityPercent,
                onTap: nil,
                onTerminalResize: { columns, rows in
                    Task {
                        await sessionManager.resizeTerminal(
                            sessionID: session.id,
                            columns: columns,
                            rows: rows
                        )
                    }
                },
                onScroll: { delta in
                    sessionManager.scrollTerminal(sessionID: session.id, delta: delta)
                },
                isFocused: true,
                isLocalSession: session.isLocal,
                selectionCoordinator: selectionCoordinator
            )
            .id(session.id)
            .background(surfaceBackgroundColor, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(surfaceBorderColor, lineWidth: 1)
            )
            .overlay {
                DirectTerminalInputCaptureView(
                    isEnabled: session.state == .connected,
                    sessionID: session.id,
                    keyEncoderOptions: { keyEncoderOptions(for: session.id) },
                    onCommandShortcut: { action in
                        handleHardwareCommandShortcut(action)
                    },
                    onSendSequence: { sessionID, sequence in
                        Task {
                            await sessionManager.sendRawShellInput(sessionID: sessionID, input: sequence)
                        }
                    }
                )
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        } else {
            Text("Terminal surface unavailable")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Placeholders

    private func disconnectedPlaceholder(for session: Session) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Session Disconnected")
                .font(.title3)
                .foregroundStyle(.secondary)
            if let error = session.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSessionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.slash")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Session Not Found")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("The session may have been closed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Keyboard Input

    private func keyEncoderOptions(for sessionID: UUID) -> KeyEncoderOptions {
        let modeSnapshot = sessionManager.inputModeSnapshotsBySessionID[sessionID] ?? .default
        return KeyEncoderOptions(applicationCursorKeys: modeSnapshot.applicationCursorKeys)
    }

    private func handleHardwareCommandShortcut(_ action: HardwareKeyCommandAction) {
        switch action {
        case .copy:
            copyActiveContentToClipboard()
        case .paste:
            if let sessionID = session?.id {
                pasteClipboardToSession(sessionID)
            }
        case .clearScrollback:
            if let sessionID = session?.id {
                sessionManager.clearShellBuffer(sessionID: sessionID)
            }
        case .increaseFontSize:
            adjustTerminalFontSize(by: 1)
        case .decreaseFontSize:
            adjustTerminalFontSize(by: -1)
        case .resetFontSize:
            terminalUIFontSize = 12.0
        default:
            break
        }
    }

    private func copyActiveContentToClipboard() {
        guard let sessionID = session?.id else { return }
        if let selectedText = selectionCoordinator.copySelection(sessionID: sessionID) {
            _ = PlatformClipboard.writeString(selectedText)
            return
        }
        if let lastLine = sessionManager.shellBuffers[sessionID]?.last, !lastLine.isEmpty {
            _ = PlatformClipboard.writeString(lastLine)
        }
    }

    private func pasteClipboardToSession(_ sessionID: UUID) {
        let bracketedPaste = sessionManager.inputModeSnapshotsBySessionID[sessionID]?.bracketedPasteMode ?? false
        let sequences = PasteHandler.readClipboardSequences(bracketedPasteEnabled: bracketedPaste)
        for sequence in sequences {
            Task {
                await sessionManager.sendRawShellInput(sessionID: sessionID, input: sequence)
            }
        }
    }

    private func adjustTerminalFontSize(by delta: Double) {
        let minSize = 9.0
        let maxSize = 28.0
        terminalUIFontSize = min(maxSize, max(minSize, terminalUIFontSize + delta))
    }

    // MARK: - Helpers

    private func stateColor(for state: SessionState) -> Color {
        switch state {
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var surfaceBackgroundColor: Color {
        let opacityMultiplier = TransparencyManager.normalizedOpacity(fromPercent: terminalBackgroundOpacityPercent)
        let baseOpacity = colorScheme == .dark ? 0.34 : 0.08
        return Color.black.opacity(baseOpacity * opacityMultiplier)
    }

    private var surfaceBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
    }
}

#Preview {
    ExternalTerminalWindowPreview()
}

private struct ExternalTerminalWindowPreview: View {
    @StateObject private var dependencies = AppDependencies()

    var body: some View {
        ExternalTerminalWindowView(sessionID: nil)
            .environmentObject(dependencies.hostListViewModel)
            .environmentObject(dependencies.sessionManager)
            .environmentObject(dependencies.auditLogManager)
            .environmentObject(dependencies.transferManager)
            .environmentObject(dependencies.keyForgeViewModel)
            .environmentObject(dependencies.certificatesViewModel)
            .environmentObject(dependencies.portForwardingManager)
            .environmentObject(dependencies.navigationCoordinator)
    }
}
