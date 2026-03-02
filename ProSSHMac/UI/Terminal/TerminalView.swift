// swiftlint:disable file_length
import SwiftUI
import UniformTypeIdentifiers
import Metal
import Combine
import AppKit

struct TerminalView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var navigationCoordinator: AppNavigationCoordinator
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var transferManager: TransferManager
    @EnvironmentObject private var portForwardingManager: PortForwardingManager
    @EnvironmentObject private var terminalAIAssistantViewModel: TerminalAIAssistantViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(BellEffectController.settingsKey) private var bellFeedbackModeRawValue = BellFeedbackMode.none.rawValue
    @AppStorage(TransparencyManager.backgroundOpacityKey) private var terminalBackgroundOpacityPercent = TransparencyManager.defaultBackgroundOpacityPercent
    @AppStorage("terminal.ui.fontSize") private var terminalUIFontSize = 12.0
    @AppStorage("terminal.ui.fontFamily") private var terminalUIFontFamily = FontManager.platformDefaultFontFamily
    @AppStorage("terminal.renderer.useMetal") private var useMetalRenderer = true
    @AppStorage("terminal.renderer.migration.restoreMetal.v1") private var didRestoreMetalPreference = false
    @AppStorage("terminal.renderer.migration.defaultMetal.v2") private var didApplyMetalDefaultV2 = false
    @AppStorage("terminal.sidebar.fileBrowser.visible") private var showFileBrowser = false
    @AppStorage("terminal.sidebar.fileBrowser.width") private var fileBrowserWidth = 260.0
    @AppStorage("terminal.sidebar.aiAssistant.visible") private var showAIAssistant = false
    @AppStorage("terminal.sidebar.aiAssistant.width") private var aiAssistantWidth = 420.0
    @State private var pendingInput: [UUID: String] = [:]
    @StateObject private var bellEffect = BellEffectController()
    @StateObject private var resizeEffect = ResizeEffectController()
    @StateObject private var tabManager = SessionTabManager()
    @StateObject private var terminalSearch = TerminalSearch()
    @StateObject private var selectionCoordinator = TerminalSelectionCoordinator()
    @StateObject private var paneManager = PaneManager()
    @State private var pendingPaneSessionCreation: Set<UUID> = []
    @StateObject private var quickCommands = QuickCommands()
    @FocusState private var focusedSessionID: UUID?
    @State private var closeConfirmationSession: Session?
    @State private var secureInputOverride: Bool?
    @State private var directInputBufferBySessionID: [UUID: String] = [:]
    @State private var directInputActivationNonce: Int = 0
    @State private var searchFocusNonce: Int = 0
    @State private var isSearchBarFocused: Bool = false
    @State private var isAIAssistantComposerFocused = false
    @State private var fileBrowserDragBaseWidth: Double?
    @State private var aiAssistantDragBaseWidth: Double?
    @State private var loadedSidebarLayoutContextKey: String?
    @State private var isApplyingSidebarLayout = false
    var body: some View {
        terminalLifecycleView
        .alert(
            "Close Active Session?",
            isPresented: Binding(
                get: { closeConfirmationSession != nil },
                set: { show in
                    if !show { closeConfirmationSession = nil }
                }
            ),
            presenting: closeConfirmationSession
        ) { session in
            Button("Cancel", role: .cancel) {
                closeConfirmationSession = nil
            }
            Button("Disconnect & Close", role: .destructive) {
                closeConfirmationSession = nil
                closeSession(session)
            }
        } message: { session in
            Text("Disconnect and close the active session for \(session.hostLabel)?")
        }
        .toolbar {
            if supportsMultitaskingControls {
                ToolbarItem(placement: newWindowToolbarPlacement) {
                    Button {
                        navigationCoordinator.toggleTerminalMaximize()
                    } label: {
                        Label(
                            navigationCoordinator.isTerminalMaximized ? "Restore Sidebar" : "Maximize Terminal",
                            systemImage: navigationCoordinator.isTerminalMaximized
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                }
            }

            if sessionManager.sessions.filter({ $0.state == .connected || $0.state == .connecting }).count > 1 {
                ToolbarItem(placement: .automatic) {
                    Button(role: .destructive) {
                        Task {
                            await sessionManager.disconnectAll()
                        }
                    } label: {
                        Label("Disconnect All", systemImage: "xmark.circle.fill")
                    }
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    showAIAssistant.toggle()
                } label: {
                    Label("AI Copilot", systemImage: showAIAssistant ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
                }
            }

            ToolbarItemGroup(placement: .keyboard) {
                Button("Esc") { sendControl("\u{1B}") }
                Button("Tab") { sendControl("\t") }
                Button("↑") { sendControl("\u{1B}[A") }
                Button("↓") { sendControl("\u{1B}[B") }
                Button("←") { sendControl("\u{1B}[D") }
                Button("→") { sendControl("\u{1B}[C") }
                Button("Ctrl-C") { sendControl("\u{03}") }
                Button("Ctrl-D") { sendControl("\u{04}") }
            }
        }
    }

    private var terminalBaseView: some View {
        ZStack {
            terminalContentWithFileBrowser

            TerminalKeyboardShortcutLayer(
                onSendCommand:         { sendSelectedCommandShortcut() },
                onSendCtrlC:           { sendControl("\u{03}") },
                onSendCtrlD:           { sendControl("\u{04}") },
                onShowSearch:          { showSearchBar() },
                onToggleQuickCommands: { quickCommands.toggleDrawer() },
                onToggleFileBrowser:   { showFileBrowser.toggle() },
                onToggleAIAssistant:   { showAIAssistant.toggle() },
                onClearBuffer:         { clearSelectedBuffer() },
                onPreviousSession:     { stepSelectedSession(direction: -1) },
                onNextSession:         { stepSelectedSession(direction: 1) },
                onDisconnectOrClose:   { disconnectOrCloseSelectedSession() },
                onSplitRight:          { splitNextAvailableSession(direction: .vertical) },
                onSplitDown:           { splitNextAvailableSession(direction: .horizontal) },
                onFocusNextPane:       { paneManager.focusNext() },
                onFocusPreviousPane:   { paneManager.focusPrevious() },
                onMaximizePane:        { paneManager.toggleMaximize(paneManager.focusedPaneId) },
                onNewLocalTerminal:    { openLocalTerminal() },
                onZoomIn:              { adjustTerminalFontSize(by: 1) },
                onZoomOut:             { adjustTerminalFontSize(by: -1) },
                onCopy:                { copyActiveContentToClipboard() },
                onPaste:               {
                    let sid = paneManager.focusedSessionID ?? focusedSessionID ?? tabManager.selectedSessionID
                    if let sessionID = sid { pasteClipboardToSession(sessionID) }
                },
                onSelectAll:           { selectAllInFocusedTerminal() },
                onToggleMaximize:      { navigationCoordinator.toggleTerminalMaximize() }
            )
            .frame(width: 0, height: 0)
            .opacity(0.001)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .overlay {
            TerminalQuickCommandPanel(
                quickCommands: quickCommands,
                selectedSession: selectedSession,
                onSendShellInput: { sid, input in
                    Task { await sessionManager.sendShellInput(sessionID: sid, input: input) }
                }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: showFileBrowser)
        .animation(.easeInOut(duration: 0.2), value: showAIAssistant)
        .navigationTitle("Terminal")
    }

    private var terminalLifecycleView: some View {
        terminalBaseView
        .onAppear {
            if !didRestoreMetalPreference {
                if isMetalRendererAvailable {
                    useMetalRenderer = true
                }
                didRestoreMetalPreference = true
            }
            if !didApplyMetalDefaultV2 {
                useMetalRenderer = isMetalRendererAvailable
                didApplyMetalDefaultV2 = true
            }
            tabManager.sync(with: sessionManager.sessions)
            synchronizeSelection()
            updateSearchLines()
            syncPaneManagerSessions()
            restoreSidebarLayoutForSelection()
        }
        .onChange(of: sessionManager.sessions) { _, _ in
            Task { @MainActor in
                tabManager.sync(with: sessionManager.sessions)
                synchronizeSelection()
                updateSearchLines()
                syncPaneManagerSessions()
                restoreSidebarLayoutForSelection()
            }
        }
        .onChange(of: tabManager.selectedSessionID) { _, _ in
            resizeEffect.reset()
            updateSearchLines()
            restoreSidebarLayoutForSelection()
        }
        .onChange(of: showFileBrowser) { _, _ in
            persistSidebarLayoutForSelection()
        }
        .onChange(of: showAIAssistant) { _, _ in
            if !showAIAssistant {
                isAIAssistantComposerFocused = false
            }
            persistSidebarLayoutForSelection()
        }
        .onChange(of: fileBrowserWidth) { _, _ in
            persistSidebarLayoutForSelection()
        }
        .onChange(of: aiAssistantWidth) { _, _ in
            persistSidebarLayoutForSelection()
        }
        .onChange(of: paneManager.focusedPaneId) { _, newPaneID in
            // When the user clicks a different pane, sync tab selection
            // so that DirectTerminalInputCaptureView enables for the
            // correct session and keyboard input is routed properly.
            if let sessionID = paneManager.rootNode.findPane(id: newPaneID)?.sessionID,
               sessionID != tabManager.selectedSessionID {
                tabManager.select(sessionID: sessionID)
            }
        }
        .onChange(of: useMetalRenderer) { _, _ in
            resizeEffect.reset()
        }
    }

    private var macOSBody: some View {
        let terminalOnlyMode = navigationCoordinator.isTerminalMaximized

        return VStack(alignment: .leading, spacing: 0) {
            if sessionManager.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Active Sessions")
                        .font(.headline)
                    Text("Connect to a host from the Hosts tab to start an SSH session.")
                        .foregroundStyle(.secondary)

                    Button {
                        openLocalTerminal()
                    } label: {
                        Label("Open Local Terminal", systemImage: "terminal.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if paneManager.paneCount > 1 || paneManager.maximizedPaneId != nil {
                if !terminalOnlyMode {
                    TerminalSessionTabBar(
                        tabManager: tabManager,
                        paneManager: paneManager,
                        onRequestClose: { s in requestCloseSession(s) },
                        onOpenLocalTerminal: { openLocalTerminal() },
                        onSplitWithExisting: { sid, pid, dir in splitWithExistingSession(sid, beside: pid, direction: dir) }
                    )
                    .padding(.vertical, 8)
                }

                SplitNodeView(
                    node: paneManager.displayNode,
                    paneManager: paneManager,
                    onNewSSHSession: { _ in navigationCoordinator.navigate(to: .hosts) },
                    onNewLocalTerminal: { _ in openLocalTerminal() },
                    onMoveToNewTab: { paneID in moveToNewTab(paneID: paneID) },
                    onSplitWithNewSession: { sourceSessionID in
                        createSessionForNewPane(duplicatingFrom: sourceSessionID)
                    },
                    availableSessions: tabManager.tabs.map { ($0.id, $0.session.hostLabel) },
                    onSplitWithExistingSession: { sessionID, paneID, direction in
                        splitWithExistingSession(sessionID, beside: paneID, direction: direction)
                    }
                ) { pane in
                    if let session = sessionForPane(pane) {
                        let paneFocused = pane.id == paneManager.focusedPaneId
                        if terminalOnlyMode {
                            TerminalSurfaceView(
                                session: session,
                                isFocused: paneFocused,
                                paneID: pane.id,
                                bellEffect: bellEffect,
                                resizeEffect: resizeEffect,
                                selectionCoordinator: selectionCoordinator,
                                terminalSearch: terminalSearch,
                                paneManager: paneManager,
                                tabManager: tabManager,
                                onFocusTap: { focusSessionAndPane(session.id, paneID: pane.id) },
                                onPaste: { sid in pasteClipboardToSession(sid) },
                                onCopy: { sid in copyContentToClipboard(sessionID: sid) },
                                onSplitWithExisting: { sid, pid, dir in splitWithExistingSession(sid, beside: pid, direction: dir) }
                            )
                            .id(session.id)
                            .overlay {
                                directTerminalInputOverlay(for: session)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            sessionPanel(for: session, paneID: pane.id, includeSearch: paneFocused, isFocused: paneFocused)
                                .padding(.horizontal)
                                .padding(.bottom, 8)
                        }
                    } else {
                        noSessionPlaceholder
                    }
                }
            } else {
                if !terminalOnlyMode {
                    TerminalSessionTabBar(
                        tabManager: tabManager,
                        paneManager: paneManager,
                        onRequestClose: { s in requestCloseSession(s) },
                        onOpenLocalTerminal: { openLocalTerminal() },
                        onSplitWithExisting: { sid, pid, dir in splitWithExistingSession(sid, beside: pid, direction: dir) }
                    )
                    .padding(.vertical, 8)
                }

                if let session = selectedSession {
                    if terminalOnlyMode {
                        TerminalSurfaceView(
                            session: session,
                            isFocused: true,
                            paneID: nil,
                            bellEffect: bellEffect,
                            resizeEffect: resizeEffect,
                            selectionCoordinator: selectionCoordinator,
                            terminalSearch: terminalSearch,
                            paneManager: paneManager,
                            tabManager: tabManager,
                            onFocusTap: { focusSessionAndPane(session.id, paneID: nil) },
                            onPaste: { sid in pasteClipboardToSession(sid) },
                            onCopy: { sid in copyContentToClipboard(sessionID: sid) },
                            onSplitWithExisting: { sid, pid, dir in splitWithExistingSession(sid, beside: pid, direction: dir) }
                        )
                        .id(session.id)
                        .overlay {
                            directTerminalInputOverlay(for: session)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        sessionPanel(for: session, includeSearch: true)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sessionPanel(
        for session: Session,
        paneID: UUID? = nil,
        includeSearch: Bool,
        isFocused: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TerminalSessionHeaderView(session: session)

            TerminalSessionMetadataView(session: session)

            if includeSearch, terminalSearch.isPresented {
                TerminalSearchBarView(
                    terminalSearch: terminalSearch,
                    focusFieldNonce: searchFocusNonce,
                    onHide: { hideSearchBar() },
                    onFocusChanged: { v in isSearchBarFocused = v }
                )
            }

            if session.state == .connected {
                TerminalSurfaceView(
                    session: session,
                    isFocused: isFocused,
                    paneID: paneID,
                    bellEffect: bellEffect,
                    resizeEffect: resizeEffect,
                    selectionCoordinator: selectionCoordinator,
                    terminalSearch: terminalSearch,
                    paneManager: paneManager,
                    tabManager: tabManager,
                    onFocusTap: { focusSessionAndPane(session.id, paneID: paneID) },
                    onPaste: { sid in pasteClipboardToSession(sid) },
                    onCopy: { sid in copyContentToClipboard(sessionID: sid) },
                    onSplitWithExisting: { sid, pid, dir in splitWithExistingSession(sid, beside: pid, direction: dir) }
                )
                .id(session.id)
                .overlay {
                    directTerminalInputOverlay(for: session)
                }
            }

            TerminalSessionActionsBar(session: session, onRestartLocal: { s in restartLocalSession(s) })
        }
    }

    private var selectedSession: Session? {
        if let selectedSessionID = tabManager.selectedSessionID {
            return tabManager.tabs.first(where: { $0.id == selectedSessionID })?.session
        }
        return tabManager.tabs.first?.session
    }

    private func sidebarLayoutContextKey(for session: Session) -> String {
        TerminalSidebarLayoutStore.contextKey(for: session)
    }

    private func sidebarLayoutStorageKey(_ suffix: String, context: String) -> String {
        TerminalSidebarLayoutStore.storageKey(suffix, context: context)
    }

    private func restoreSidebarLayoutForSelection() {
        guard let session = selectedSession else { return }
        let contextKey = TerminalSidebarLayoutStore.contextKey(for: session)
        guard loadedSidebarLayoutContextKey != contextKey else { return }
        isApplyingSidebarLayout = true
        defer { isApplyingSidebarLayout = false; loadedSidebarLayoutContextKey = contextKey }
        let values = TerminalSidebarLayoutStore.restore(contextKey: contextKey)
        if let v = values.showFileBrowser   { showFileBrowser   = v }
        if let v = values.fileBrowserWidth  { fileBrowserWidth  = v }
        if let v = values.showAIAssistant   { showAIAssistant   = v }
        if let v = values.aiAssistantWidth  { aiAssistantWidth  = v }
        fileBrowserWidth  = clampedFileBrowserWidth
        aiAssistantWidth  = clampedAIAssistantWidth
    }

    private func persistSidebarLayoutForSelection() {
        guard !isApplyingSidebarLayout, let session = selectedSession else { return }
        loadedSidebarLayoutContextKey = TerminalSidebarLayoutStore.contextKey(for: session)
        TerminalSidebarLayoutStore.persist(
            contextKey: loadedSidebarLayoutContextKey!,
            showFileBrowser: showFileBrowser, fileBrowserWidth: clampedFileBrowserWidth,
            showAIAssistant: showAIAssistant, aiAssistantWidth: clampedAIAssistantWidth
        )
    }

    private var terminalContentWithFileBrowser: some View {
        HStack(spacing: 0) {
            if showFileBrowser {
                TerminalFileBrowserSidebar(
                    session: selectedSession,
                    onClose: { showFileBrowser = false },
                    onSendShellInput: { sid, input in
                        Task { await sessionManager.sendShellInput(sessionID: sid, input: input) }
                    }
                )
                .frame(width: CGFloat(clampedFileBrowserWidth))
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let base = fileBrowserDragBaseWidth ?? clampedFileBrowserWidth
                                    fileBrowserDragBaseWidth = base
                                    fileBrowserWidth = min(460, max(220, base + Double(value.translation.width)))
                                }
                                .onEnded { _ in
                                    fileBrowserDragBaseWidth = nil
                                }
                        )
                }
                .transition(.move(edge: .leading))
            }
            macOSBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showAIAssistant {
                aiAssistantPane
                    .frame(width: CGFloat(clampedAIAssistantWidth))
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var aiAssistantPane: some View {
        TerminalAIAssistantPane(
            viewModel: terminalAIAssistantViewModel,
            session: selectedSession?.state == .connected ? selectedSession : nil,
            onClose: {
                terminalAIAssistantViewModel.clearConversation(sessionID: selectedSession?.id)
                showAIAssistant = false
            },
            onSend: { sessionID in
                terminalAIAssistantViewModel.submitPrompt(for: sessionID)
            },
            onComposerFocusChanged: { isFocused in
                isAIAssistantComposerFocused = isFocused
                if !isFocused {
                    directInputActivationNonce &+= 1
                }
            }
        )
        .frame(minWidth: CGFloat(aiAssistantMinWidth), idealWidth: CGFloat(clampedAIAssistantWidth), maxWidth: CGFloat(aiAssistantMaxWidth))
        .overlay(alignment: .leading) {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.26))
                    .frame(width: 4, height: 40)
            }
            .frame(width: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = aiAssistantDragBaseWidth ?? clampedAIAssistantWidth
                        aiAssistantDragBaseWidth = base
                        aiAssistantWidth = min(aiAssistantMaxWidth, max(aiAssistantMinWidth, base - Double(value.translation.width)))
                    }
                    .onEnded { _ in
                        aiAssistantDragBaseWidth = nil
                    }
            )
        }
    }

    private func sessionForPane(_ pane: TerminalPane) -> Session? {
        guard let sessionID = pane.sessionID else { return nil }
        return tabManager.tabs.first(where: { $0.id == sessionID })?.session
    }

    private func focusSessionAndPane(_ sessionID: UUID, paneID: UUID? = nil) {
        // If a text input (e.g. AI composer) holds first-responder status,
        // resign it at the AppKit level so the terminal can reclaim focus.
        if let window = NSApp.keyWindow,
           let responder = window.firstResponder,
           responder is NSTextView {
            window.makeFirstResponder(nil)
        }
        isAIAssistantComposerFocused = false
        directInputActivationNonce &+= 1
        focusedSessionID = sessionID
        if tabManager.selectedSessionID != sessionID {
            tabManager.select(sessionID: sessionID)
        }

        let targetPaneID = paneID
            ?? paneManager.allPanes.first(where: { $0.sessionID == sessionID })?.id
        if let targetPaneID, targetPaneID != paneManager.focusedPaneId {
            paneManager.focusPane(targetPaneID)
        }
    }

    private var noSessionPlaceholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No Session Assigned")
                .font(.headline)
            Text("Split a pane or assign a session from the context menu.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
    }

    @ViewBuilder
    private func directTerminalInputOverlay(for session: Session) -> some View {
        DirectTerminalInputCaptureView(
            isEnabled: shouldEnableDirectTerminalInput(for: session),
            sessionID: session.id,
            isLocalSession: session.isLocal,
            activationNonce: directInputActivationNonce,
            keyEncoderOptions: { hardwareKeyEncoderOptions() },
            onCommandShortcut: { action in
                handleHardwareCommandShortcut(action)
            },
            onSendSequence: { sessionID, sequence in
                handleDirectTerminalInput(sequence, sessionID: sessionID)
            },
            onSendBytes: { sessionID, bytes, eventType in
                Task {
                    await sessionManager.sendRawShellInputBytes(
                        sessionID: sessionID,
                        bytes: bytes,
                        source: .hardwareKeyCapture,
                        eventType: eventType
                    )
                }
            }
        )
    }

    private func shouldEnableDirectTerminalInput(for session: Session) -> Bool {
        guard session.state == .connected else { return false }
        if isSearchBarFocused { return false }
        if isAIAssistantComposerFocused { return false }
        if quickCommands.isDrawerPresented { return false }
        return tabManager.selectedSessionID == session.id
    }

    private func handleDirectTerminalInput(_ sequence: String, sessionID: UUID) {
        if !isMacOSTerminalSafetyModeEnabled {
            directInputBufferBySessionID[sessionID] = ""
            sendControl(sequence, sessionID: sessionID)
            return
        }

        let isSecure = sessionManager.sessions
            .first(where: { $0.id == sessionID })
            .map(shouldUseSecureInput(for:))
            ?? false

        if sequence == "\r" {
            let command = directInputBufferBySessionID[sessionID, default: ""]
            directInputBufferBySessionID[sessionID] = ""
            Task {
                await sessionManager.sendShellInput(
                    sessionID: sessionID,
                    input: command,
                    suppressEcho: isSecure
                )
            }
            return
        }

        if sequence == "\u{7F}" {
            var buffer = directInputBufferBySessionID[sessionID, default: ""]
            if !buffer.isEmpty {
                buffer.removeLast()
            }
            directInputBufferBySessionID[sessionID] = buffer
            return
        }

        if isDirectPrintableInput(sequence) {
            directInputBufferBySessionID[sessionID, default: ""] += sequence
            return
        }

        directInputBufferBySessionID[sessionID] = ""
        sendControl(sequence, sessionID: sessionID)
    }

    private func isDirectPrintableInput(_ sequence: String) -> Bool {
        guard sequence.count == 1,
              let scalar = sequence.unicodeScalars.first else {
            return false
        }
        return scalar.value >= 0x20 && scalar.value != 0x7F
    }

    private func binding(for sessionID: UUID) -> Binding<String> {
        Binding(
            get: { pendingInput[sessionID, default: ""] },
            set: { pendingInput[sessionID] = $0 }
        )
    }

    private var supportsMultitaskingControls: Bool {
        horizontalSizeClass == .regular
    }

    private var supportsSplitTerminal: Bool {
        true
    }

    private var isMetalRendererAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    private var isMacOSTerminalSafetyModeEnabled: Bool { false }

    private var newWindowToolbarPlacement: ToolbarItemPlacement {
        return .automatic
    }

    private var clampedAIAssistantWidth: Double {
        min(aiAssistantMaxWidth, max(aiAssistantMinWidth, aiAssistantWidth))
    }

    private var clampedFileBrowserWidth: Double {
        min(460, max(220, fileBrowserWidth))
    }

    private var aiAssistantMinWidth: Double { 280 }

    private var aiAssistantMaxWidth: Double { 920 }

    private func sendSelectedCommandShortcut() {
        guard let sessionID = selectedSession?.id else { return }
        let input = pendingInput[sessionID, default: ""]
        guard input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        sendCommand(for: sessionID)
    }

    private func clearSelectedBuffer() {
        guard let sessionID = selectedSession?.id else { return }
        sessionManager.clearShellBuffer(sessionID: sessionID)
    }

    private func stepSelectedSession(direction: Int) {
        tabManager.stepSelection(direction: direction)
    }

    private func switchSessionTab(oneBasedIndex: Int) {
        guard let tab = tabManager.tab(atOneBasedIndex: oneBasedIndex) else { return }
        tabManager.select(sessionID: tab.id)
    }

    private func syncPaneManagerSessions() {
        let activeIDs = Set(tabManager.tabs.map(\.id))
        paneManager.syncSessions(activeSessionIDs: activeIDs)

        // If the focused pane has no session and is not waiting for a new session, assign the selected session.
        if paneManager.focusedSessionID == nil,
           !pendingPaneSessionCreation.contains(paneManager.focusedPaneId),
           let selectedID = tabManager.selectedSessionID {
            paneManager.assignSession(selectedID, to: paneManager.focusedPaneId)
        }
    }

    private func createSessionForNewPane(duplicatingFrom sourceSessionID: UUID? = nil) {
        let sourceID = sourceSessionID ?? paneManager.focusedSessionID ?? tabManager.selectedSessionID
        guard let sourceID else { return }

        // Capture the target pane ID synchronously — focusedPaneId is the new pane
        // right after splitPane(), but may change by the time the async Task completes.
        let targetPaneID = paneManager.focusedPaneId

        // Mark this pane as pending so syncPaneManagerSessions doesn't
        // auto-assign the tab's session before duplicateSession completes.
        pendingPaneSessionCreation.insert(targetPaneID)

        Task {
            defer { pendingPaneSessionCreation.remove(targetPaneID) }
            do {
                if let newSession = try await sessionManager.duplicateSession(sourceID) {
                    tabManager.sync(with: sessionManager.sessions)
                    let sessionType: PaneSessionType
                    if newSession.isLocal {
                        sessionType = .local
                    } else if case let .ssh(hostID) = newSession.kind {
                        sessionType = .ssh(hostID: hostID, hostLabel: newSession.hostLabel)
                    } else {
                        sessionType = .local
                    }
                    paneManager.assignSession(newSession.id, to: targetPaneID, sessionType: sessionType)
                } else {
                    // duplicateSession returned nil — fall back to sharing the source session
                    paneManager.assignSession(sourceID, to: targetPaneID)
                }
            } catch {
                // Fallback: assign same session if duplication fails
                paneManager.assignSession(sourceID, to: targetPaneID)
            }
        }
    }

    /// Splits an existing pane and assigns an already-open session to the new pane.
    /// No new sessions are created — the existing tab is moved into the split layout.
    private func splitWithExistingSession(_ sessionID: UUID, beside paneID: UUID, direction: SplitDirection) {
        paneManager.splitPane(paneID, direction: direction)
        let newPaneID = paneManager.focusedPaneId
        let session = sessionManager.sessions.first(where: { $0.id == sessionID })
        let sessionType: PaneSessionType
        if let session, session.isLocal {
            sessionType = .local
        } else if let session, case let .ssh(hostID) = session.kind {
            sessionType = .ssh(hostID: hostID, hostLabel: session.hostLabel)
        } else {
            sessionType = .local
        }
        paneManager.assignSession(sessionID, to: newPaneID, sessionType: sessionType)
    }

    /// Keyboard shortcut helper: splits the focused pane with the next available
    /// tab session that isn't already displayed in a pane. Does nothing if there
    /// are no unassigned sessions to split with.
    private func splitNextAvailableSession(direction: SplitDirection) {
        let paneSessionIDs = Set(paneManager.allPanes.compactMap(\.sessionID))
        guard let nextSession = tabManager.tabs.first(where: { !paneSessionIDs.contains($0.id) }) else {
            return
        }
        splitWithExistingSession(nextSession.id, beside: paneManager.focusedPaneId, direction: direction)
    }

    private func moveToNewTab(paneID: UUID) {
        // Detach the pane's session from the split tree and select it in a standalone tab.
        if let sessionID = paneManager.rootNode.findPane(id: paneID)?.sessionID {
            paneManager.closePane(paneID)
            tabManager.select(sessionID: sessionID)
        }
    }

    private func disconnectOrCloseSelectedSession() {
        guard let session = selectedSession else { return }
        Task {
            if session.state == .connected {
                await sessionManager.disconnect(sessionID: session.id)
            } else {
                await sessionManager.closeSession(sessionID: session.id)
            }
        }
    }

    private func copyActiveContentToClipboard() {
        let targetSessionID = paneManager.focusedSessionID ?? focusedSessionID ?? tabManager.selectedSessionID
        if let sessionID = targetSessionID,
           copyContentToClipboard(sessionID: sessionID) {
            return
        }
        if let selectedText = selectionCoordinator.copySelection(preferredSessionID: targetSessionID) {
            _ = PlatformClipboard.writeString(selectedText)
            return
        }
    }

    @discardableResult
    private func copyContentToClipboard(sessionID: UUID) -> Bool {
        if let selectedText = selectionCoordinator.copySelection(sessionID: sessionID), !selectedText.isEmpty {
            _ = PlatformClipboard.writeString(selectedText)
            return true
        }
        let draft = pendingInput[sessionID, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty {
            _ = PlatformClipboard.writeString(draft)
            return true
        }

        if let lastLine = sessionManager.shellBuffers[sessionID]?.last,
           !lastLine.isEmpty {
            _ = PlatformClipboard.writeString(lastLine)
            return true
        }
        return false
    }

    private func pasteClipboardToSession(_ sessionID: UUID) {
        let bracketedPaste = inputModeSnapshot(for: sessionID).bracketedPasteMode
        let sequences = PasteHandler.readClipboardSequences(bracketedPasteEnabled: bracketedPaste)
        for sequence in sequences {
            sendControl(sequence, sessionID: sessionID)
        }
    }

    private func selectAllInFocusedTerminal() {
        let targetSessionID = paneManager.focusedSessionID ?? focusedSessionID ?? tabManager.selectedSessionID
        guard let sessionID = targetSessionID else { return }
        selectionCoordinator.selectAll(sessionID: sessionID)
    }

    private func inputModeSnapshot(for sessionID: UUID) -> InputModeSnapshot {
        sessionManager.inputModeSnapshotsBySessionID[sessionID] ?? .default
    }

    private func hardwareKeyEncoderOptions() -> KeyEncoderOptions {
        let targetSessionID = paneManager.focusedSessionID ?? focusedSessionID ?? tabManager.selectedSessionID
        guard let sessionID = targetSessionID else { return .default }
        let modeSnapshot = inputModeSnapshot(for: sessionID)
        return KeyEncoderOptions(
            applicationCursorKeys: modeSnapshot.applicationCursorKeys
        )
    }

    private func hardwareBracketedPasteEnabled() -> Bool {
        let targetSessionID = paneManager.focusedSessionID ?? focusedSessionID ?? tabManager.selectedSessionID
        guard let sessionID = targetSessionID else { return false }
        return inputModeSnapshot(for: sessionID).bracketedPasteMode
    }

    private func adjustTerminalFontSize(by delta: Double) {
        let minSize = 9.0
        let maxSize = 28.0
        terminalUIFontSize = min(maxSize, max(minSize, terminalUIFontSize + delta))
    }

    private func resetTerminalFontSize() {
        terminalUIFontSize = 12.0
    }

    private func handleHardwareCommandShortcut(_ action: HardwareKeyCommandAction) {
        switch action {
        case .copy:
            copyActiveContentToClipboard()
        case .paste:
            let targetSessionID = paneManager.focusedSessionID ?? focusedSessionID ?? tabManager.selectedSessionID
            if let sessionID = targetSessionID {
                pasteClipboardToSession(sessionID)
            }
        case .clearScrollback:
            clearSelectedBuffer()
        case .increaseFontSize:
            adjustTerminalFontSize(by: 1)
        case .decreaseFontSize:
            adjustTerminalFontSize(by: -1)
        case .resetFontSize:
            resetTerminalFontSize()
        default:
            break
        }
    }

    private func shouldUseSecureInput(for session: Session) -> Bool {
        if let override = secureInputOverride { return override }
        return detectsPasswordPrompt(for: session)
    }

    private var bellFeedbackMode: BellFeedbackMode {
        BellFeedbackMode(rawValue: bellFeedbackModeRawValue) ?? .none
    }

    private func detectsPasswordPrompt(for session: Session) -> Bool {
        let lines = sessionManager.shellBuffers[session.id] ?? []
        guard let lastLine = lines.last?.trimmingCharacters(in: .whitespaces).lowercased(),
              !lastLine.isEmpty else { return false }
        let patterns = ["password:", "password for", "passphrase:", "passphrase for", "enter pin"]
        return patterns.contains(where: { lastLine.contains($0) })
    }

    private func sendCommand(for sessionID: UUID) {
        let command = pendingInput[sessionID, default: ""]
        let wasSecure: Bool
        if let session = sessionManager.sessions.first(where: { $0.id == sessionID }) {
            wasSecure = shouldUseSecureInput(for: session)
        } else {
            wasSecure = false
        }
        pendingInput[sessionID] = ""
        secureInputOverride = nil
        Task {
            await sessionManager.sendShellInput(sessionID: sessionID, input: command, suppressEcho: wasSecure)
        }
    }

    private func sendControl(_ sequence: String) {
        let targetSessionID = paneManager.focusedSessionID ?? focusedSessionID ?? tabManager.selectedSessionID
        guard let sessionID = targetSessionID else { return }
        sendControl(sequence, sessionID: sessionID)
    }

    private func sendControl(_ sequence: String, sessionID: UUID) {
        Task {
            await sessionManager.sendRawShellInput(sessionID: sessionID, input: sequence)
        }
    }

    private func showSearchBar() {
        terminalSearch.present()
        updateSearchLines()
        searchFocusNonce &+= 1
    }

    private func hideSearchBar() {
        terminalSearch.dismiss()
    }

    private func updateSearchLines() {
        guard let selectedSessionID = tabManager.selectedSessionID else {
            terminalSearch.updateLines([])
            return
        }
        terminalSearch.updateLines(sessionManager.shellBuffers[selectedSessionID] ?? [])
    }

    private func synchronizeSelection() {
        let ids = Set(tabManager.tabs.map(\.id))

        if tabManager.selectedSessionID == nil, let first = tabManager.tabs.first?.id {
            tabManager.select(sessionID: first)
        }

        if let focusedSessionID, ids.contains(focusedSessionID) == false {
            self.focusedSessionID = nil
        }
    }

    private func requestCloseSession(_ session: Session) {
        if session.state == .connected {
            closeConfirmationSession = session
        } else {
            closeSession(session)
        }
    }

    private func closeSession(_ session: Session) {
        tabManager.removeTab(sessionID: session.id)
        Task {
            await sessionManager.closeSession(sessionID: session.id)
        }
    }

    private func openLocalTerminal() {
        Task {
            do {
                let session = try await sessionManager.openLocalSession()
                tabManager.sync(with: sessionManager.sessions)
                tabManager.select(sessionID: session.id)
            } catch {
                // Surface error via existing session state mechanism.
            }
        }
    }

    private func restartLocalSession(_ session: Session) {
        Task {
            do {
                let newSession = try await sessionManager.restartLocalSession(sessionID: session.id)
                tabManager.sync(with: sessionManager.sessions)
                tabManager.select(sessionID: newSession.id)
            } catch {
                // Surface error via existing session state mechanism.
            }
        }
    }
}
