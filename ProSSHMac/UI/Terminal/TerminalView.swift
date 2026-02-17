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
    @EnvironmentObject private var portForwardingManager: PortForwardingManager
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(BellEffectController.settingsKey) private var bellFeedbackModeRawValue = BellFeedbackMode.none.rawValue
    @AppStorage(TransparencyManager.backgroundOpacityKey) private var terminalBackgroundOpacityPercent = TransparencyManager.defaultBackgroundOpacityPercent
    @AppStorage("terminal.ui.fontSize") private var terminalUIFontSize = 12.0
    @AppStorage("terminal.renderer.useMetal") private var useMetalRenderer = true
    @AppStorage("terminal.renderer.migration.restoreMetal.v1") private var didRestoreMetalPreference = false
    @AppStorage("terminal.renderer.migration.defaultMetal.v2") private var didApplyMetalDefaultV2 = false
    @State private var pendingInput: [UUID: String] = [:]
    @StateObject private var bellEffect = BellEffectController()
    @StateObject private var scrollIndicator = ScrollIndicatorController()
    @StateObject private var resizeEffect = ResizeEffectController()
    @StateObject private var tabManager = SessionTabManager()
    @StateObject private var terminalSearch = TerminalSearch()
    @StateObject private var selectionCoordinator = TerminalSelectionCoordinator()
    @State private var paneManager = PaneManager()
    @State private var pendingPaneSessionCreation: Set<UUID> = []
    @StateObject private var quickCommands = QuickCommands()
    @FocusState private var focusedSessionID: UUID?
    @FocusState private var isSearchFieldFocused: Bool
    @State private var closeConfirmationSession: Session?
    @State private var secureInputOverride: Bool?
    @State private var isQuickCommandEditorPresented = false
    @State private var quickCommandEditingSnippetID: UUID?
    @State private var quickCommandDraftName = ""
    @State private var quickCommandDraftTemplate = ""
    @State private var quickCommandDraftHostScoped = false
    @State private var quickCommandDraftHostID: UUID?
    @State private var quickCommandDraftHostLabel: String?
    @State private var quickCommandDraftVariableDefaults: [String: String] = [:]
    @State private var quickCommandPendingSnippet: QuickCommandSnippet?
    @State private var quickCommandPendingValues: [String: String] = [:]
    @State private var isQuickCommandImportPresented = false
    @State private var quickCommandStatusLine: String?
    @State private var terminalContentHeight: CGFloat = 0
    @State private var terminalContentOffset: CGFloat = 0
    @State private var terminalViewportSize: CGSize = .zero
    @State private var directInputBufferBySessionID: [UUID: String] = [:]
    private let linkDetector = LinkDetector()

    var body: some View {
        ZStack {
            macOSBody

            terminalShortcutLayer
                .frame(width: 0, height: 0)
                .opacity(0.001)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay {
            if quickCommands.isDrawerPresented {
                quickCommandScrim
            }
        }
        .overlay(alignment: .trailing) {
            quickCommandDrawerLayer
        }
        .animation(.easeInOut(duration: 0.2), value: quickCommands.isDrawerPresented)
        .navigationTitle("Terminal")
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
        }
        .onChange(of: sessionManager.sessions.map(\.id)) { _, _ in
            Task { @MainActor in
                tabManager.sync(with: sessionManager.sessions)
                synchronizeSelection()
                updateSearchLines()
                syncPaneManagerSessions()
            }
        }
        .onChange(of: tabManager.selectedSessionID) { _, _ in
            scrollIndicator.reset()
            resizeEffect.reset()
            updateSearchLines()
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
            scrollIndicator.reset()
            resizeEffect.reset()
        }
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
                        openWindow(id: ProSSHMacApp.externalTerminalWindowID)
                    } label: {
                        Label("New Window", systemImage: "rectangle.on.rectangle")
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
        .sheet(isPresented: $isQuickCommandEditorPresented) {
            quickCommandEditorSheet
        }
        .sheet(item: $quickCommandPendingSnippet) { snippet in
            quickCommandVariableSheet(for: snippet)
        }
        .fileImporter(
            isPresented: $isQuickCommandImportPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleQuickCommandImport(result: result)
        }
    }

    private var macOSBody: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                sessionTabs
                    .padding(.vertical, 8)

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
                        sessionPanel(for: session, includeSearch: paneFocused, isFocused: paneFocused)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    } else {
                        noSessionPlaceholder
                    }
                }
            } else {
                sessionTabs
                    .padding(.vertical, 8)

                if let session = selectedSession {
                    sessionPanel(for: session, includeSearch: true)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionPanel(for session: Session, includeSearch: Bool, isFocused: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(for: session)

            sessionMetadata(for: session)

            if includeSearch, terminalSearch.isPresented {
                searchBar
            }

            if session.state == .connected {
                terminalSurface(for: session, isFocused: isFocused)
                    .overlay {
                        directTerminalInputOverlay(for: session)
                    }
            }

            terminalActions(for: session)
        }
    }

    @ViewBuilder
    private func sessionMetadata(for session: Session) -> some View {
        if session.isLocal {
            let cwd = sessionManager.workingDirectoryBySessionID[session.id] ?? "~"
            let displayCwd = cwd.replacingOccurrences(
                of: ProcessInfo.processInfo.environment["HOME"] ?? "/nonexistent",
                with: "~"
            )
            Text("Shell: \(session.shellPath ?? "/bin/zsh")  |  CWD: \(displayCwd)  |  TERM: xterm-256color")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            if let kex = session.negotiatedKEX,
               let cipher = session.negotiatedCipher,
               let hostKey = session.negotiatedHostKeyType {
                let fingerprint = session.negotiatedHostFingerprint ?? "unknown"
                Text("KEX: \(kex)  |  Cipher: \(cipher)  |  Host Key: \(hostKey)  |  FP: \(fingerprint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let advisory = session.securityAdvisory {
                Label(advisory, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            let forwards = portForwardingManager.activeForwards.filter { $0.sessionID == session.id }
            if !forwards.isEmpty {
                let listeningCount = forwards.filter { $0.state == .listening }.count
                Label("\(listeningCount)/\(forwards.count) forwards active", systemImage: "arrow.right.arrow.left")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }

        if session.state == .connected {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                let duration = Date.now.timeIntervalSince(session.startedAt)
                let hours = Int(duration) / 3600
                let minutes = (Int(duration) % 3600) / 60
                Text("Duration: \(hours > 0 ? "\(hours)h " : "")\(minutes)m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if session.state == .connected, !session.isLocal {
            let lastActivity = sessionManager.lastActivityBySessionID[session.id]
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let idleSeconds = lastActivity.map { Date.now.timeIntervalSince($0) } ?? 0
                if idleSeconds > 600 {
                    let idleMinutes = Int(idleSeconds) / 60
                    Label("Idle for \(idleMinutes)m — session may time out", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }

        if let errorMessage = session.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var selectedSession: Session? {
        if let selectedSessionID = tabManager.selectedSessionID {
            return tabManager.tabs.first(where: { $0.id == selectedSessionID })?.session
        }
        return tabManager.tabs.first?.session
    }

    private var sessionTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabManager.tabs) { tab in
                        let session = tab.session
                        HStack(spacing: 6) {
                            Button {
                                tabManager.select(sessionID: session.id)
                            } label: {
                                HStack(spacing: 6) {
                                    if tab.isPinned {
                                        Image(systemName: "pin.fill")
                                            .foregroundStyle(.orange)
                                            .font(.caption2)
                                    }
                                    Circle()
                                        .fill(tab.statusColor)
                                        .frame(width: 7, height: 7)
                                    if session.usesLegacyCrypto {
                                        Image(systemName: "shield.lefthalf.filled")
                                            .foregroundStyle(.orange)
                                            .font(.caption2)
                                    }
                                    if session.usesAgentForwarding {
                                        Image(systemName: "arrow.triangle.branch")
                                            .foregroundStyle(.teal)
                                            .font(.caption2)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(sessionManager.windowTitleBySessionID[session.id] ?? tab.label)
                                            .font(.caption)
                                            .lineLimit(1)
                                        if session.isLocal, let cwd = sessionManager.workingDirectoryBySessionID[session.id] {
                                            let homePath = ProcessInfo.processInfo.environment["HOME"] ?? ""
                                            let displayCwd = cwd.replacingOccurrences(of: homePath, with: "~")
                                            Text(displayCwd)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    tabBackground(for: session),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                            .id(session.id)
                            .draggable(session.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let sourceIDString = items.first,
                                      let sourceID = UUID(uuidString: sourceIDString) else { return false }
                                tabManager.moveTab(from: sourceID, before: session.id)
                                return true
                            }
                            .contextMenu {
                                Button("Move Left") {
                                    tabManager.moveTab(sessionID: session.id, by: -1)
                                }
                                .disabled(!tabManager.canMoveTab(sessionID: session.id, direction: -1))

                                Button("Move Right") {
                                    tabManager.moveTab(sessionID: session.id, by: 1)
                                }
                                .disabled(!tabManager.canMoveTab(sessionID: session.id, direction: 1))

                                Divider()

                                Button {
                                    Task {
                                        try? await sessionManager.duplicateSession(session.id)
                                    }
                                } label: {
                                    Label("Duplicate", systemImage: "doc.on.doc")
                                }

                                Button {
                                    tabManager.togglePin(sessionID: session.id)
                                } label: {
                                    Label(tab.isPinned ? "Unpin" : "Pin", systemImage: tab.isPinned ? "pin.slash" : "pin")
                                }

                                if paneManager.canSplit(paneManager.focusedPaneId),
                                   session.id != paneManager.focusedSessionID {
                                    Divider()

                                    Button {
                                        splitWithExistingSession(session.id, beside: paneManager.focusedPaneId, direction: .vertical)
                                    } label: {
                                        Label("Split Right", systemImage: "rectangle.split.2x1")
                                    }

                                    Button {
                                        splitWithExistingSession(session.id, beside: paneManager.focusedPaneId, direction: .horizontal)
                                    } label: {
                                        Label("Split Down", systemImage: "rectangle.split.1x2")
                                    }
                                }
                            }

                            if !tab.isPinned {
                                Button(role: .destructive) {
                                    requestCloseSession(session)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                Menu {
                    Button {
                        navigationCoordinator.navigate(to: .hosts)
                    } label: {
                        Label("New SSH Session", systemImage: "network")
                    }

                    Button {
                        openLocalTerminal()
                    } label: {
                        Label("New Local Terminal", systemImage: "terminal.fill")
                    }
                } label: {
                    Label("New Tab", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            (colorScheme == .dark ? Color.white.opacity(0.1) : Color.secondary.opacity(0.12)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: tabManager.selectedSessionID) { _, newID in
                if let newID {
                    withAnimation {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    private var splitPaneBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sessionManager.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Active Sessions")
                        .font(.headline)
                    Text("Connect to a host from the Hosts tab to start an SSH session.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                Spacer(minLength: 0)
            } else {
                sessionTabs

                SplitNodeView(
                    node: paneManager.displayNode,
                    paneManager: paneManager,
                    onNewSSHSession: { _ in navigationCoordinator.navigate(to: .hosts) },
                    onNewLocalTerminal: nil,
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
                        sessionPanel(for: session, includeSearch: paneFocused, isFocused: paneFocused)
                    } else {
                        noSessionPlaceholder
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func sessionForPane(_ pane: TerminalPane) -> Session? {
        guard let sessionID = pane.sessionID else { return nil }
        return tabManager.tabs.first(where: { $0.id == sessionID })?.session
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

    private var quickCommandScrim: some View {
        Color.black.opacity(0.2)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                quickCommands.dismissDrawer()
            }
    }

    private var quickCommandDrawerLayer: some View {
        GeometryReader { geometry in
            let drawerWidth = min(380, max(280, geometry.size.width * 0.72))

            ZStack(alignment: .trailing) {
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onEnded { value in
                                guard !quickCommands.isDrawerPresented else { return }
                                guard value.translation.width < -35 else { return }
                                quickCommands.presentDrawer()
                            }
                    )

                if quickCommands.isDrawerPresented {
                    quickCommandDrawer(width: drawerWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    private func quickCommandDrawer(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            quickCommandDrawerHeader
            quickCommandDrawerTarget

            if let quickCommandStatusLine {
                Text(quickCommandStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            quickCommandDrawerBody
        }
        .padding(12)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    if value.translation.width > 35 {
                        quickCommands.dismissDrawer()
                    }
                }
        )
    }

    private var quickCommandDrawerHeader: some View {
        HStack(spacing: 8) {
            Label("Quick Commands", systemImage: "terminal")
                .font(.headline)

            Spacer()

            Menu {
                Button("Import JSON") {
                    isQuickCommandImportPresented = true
                }
                Button("Export JSON") {
                    exportQuickCommandLibrary()
                }
            } label: {
                Image(systemName: "square.and.arrow.up.on.square")
            }
            .buttonStyle(.borderless)

            Button {
                presentQuickCommandEditor(for: nil)
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)

            Button {
                quickCommands.dismissDrawer()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }

    private var quickCommandDrawerTarget: some View {
        Group {
            if let session = selectedSession {
                Text("Target: \(session.hostLabel)")
            } else {
                Text("Select an active session to run commands.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var quickCommandDrawerBody: some View {
        if quickCommandVisibleSnippets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No Quick Commands")
                    .font(.headline)
                Text("Add snippets for repetitive commands. Use {{variable}} placeholders for prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(quickCommandVisibleSnippets) { snippet in
                        quickCommandSnippetRow(snippet)
                    }
                }
            }
        }
    }

    private func quickCommandSnippetRow(_ snippet: QuickCommandSnippet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    runQuickCommandSnippet(snippet)
                } label: {
                    Text(snippet.name)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    presentQuickCommandEditor(for: snippet)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    quickCommands.removeSnippet(id: snippet.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            Text(snippet.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(snippet.isGlobal ? "Global" : (snippet.hostLabel ?? "Host"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.16), in: Capsule())

                if !snippet.variables.isEmpty {
                    Text("Vars: \(snippet.variables.map(\.name).joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
        )
    }

    private var quickCommandVisibleSnippets: [QuickCommandSnippet] {
        quickCommands.snippets(for: selectedSession?.hostID)
    }

    private var quickCommandEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Snippet") {
                    TextField("Name", text: $quickCommandDraftName)
                    TextField("Command Template", text: $quickCommandDraftTemplate, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("Scope") {
                    Toggle("Host-specific", isOn: $quickCommandDraftHostScoped)
                        .onChange(of: quickCommandDraftHostScoped) { _, isOn in
                            guard isOn else { return }
                            if quickCommandDraftHostID == nil, let session = selectedSession {
                                quickCommandDraftHostID = session.hostID
                                quickCommandDraftHostLabel = session.hostLabel
                            }
                        }

                    Text(
                        quickCommandDraftHostScoped
                        ? "Host: \(quickCommandDraftHostLabel ?? "No host selected")"
                        : "Global (all hosts)"
                    )
                    .font(.caption)
                    .foregroundStyle(quickCommandDraftHostScoped && quickCommandDraftHostID == nil ? .red : .secondary)
                }

                if !quickCommandDraftVariableNames.isEmpty {
                    Section("Variable Defaults") {
                        ForEach(quickCommandDraftVariableNames, id: \.self) { variableName in
                            TextField(
                                variableName,
                                text: quickCommandDraftDefaultBinding(for: variableName)
                            )
                            .terminalInputBehavior()
                        }
                    }
                }
            }
            .navigationTitle(quickCommandEditingSnippetID == nil ? "New Quick Command" : "Edit Quick Command")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isQuickCommandEditorPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveQuickCommandFromDraft()
                    }
                    .disabled(!quickCommandDraftCanSave)
                }
            }
        }
    }

    private func quickCommandVariableSheet(for snippet: QuickCommandSnippet) -> some View {
        NavigationStack {
            Form {
                ForEach(snippet.variables) { variable in
                    TextField(
                        variable.name,
                        text: Binding(
                            get: { quickCommandPendingValues[variable.name, default: variable.defaultValue] },
                            set: { quickCommandPendingValues[variable.name] = $0 }
                        )
                    )
                    .terminalInputBehavior()
                }
            }
            .navigationTitle(snippet.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        quickCommandPendingSnippet = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sendQuickCommand(snippet: snippet, values: quickCommandPendingValues)
                        quickCommandPendingSnippet = nil
                    }
                }
            }
        }
    }

    private var quickCommandDraftVariableNames: [String] {
        quickCommands.placeholderVariables(in: quickCommandDraftTemplate)
    }

    private var quickCommandDraftCanSave: Bool {
        let hasName = !quickCommandDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCommand = !quickCommandDraftTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasScope = !quickCommandDraftHostScoped || quickCommandDraftHostID != nil
        return hasName && hasCommand && hasScope
    }

    private func quickCommandDraftDefaultBinding(for variableName: String) -> Binding<String> {
        Binding(
            get: { quickCommandDraftVariableDefaults[variableName, default: ""] },
            set: { quickCommandDraftVariableDefaults[variableName] = $0 }
        )
    }

    private func presentQuickCommandEditor(for snippet: QuickCommandSnippet?) {
        if let snippet {
            quickCommandEditingSnippetID = snippet.id
            quickCommandDraftName = snippet.name
            quickCommandDraftTemplate = snippet.command
            quickCommandDraftHostScoped = !snippet.isGlobal
            quickCommandDraftHostID = snippet.hostID
            quickCommandDraftHostLabel = snippet.hostLabel
            quickCommandDraftVariableDefaults = Dictionary(
                uniqueKeysWithValues: snippet.variables.map { ($0.name, $0.defaultValue) }
            )
        } else {
            quickCommandEditingSnippetID = nil
            quickCommandDraftName = ""
            quickCommandDraftTemplate = ""
            quickCommandDraftHostScoped = false
            quickCommandDraftHostID = selectedSession?.hostID
            quickCommandDraftHostLabel = selectedSession?.hostLabel
            quickCommandDraftVariableDefaults = [:]
        }

        isQuickCommandEditorPresented = true
    }

    private func saveQuickCommandFromDraft() {
        var hostID: UUID?
        var hostLabel: String?

        if quickCommandDraftHostScoped {
            if quickCommandDraftHostID == nil, let session = selectedSession {
                quickCommandDraftHostID = session.hostID
                quickCommandDraftHostLabel = session.hostLabel
            }

            hostID = quickCommandDraftHostID
            hostLabel = quickCommandDraftHostLabel
        }

        do {
            _ = try quickCommands.saveSnippet(
                id: quickCommandEditingSnippetID,
                name: quickCommandDraftName,
                command: quickCommandDraftTemplate,
                variableDefaults: quickCommandDraftVariableDefaults,
                hostID: hostID,
                hostLabel: hostLabel
            )
            quickCommandStatusLine = quickCommandEditingSnippetID == nil
                ? "Quick command saved."
                : "Quick command updated."
            isQuickCommandEditorPresented = false
        } catch {
            quickCommandStatusLine = error.localizedDescription
        }
    }

    private func runQuickCommandSnippet(_ snippet: QuickCommandSnippet) {
        guard let session = selectedSession else {
            quickCommandStatusLine = "Select a connected session first."
            return
        }

        guard snippet.applies(toHostID: session.hostID) else {
            quickCommandStatusLine = "This quick command does not apply to the selected host."
            return
        }

        if snippet.variables.isEmpty {
            sendQuickCommand(snippet: snippet, values: [:])
        } else {
            quickCommandPendingValues = Dictionary(
                uniqueKeysWithValues: snippet.variables.map { ($0.name, $0.defaultValue) }
            )
            quickCommandPendingSnippet = snippet
        }
    }

    private func sendQuickCommand(snippet: QuickCommandSnippet, values: [String: String]) {
        guard let session = selectedSession else {
            quickCommandStatusLine = "Select a connected session first."
            return
        }

        let resolved = quickCommands.resolvedCommand(for: snippet, values: values)
        quickCommandStatusLine = "Sent '\(snippet.name)' to \(session.hostLabel)."

        Task {
            await sessionManager.sendShellInput(sessionID: session.id, input: resolved)
        }
    }

    private func exportQuickCommandLibrary() {
        do {
            let url = try quickCommands.exportLibrary()
            quickCommandStatusLine = "Exported quick commands to \(url.lastPathComponent)."
        } catch {
            quickCommandStatusLine = "Export failed: \(error.localizedDescription)"
        }
    }

    private func handleQuickCommandImport(result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try quickCommands.importLibrary(from: url, strategy: .merge)
                quickCommandStatusLine = "Imported quick commands from \(url.lastPathComponent)."
            } catch {
                quickCommandStatusLine = "Import failed: \(error.localizedDescription)"
            }
        case let .failure(error):
            quickCommandStatusLine = "Import failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func header(for session: Session) -> some View {
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

                        if session.usesLegacyCrypto {
                            Label("Legacy", systemImage: "shield.lefthalf.filled")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

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

    @ViewBuilder
    private func terminalSurface(for session: Session, isFocused: Bool = true) -> some View {
        if isMacOSTerminalSafetyModeEnabled {
            safeTerminalBuffer(for: session)
        } else if supportsMetalTerminalSurface {
            metalTerminalBuffer(for: session, isFocused: isFocused)
        } else {
            terminalBuffer(for: session)
        }
    }

    @ViewBuilder
    private func safeTerminalBuffer(for session: Session) -> some View {
        let renderedLines = safeTerminalDisplayLines(for: session)
        let scrollSpaceName = "terminal-scroll-safe-\(session.id.uuidString)"

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(renderedLines) { line in
                        Text(verbatim: line.text)
                            .font(.system(size: terminalUIFontSize, weight: .regular, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .coordinateSpace(name: scrollSpaceName)
            .onAppear {
                guard let last = renderedLines.indices.last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .onChange(of: renderedLines.count) { _, _ in
                guard let last = renderedLines.indices.last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
        .frame(minHeight: 220, maxHeight: .infinity)
        .background(terminalSurfaceColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(terminalSurfaceBorderColor, lineWidth: 1)
        )
    }

    private func safeTerminalDisplayLines(for session: Session) -> [SafeTerminalRenderedLine] {
        var lines = sessionManager.shellBuffers[session.id] ?? []
        let directInput = directInputBufferBySessionID[session.id, default: ""]
        let shouldUseSafetyOverlay = isMacOSTerminalSafetyModeEnabled
        let shouldEchoInput = !shouldUseSecureInput(for: session)
        let shouldShowCursor = shouldEnableDirectTerminalInput(for: session)

        if shouldUseSafetyOverlay && (shouldShowCursor || (shouldEchoInput && !directInput.isEmpty)) {
            let suffix = (shouldEchoInput ? directInput : "") + (shouldShowCursor ? "█" : "")
            if lines.isEmpty {
                lines = [suffix]
            } else {
                lines[lines.count - 1] += suffix
            }
        }

        return lines.enumerated().map { index, line in
            SafeTerminalRenderedLine(id: index, text: line)
        }
    }

    @ViewBuilder
    private func metalTerminalBuffer(for session: Session, isFocused: Bool = true) -> some View {
        let snapshot = sessionManager.gridSnapshotsBySessionID[session.id]
        let snapshotNonce = sessionManager.gridSnapshotNonceBySessionID[session.id, default: 0]

        MetalTerminalSessionSurface(
            sessionID: session.id,
            snapshot: snapshot,
            snapshotNonce: snapshotNonce,
            backgroundOpacityPercent: terminalBackgroundOpacityPercent,
            onTap: { _ in
                focusedSessionID = session.id
            },
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
            isFocused: isFocused,
            isLocalSession: session.isLocal,
            selectionCoordinator: selectionCoordinator
        )
        .id(session.id)
        .frame(minHeight: 220, maxHeight: .infinity)
        .scaleEffect(resizeEffect.contentScale)
        .opacity(resizeEffect.contentOpacity)
        .background(terminalSurfaceColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(terminalSurfaceBorderColor, lineWidth: 1)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(bellEffect.flashOpacity))
                .allowsHitTesting(false)
        }
        .overlay {
            mouseInputOverlay(for: session, contentPadding: 0)
        }
        .contextMenu {
            terminalSurfaceContextMenu(for: session)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let escapedPath = url.path.replacingOccurrences(of: " ", with: "\\ ")
                    Task { @MainActor in
                        await sessionManager.sendShellInput(sessionID: session.id, input: escapedPath)
                    }
                }
            }
            return true
        }
        .onChange(of: sessionManager.bellEventNonceBySessionID[session.id, default: 0]) { _, _ in
            bellEffect.trigger(mode: bellFeedbackMode)
        }
    }

    @ViewBuilder
    private func terminalSurfaceContextMenu(for session: Session) -> some View {
        Button {
            copyActiveContentToClipboard()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(!selectionCoordinator.hasSelection(sessionID: session.id))

        Button {
            pasteClipboardToSession(session.id)
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }

        Divider()

        Button {
            selectionCoordinator.selectAll(sessionID: session.id)
        } label: {
            Label("Select All", systemImage: "selection.pin.in.out")
        }

        if selectionCoordinator.hasSelection(sessionID: session.id) {
            Button {
                selectionCoordinator.clearSelection(sessionID: session.id)
            } label: {
                Label("Clear Selection", systemImage: "xmark.rectangle")
            }
        }

        let currentPaneID = paneManager.allPanes.first(where: { $0.sessionID == session.id })?.id
            ?? paneManager.focusedPaneId
        let otherSessions = tabManager.tabs
            .map(\.session)
            .filter { $0.id != session.id }

        if paneManager.canSplit(currentPaneID) && !otherSessions.isEmpty {
            Divider()

            Menu {
                ForEach(otherSessions, id: \.id) { other in
                    Button(other.hostLabel) {
                        splitWithExistingSession(other.id, beside: currentPaneID, direction: .vertical)
                    }
                }
            } label: {
                Label("Split Right With...", systemImage: "rectangle.split.2x1")
            }

            Menu {
                ForEach(otherSessions, id: \.id) { other in
                    Button(other.hostLabel) {
                        splitWithExistingSession(other.id, beside: currentPaneID, direction: .horizontal)
                    }
                }
            } label: {
                Label("Split Down With...", systemImage: "rectangle.split.1x2")
            }
        }
    }

    @ViewBuilder
    private func terminalBuffer(for session: Session) -> some View {
        let lines = sessionManager.shellBuffers[session.id] ?? []
        let scrollSpaceName = "terminal-scroll-\(session.id.uuidString)"

        ScrollViewReader { proxy in
            GeometryReader { viewportProxy in
                ScrollView {
                    GeometryReader { offsetProxy in
                        Color.clear.preference(
                            key: TerminalScrollOffsetPreferenceKey.self,
                            value: -offsetProxy.frame(in: .named(scrollSpaceName)).minY
                        )
                    }
                    .frame(height: 0)

                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            terminalLineView(line, lineIndex: index)
                                .id(index)
                        }
                    }
                    .padding(8)
                    .background(
                        GeometryReader { contentProxy in
                            Color.clear.preference(
                                key: TerminalScrollContentHeightPreferenceKey.self,
                                value: contentProxy.size.height
                            )
                        }
                    )
                }
                .coordinateSpace(name: scrollSpaceName)
                .onAppear {
                    terminalViewportSize = viewportProxy.size
                    terminalSearch.updateLines(lines)
                    scrollIndicator.update(
                        contentOffset: terminalContentOffset,
                        contentHeight: terminalContentHeight,
                        viewportHeight: terminalViewportSize.height
                    )
                    guard lines.count > 0 else { return }
                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
                }
                .onChange(of: viewportProxy.size) { oldSize, newSize in
                    terminalViewportSize = newSize
                    resizeEffect.handleViewportChange(from: oldSize, to: newSize)
                    scrollIndicator.update(
                        contentOffset: terminalContentOffset,
                        contentHeight: terminalContentHeight,
                        viewportHeight: terminalViewportSize.height
                    )
                }
                .onPreferenceChange(TerminalScrollOffsetPreferenceKey.self) { offset in
                    terminalContentOffset = max(0, offset)
                    scrollIndicator.update(
                        contentOffset: terminalContentOffset,
                        contentHeight: terminalContentHeight,
                        viewportHeight: terminalViewportSize.height
                    )
                }
                .onPreferenceChange(TerminalScrollContentHeightPreferenceKey.self) { contentHeight in
                    terminalContentHeight = contentHeight
                    scrollIndicator.update(
                        contentOffset: terminalContentOffset,
                        contentHeight: terminalContentHeight,
                        viewportHeight: terminalViewportSize.height
                    )
                }
                .onChange(of: lines) { _, newLines in
                    terminalSearch.updateLines(newLines)
                    guard !newLines.isEmpty else { return }
                    guard scrollIndicator.isNearBottom else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newLines.count - 1, anchor: .bottom)
                    }
                }
                .onChange(of: terminalSearch.selectedMatch) { _, selectedMatch in
                    guard let selectedMatch, selectedMatch.lineIndex < lines.count else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(selectedMatch.lineIndex, anchor: .center)
                    }
                }
                .overlay(alignment: .trailing) {
                    if scrollIndicator.shouldShowThumb {
                        GeometryReader { indicatorProxy in
                            let trackHeight = indicatorProxy.size.height
                            let thumbHeight = max(18, trackHeight * scrollIndicator.thumbFraction)
                            let travel = max(0, trackHeight - thumbHeight)
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.58 : 0.42))
                                .frame(width: 3, height: thumbHeight)
                                .offset(y: travel * scrollIndicator.thumbOffsetFraction)
                                .padding(.trailing, 4)
                                .opacity(scrollIndicator.thumbOpacity)
                                .animation(.easeOut(duration: 0.16), value: scrollIndicator.thumbOpacity)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if scrollIndicator.showJumpToBottom, !lines.isEmpty {
                        VStack(spacing: 6) {
                            if !scrollIndicator.isNearBottom {
                                Text("\u{2193} New output below")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }

                            Button {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
                                }
                            } label: {
                                Label("Jump to Bottom", systemImage: "arrow.down.to.line")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: .infinity)
            .scaleEffect(resizeEffect.contentScale)
            .opacity(resizeEffect.contentOpacity)
            .background(terminalSurfaceColor, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(terminalSurfaceBorderColor, lineWidth: 1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(bellEffect.flashOpacity))
                    .allowsHitTesting(false)
            }
            .overlay {
                mouseInputOverlay(for: session)
            }
            .onChange(of: sessionManager.bellEventNonceBySessionID[session.id, default: 0]) { _, _ in
                bellEffect.trigger(mode: bellFeedbackMode)
            }
        }
    }

    @ViewBuilder
    private func terminalLineView(_ line: String, lineIndex: Int) -> some View {
        let detectedLinks = linkDetector.detectLinks(in: line)
        let attributed = attributedTerminalLine(line, lineIndex: lineIndex)

        let base = Text(attributed)
            .font(.system(size: terminalUIFontSize, weight: .regular, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    PlatformURL.openInBrowser(url)
                    return .handled
                }
            )

        if detectedLinks.isEmpty {
            base
        } else {
            base
                .help(detectedLinks.map(\.previewLabel).joined(separator: "\n"))
                .contextMenu {
                    Text(detectedLinks.first?.previewLabel ?? "Detected Link")
                    Divider()
                    ForEach(detectedLinks) { link in
                        Button("Open \(link.text) in Browser") {
                            PlatformURL.openInBrowser(link.destinationURL)
                        }
                    }
                    Divider()
                    ForEach(detectedLinks) { link in
                        Button("Copy \(link.text)") {
                            PlatformClipboard.writeString(link.text)
                        }
                    }
                }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Find", systemImage: "magnifyingglass")
                    .font(.caption.weight(.semibold))

                TextField("Find in terminal output", text: searchQueryBinding)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        terminalSearch.selectNextMatch()
                    }

                Button {
                    hideSearchBar()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Toggle("Regex", isOn: searchRegexBinding)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Toggle("Case", isOn: searchCaseSensitiveBinding)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Spacer()

                Text(terminalSearch.resultSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    terminalSearch.selectPreviousMatch()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(terminalSearch.matches.isEmpty)

                Button {
                    terminalSearch.selectNextMatch()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(terminalSearch.matches.isEmpty)
            }

            if let validationError = terminalSearch.validationError {
                Text("Regex error: \(validationError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(terminalSurfaceColor, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(terminalSurfaceBorderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func directTerminalInputOverlay(for session: Session) -> some View {
        DirectTerminalInputCaptureView(
            isEnabled: shouldEnableDirectTerminalInput(for: session),
            sessionID: session.id,
            keyEncoderOptions: { hardwareKeyEncoderOptions() },
            onSendSequence: { sessionID, sequence in
                handleDirectTerminalInput(sequence, sessionID: sessionID)
            }
        )
    }

    private func shouldEnableDirectTerminalInput(for session: Session) -> Bool {
        guard session.state == .connected else { return false }
        if isSearchFieldFocused { return false }
        if isQuickCommandEditorPresented { return false }
        if quickCommandPendingSnippet != nil { return false }
        if isQuickCommandImportPresented { return false }
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

    @ViewBuilder
    private func terminalActions(for session: Session) -> some View {
        let isRecording = sessionManager.isRecordingBySessionID[session.id, default: false]
        let hasRecording = sessionManager.hasRecordingBySessionID[session.id, default: false]
        let isPlaybackRunning = sessionManager.isPlaybackRunningBySessionID[session.id, default: false]

        HStack {
            if session.state == .connected {
                Button("Clear") {
                    sessionManager.clearShellBuffer(sessionID: session.id)
                }
                .buttonStyle(.bordered)

                Button(isRecording ? "Stop Rec" : "Record") {
                    Task {
                        await sessionManager.toggleRecording(sessionID: session.id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .accentColor)
            }

            Menu {
                Button("Play 1x") {
                    Task {
                        await sessionManager.playLastRecording(sessionID: session.id, speed: 1.0)
                    }
                }
                Button("Play 2x") {
                    Task {
                        await sessionManager.playLastRecording(sessionID: session.id, speed: 2.0)
                    }
                }
                Button("Play 4x") {
                    Task {
                        await sessionManager.playLastRecording(sessionID: session.id, speed: 4.0)
                    }
                }
                Divider()
                Button("Export .cast") {
                    Task {
                        await sessionManager.exportLastRecordingAsCast(sessionID: session.id)
                    }
                }
            } label: {
                Label(isPlaybackRunning ? "Playing" : "Playback", systemImage: "play.circle")
            }
            .disabled(!hasRecording || isRecording || isPlaybackRunning)

            Menu {
                Button(useMetalRenderer ? "Switch to Classic" : "Switch to Metal") {
                    useMetalRenderer.toggle()
                }
                .disabled(!isMetalRendererToggleEnabled)

                if !isMetalRendererAvailable {
                    Text("Metal unavailable on this device")
                }
            } label: {
                Label("Display", systemImage: useMetalRenderer ? "display.2" : "display")
            }

            Spacer()

            if session.state == .connected {
                Button("Disconnect", role: .destructive) {
                    Task {
                        await sessionManager.disconnect(sessionID: session.id)
                    }
                }
                .buttonStyle(.bordered)
            } else {
                if session.isLocal {
                    Button {
                        restartLocalSession(session)
                    } label: {
                        Label("Restart Shell", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Button("Close", role: .destructive) {
                    Task {
                        await sessionManager.closeSession(sessionID: session.id)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func binding(for sessionID: UUID) -> Binding<String> {
        Binding(
            get: { pendingInput[sessionID, default: ""] },
            set: { pendingInput[sessionID] = $0 }
        )
    }

    private func stateColor(for state: SessionState) -> Color {
        switch state {
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private func tabBackground(for session: Session) -> Color {
        if tabManager.selectedSessionID == session.id {
            return colorScheme == .dark ? Color.accentColor.opacity(0.34) : Color.accentColor.opacity(0.2)
        }
        return colorScheme == .dark ? Color.white.opacity(0.1) : Color.secondary.opacity(0.12)
    }

    private var terminalSurfaceColor: Color {
        let opacityMultiplier = TransparencyManager.normalizedOpacity(fromPercent: terminalBackgroundOpacityPercent)
        let baseOpacity = colorScheme == .dark ? 0.34 : 0.08
        return Color.black.opacity(baseOpacity * opacityMultiplier)
    }

    private var terminalSurfaceBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private var supportsMultitaskingControls: Bool {
        horizontalSizeClass == .regular
    }

    private var supportsSplitTerminal: Bool {
        true
    }

    private var supportsMetalTerminalSurface: Bool {
        useMetalRenderer && isMetalRendererAvailable
    }

    private var isMacOSTerminalSafetyModeEnabled: Bool {
        false
    }

    private var isMetalRendererToggleEnabled: Bool {
        isMetalRendererAvailable
    }

    private var isMetalRendererAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    private var newWindowToolbarPlacement: ToolbarItemPlacement {
        return .automatic
    }

    private var terminalShortcutLayer: some View {
        Group {
            Button("Send Command") {
                sendSelectedCommandShortcut()
            }
            .keyboardShortcut(.return, modifiers: [.command])

            Button("Send Ctrl-C") {
                sendControl("\u{03}")
            }
            .keyboardShortcut("c", modifiers: [.control])

            Button("Send Ctrl-D") {
                sendControl("\u{04}")
            }
            .keyboardShortcut("d", modifiers: [.control])

            Button("Find in Terminal") {
                showSearchBar()
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("Toggle Quick Commands") {
                quickCommands.toggleDrawer()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Clear Buffer") {
                clearSelectedBuffer()
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("Previous Session") {
                stepSelectedSession(direction: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Next Session") {
                stepSelectedSession(direction: 1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Disconnect or Close Session") {
                disconnectOrCloseSelectedSession()
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])

            Button("Split Right") {
                splitNextAvailableSession(direction: .vertical)
            }
            .keyboardShortcut("d", modifiers: [.command])

            Button("Split Down") {
                splitNextAvailableSession(direction: .horizontal)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Focus Next Pane") {
                paneManager.focusNext()
            }
            .keyboardShortcut("]", modifiers: [.command])

            Button("Focus Previous Pane") {
                paneManager.focusPrevious()
            }
            .keyboardShortcut("[", modifiers: [.command])

            Button("Maximize/Restore Pane") {
                paneManager.toggleMaximize(paneManager.focusedPaneId)
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])

            Button("New Local Terminal") {
                openLocalTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("New Tab (Local)") {
                openLocalTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command])

            Button("Copy") {
                copyActiveContentToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command])

            Button("Paste") {
                let targetSessionID = paneManager.focusedSessionID ?? focusedSessionID ?? tabManager.selectedSessionID
                if let sessionID = targetSessionID {
                    pasteClipboardToSession(sessionID)
                }
            }
            .keyboardShortcut("v", modifiers: [.command])

            Button("Select All") {
                selectAllInFocusedTerminal()
            }
            .keyboardShortcut("a", modifiers: [.command])
        }
    }

    @ViewBuilder
    private func mouseInputOverlay(for session: Session, contentPadding: CGFloat = 8) -> some View {
        let isEnabled = session.state == .connected && isMouseTrackingEnabled(for: session.id)

        MouseInputHandler(
            isEnabled: isEnabled,
            modeSnapshot: {
                inputModeSnapshot(for: session.id)
            },
            locationToCell: { location in
                terminalCellCoordinates(from: location, contentPadding: contentPadding)
            },
            onSendSequence: { sequence in
                sendControl(sequence, sessionID: session.id)
            }
        )
        .opacity(0.001)
        .accessibilityHidden(true)
        .allowsHitTesting(isEnabled)
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { terminalSearch.query },
            set: { terminalSearch.query = $0 }
        )
    }

    private var searchRegexBinding: Binding<Bool> {
        Binding(
            get: { terminalSearch.isRegexEnabled },
            set: { terminalSearch.isRegexEnabled = $0 }
        )
    }

    private var searchCaseSensitiveBinding: Binding<Bool> {
        Binding(
            get: { terminalSearch.isCaseSensitive },
            set: { terminalSearch.isCaseSensitive = $0 }
        )
    }

    private func attributedTerminalLine(_ line: String, lineIndex: Int) -> AttributedString {
        var attributed = linkDetector.attributedLine(line)
        guard terminalSearch.isPresented else { return attributed }

        let lineMatches = terminalSearch.matches(forLineIndex: lineIndex)
        guard !lineMatches.isEmpty else { return attributed }

        for match in lineMatches {
            guard let lineRange = match.stringRange(in: line),
                  let attributedRange = Range(lineRange, in: attributed) else {
                continue
            }

            if terminalSearch.isSelected(match) {
                attributed[attributedRange].backgroundColor = .orange.opacity(0.6)
                attributed[attributedRange].foregroundColor = colorScheme == .dark ? .black : .primary
            } else {
                attributed[attributedRange].backgroundColor = .yellow.opacity(0.35)
            }
        }

        return attributed
    }

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
        guard let sessionID = targetSessionID else { return }

        // Check for Metal renderer text selection first
        if let selectedText = selectionCoordinator.copySelection(sessionID: sessionID) {
            _ = PlatformClipboard.writeString(selectedText)
            return
        }

        let draft = pendingInput[sessionID, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty {
            _ = PlatformClipboard.writeString(draft)
            return
        }

        if let lastLine = sessionManager.shellBuffers[sessionID]?.last,
           !lastLine.isEmpty {
            _ = PlatformClipboard.writeString(lastLine)
        }
    }

    private func pasteClipboardToSession(_ sessionID: UUID) {
        let bracketedPaste = inputModeSnapshot(for: sessionID).bracketedPasteMode
        let sequences = PasteHandler.readClipboardSequences(bracketedPasteEnabled: bracketedPaste)
        for sequence in sequences {
            sendControl(sequence)
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

    private func isMouseTrackingEnabled(for sessionID: UUID) -> Bool {
        inputModeSnapshot(for: sessionID).mouseTracking != .none
    }

    private func terminalCellCoordinates(from location: CGPoint, contentPadding: CGFloat = 8) -> (row: Int, col: Int)? {
        let fontSize = CGFloat(terminalUIFontSize)
        let estimatedCellWidth = max(1, fontSize * 0.62)
        let estimatedLineHeight = max(1, fontSize * 1.35 + 2)

        let x = max(0, location.x - contentPadding)
        let y = max(0, location.y - contentPadding)
        let row = Int(y / estimatedLineHeight) + 1
        let col = Int(x / estimatedCellWidth) + 1
        return (row: max(1, row), col: max(1, col))
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
        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }

    private func hideSearchBar() {
        terminalSearch.dismiss()
        isSearchFieldFocused = false
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

// MetalTerminalSessionSurface and MetalTerminalSurfaceModel moved to MetalTerminalSessionSurface.swift

private struct SafeTerminalRenderedLine: Identifiable {
    let id: Int
    let text: String
}

private struct DirectTerminalInputCaptureView: NSViewRepresentable {
    let isEnabled: Bool
    let sessionID: UUID
    let keyEncoderOptions: () -> KeyEncoderOptions
    let onSendSequence: (UUID, String) -> Void

    func makeNSView(context: Context) -> DirectTerminalInputNSView {
        let view = DirectTerminalInputNSView(frame: .zero)
        view.isEnabled = isEnabled
        view.sessionID = sessionID
        view.keyEncoderOptions = keyEncoderOptions
        view.onSendSequence = onSendSequence
        view.armForKeyboardInputIfNeeded()
        return view
    }

    func updateNSView(_ nsView: DirectTerminalInputNSView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.sessionID = sessionID
        nsView.keyEncoderOptions = keyEncoderOptions
        nsView.onSendSequence = onSendSequence
        nsView.armForKeyboardInputIfNeeded()
    }
}

private final class DirectTerminalInputNSView: NSView {
    var isEnabled = false
    var sessionID: UUID?
    var keyEncoderOptions: (() -> KeyEncoderOptions)?
    var onSendSequence: ((UUID, String) -> Void)?

    override var acceptsFirstResponder: Bool {
        isEnabled
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func armForKeyboardInputIfNeeded() {
        guard isEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled else { return }
            _ = self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled,
              let sessionID,
              let sequence = encodeEvent(event) else {
            super.keyDown(with: event)
            return
        }
        onSendSequence?(sessionID, sequence)
    }

    // MARK: - Unified Encoding

    private func encodeEvent(_ event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])

        // Command-modified keys are handled by SwiftUI shortcut layer.
        if flags.contains(.command) { return nil }

        let modifiers = mapModifiers(event.modifierFlags)
        let options = keyEncoderOptions?() ?? .default
        let encoder = KeyEncoder(options: options)

        // 1. Special keys (arrows, Tab, Enter, Esc, F-keys, editing keys, Backspace, Delete).
        if let keyEvent = specialKeyEvent(keyCode: event.keyCode, modifiers: modifiers) {
            if let bytes = encoder.encode(keyEvent) {
                return String(bytes: bytes, encoding: .utf8) ?? String(bytes.map { Character(UnicodeScalar($0)) })
            }
            return nil
        }

        // 2. Ctrl+character — encode via KeyEncoder for proper control bytes.
        if modifiers.contains(.ctrl),
           let raw = event.charactersIgnoringModifiers, !raw.isEmpty {
            let ch = raw.first!
            if let scalar = ch.unicodeScalars.first,
               scalar.isASCII,
               (scalar.value < 0x20 || scalar.value == 0x7F) {
                return String(ch)
            }
            let keyEvent = KeyEvent(key: .character(ch), modifiers: modifiers)
            if let bytes = encoder.encode(keyEvent) {
                return String(bytes: bytes, encoding: .utf8) ?? String(bytes.map { Character(UnicodeScalar($0)) })
            }
            return nil
        }

        // 3. Alt/Option+character — ESC prefix + base character.
        if modifiers.contains(.alt),
           let raw = event.charactersIgnoringModifiers, !raw.isEmpty {
            let ch = raw.first!
            let keyEvent = KeyEvent(key: .character(ch), modifiers: modifiers)
            if let bytes = encoder.encode(keyEvent) {
                return String(bytes: bytes, encoding: .utf8) ?? String(bytes.map { Character(UnicodeScalar($0)) })
            }
            return nil
        }

        // 4. Regular characters (includes Shift effect: Shift+1→"!").
        if let characters = event.characters, !characters.isEmpty {
            return characters
        }

        return nil
    }

    // MARK: - Special Key Mapping

    private func specialKeyEvent(keyCode: UInt16, modifiers: KeyModifiers) -> KeyEvent? {
        let key: EncodableKey
        switch keyCode {
        case 126: key = .arrow(.up)
        case 125: key = .arrow(.down)
        case 124: key = .arrow(.right)
        case 123: key = .arrow(.left)
        case 36, 76: key = .enter
        case 48: key = .tab
        case 53: key = .escape
        case 51: key = .backspace
        case 117: key = .editing(.delete)
        case 115: key = .editing(.home)
        case 119: key = .editing(.end)
        case 116: key = .editing(.pageUp)
        case 121: key = .editing(.pageDown)
        case 114: key = .editing(.insert)
        case 122: key = .function(1)
        case 120: key = .function(2)
        case 99:  key = .function(3)
        case 118: key = .function(4)
        case 96:  key = .function(5)
        case 97:  key = .function(6)
        case 98:  key = .function(7)
        case 100: key = .function(8)
        case 101: key = .function(9)
        case 109: key = .function(10)
        case 103: key = .function(11)
        case 111: key = .function(12)
        default: return nil
        }
        return KeyEvent(key: key, modifiers: modifiers)
    }

    // MARK: - Modifier Mapping

    private func mapModifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.alt) }
        if flags.contains(.control) { result.insert(.ctrl) }
        return result
    }
}

// MARK: - iOS Fullscreen Terminal Keyboard Input (removed for macOS)

private extension View {
    @ViewBuilder
    func terminalInputBehavior() -> some View {
        self
    }
}

private struct TerminalScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TerminalScrollContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
