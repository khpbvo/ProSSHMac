import Foundation
import Combine
import Network

enum SessionConnectionError: LocalizedError {
    case hostVerificationRequired(KnownHostVerificationChallenge)
    case hostKeyAlgorithmMismatch(host: String, expected: [String], presented: String)

    var errorDescription: String? {
        switch self {
        case .hostVerificationRequired:
            return "Host key verification is required before connecting."
        case let .hostKeyAlgorithmMismatch(host, expected, presented):
            return "\(host) presented host key algorithm '\(presented)', but this host is pinned to: \(expected.joined(separator: ", "))."
        }
    }
}

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var shellBuffers: [UUID: [String]] = [:]
    @Published private(set) var bellEventNonceBySessionID: [UUID: Int] = [:]
    @Published private(set) var inputModeSnapshotsBySessionID: [UUID: InputModeSnapshot] = [:]
    @Published private(set) var gridSnapshotsBySessionID: [UUID: GridSnapshot] = [:]
    @Published private(set) var gridSnapshotNonceBySessionID: [UUID: Int] = [:]
    @Published private(set) var windowTitleBySessionID: [UUID: String] = [:]
    @Published private(set) var knownHosts: [KnownHostEntry] = []
    @Published private(set) var isRecordingBySessionID: [UUID: Bool] = [:]
    @Published private(set) var hasRecordingBySessionID: [UUID: Bool] = [:]
    @Published private(set) var isPlaybackRunningBySessionID: [UUID: Bool] = [:]
    @Published private(set) var latestRecordingURLBySessionID: [UUID: URL] = [:]
    @Published private(set) var workingDirectoryBySessionID: [UUID: String] = [:]
    @Published private(set) var bytesReceivedBySessionID: [UUID: Int64] = [:]
    @Published private(set) var bytesSentBySessionID: [UUID: Int64] = [:]

    private let transport: any SSHTransporting
    private let knownHostsStore: any KnownHostsStoreProtocol
    private let auditLogManager: AuditLogManager?
    private let portForwardingManager: PortForwardingManager?
    private let sessionRecorder: SessionRecorder
    private var shellChannels: [UUID: any SSHShellChannel] = [:]
    private var parserReaderTasks: [UUID: Task<Void, Never>] = [:]
    private var terminalGrids: [UUID: TerminalGrid] = [:]
    private var vtParsers: [UUID: VTParser] = [:]
    private var inputModeActors: [UUID: InputModeState] = [:]
    private var desiredPTYBySessionID: [UUID: PTYConfiguration] = [:]
    private var hostBySessionID: [UUID: Host] = [:]
    private(set) var lastActivityBySessionID: [UUID: Date] = [:]
    private var jumpHostBySessionID: [UUID: Host] = [:]
    private var pendingReconnectHosts: [UUID: (host: Host, jumpHost: Host?)] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var manuallyDisconnectingSessions: Set<UUID> = []
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "prosshv2.network.monitor")
    private var isNetworkReachable = true
    private var pendingResizeTasks: [UUID: Task<Void, Never>] = [:]
    /// Per-session coalesced snapshot publish task (max one publish per frame interval).
    private var pendingSnapshotPublishTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    /// Per-session scroll offset (0 = live view, >0 = scrolled back N lines).
    private var scrollOffsetBySessionID: [UUID: Int] = [:]
    /// Throttles expensive visible-text extraction/publishing during heavy output.
    private var lastShellBufferPublishAtBySessionID: [UUID: Date] = [:]
    private var keepaliveTask: Task<Void, Never>?
    private let shellBufferPublishInterval: TimeInterval = 1.0 / 30.0
    private let snapshotPublishInterval: Duration = .milliseconds(8)

    private var keepaliveEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ssh.keepalive.enabled")
    }

    private var keepaliveInterval: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: "ssh.keepalive.interval")
        return stored > 0 ? TimeInterval(stored) : 30
    }

    private var configuredScrollbackLines: Int {
        let stored = UserDefaults.standard.integer(forKey: "terminal.scrollback.maxLines")
        return stored > 0 ? stored : TerminalDefaults.maxScrollbackLines
    }

    init(
        transport: any SSHTransporting,
        knownHostsStore: any KnownHostsStoreProtocol,
        auditLogManager: AuditLogManager? = nil,
        portForwardingManager: PortForwardingManager? = nil,
        sessionRecorder: SessionRecorder = SessionRecorder()
    ) {
        self.transport = transport
        self.knownHostsStore = knownHostsStore
        self.auditLogManager = auditLogManager
        self.portForwardingManager = portForwardingManager
        self.sessionRecorder = sessionRecorder

        Task { @MainActor [weak self] in
            await self?.refreshKnownHosts()
        }

        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkStatusChange(isReachable: path.status == .satisfied)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    deinit {
        networkMonitor.cancel()
        reconnectTask?.cancel()
        keepaliveTask?.cancel()
    }

    func connect(to host: Host, jumpHost: Host? = nil, passwordOverride: String? = nil, keyPassphraseOverride: String? = nil) async throws -> Session {
        try await connect(to: host, jumpHost: jumpHost, automaticReconnect: false, passwordOverride: passwordOverride, keyPassphraseOverride: keyPassphraseOverride)
    }

    func closeSession(sessionID: UUID) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return
        }

        if session.state == .connected {
            await disconnect(sessionID: sessionID)
        }

        removeSession(sessionID: sessionID)
    }

    func openLocalSession(
        shellPath: String? = nil,
        workingDirectory: String? = nil
    ) async throws -> Session {
        let resolvedShell = shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (resolvedShell as NSString).lastPathComponent
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()

        let sessionID = UUID()
        var session = Session(
            id: sessionID,
            kind: .local,
            hostLabel: "Local: \(shellName)",
            username: user,
            hostname: "localhost",
            port: 0,
            state: .connecting,
            shellPath: resolvedShell
        )

        sessions.insert(session, at: 0)
        let grid = TerminalGrid(columns: PTYConfiguration.default.columns, rows: PTYConfiguration.default.rows, maxScrollbackLines: configuredScrollbackLines)
        await grid.setLineFeedMode(true)
        terminalGrids[sessionID] = grid
        desiredPTYBySessionID[sessionID] = .default
        let parser = VTParser(grid: grid)
        vtParsers[sessionID] = parser

        let modeState = InputModeState()
        inputModeActors[sessionID] = modeState
        await parser.setInputModeState(modeState)

        gridSnapshotsBySessionID[sessionID] = await grid.snapshot()
        gridSnapshotNonceBySessionID[sessionID] = 0
        shellBuffers[sessionID] = []
        bellEventNonceBySessionID[sessionID] = 0
        inputModeSnapshotsBySessionID[sessionID] = await modeState.snapshot()
        isRecordingBySessionID[sessionID] = false
        hasRecordingBySessionID[sessionID] = false
        isPlaybackRunningBySessionID[sessionID] = false
        bytesReceivedBySessionID[sessionID] = 0
        bytesSentBySessionID[sessionID] = 0

        do {
            let desiredPTY = sanitizedPTY(for: sessionID)
            let channel = try await LocalShellChannel.spawn(
                columns: desiredPTY.columns,
                rows: desiredPTY.rows,
                shellPath: resolvedShell,
                workingDirectory: workingDirectory
            )
            shellChannels[sessionID] = channel

            // Wire response handler so the parser can send CPR/DA responses
            // back through the shell channel.
            if let parser = vtParsers[sessionID] {
                let shellRef: any SSHShellChannel = channel
                await parser.setResponseHandler { @Sendable bytes in
                    let response = String(bytes: bytes, encoding: .utf8) ?? ""
                    guard !response.isEmpty else { return }
                    try? await shellRef.send(response)
                }
            }

            session.state = .connected
            replaceSession(session)

            startParserReader(for: sessionID, rawOutput: channel.rawOutput)

            if let cwd = workingDirectory ?? ProcessInfo.processInfo.environment["HOME"] {
                workingDirectoryBySessionID[sessionID] = cwd
            }

            return session
        } catch {
            session.state = .failed
            session.endedAt = .now
            session.errorMessage = error.localizedDescription
            replaceSession(session)
            throw error
        }
    }

    func restartLocalSession(sessionID: UUID) async throws -> Session {
        guard let oldSession = sessions.first(where: { $0.id == sessionID }),
              oldSession.isLocal else {
            throw LocalShellError.platformUnsupported
        }

        // Capture the tracked working directory before cleanup removes it.
        let trackedWorkingDirectory = workingDirectoryBySessionID[sessionID]

        // Clean up old session artifacts
        if let shell = shellChannels[sessionID] {
            await shell.close()
        }
        removeSessionArtifacts(sessionID: sessionID)
        removeSession(sessionID: sessionID)

        return try await openLocalSession(
            shellPath: oldSession.shellPath,
            workingDirectory: trackedWorkingDirectory
        )
    }

    func applicationDidEnterBackground() {
        for session in sessions where session.state == .connected {
            if let host = hostBySessionID[session.id] {
                pendingReconnectHosts[session.id] = (host: host, jumpHost: jumpHostBySessionID[session.id])
            }
        }
    }

    func applicationDidBecomeActive() {
        scheduleReconnectAttempt(after: .milliseconds(0))
    }

    private func connect(
        to host: Host,
        jumpHost: Host? = nil,
        automaticReconnect: Bool,
        passwordOverride: String?,
        keyPassphraseOverride: String? = nil
    ) async throws -> Session {
        if let jumpHost {
            await auditLogManager?.record(
                category: .connection,
                action: automaticReconnect ? "Reconnect started via jump host" : "Connection started via jump host",
                outcome: .info,
                host: host,
                details: "Jump host: \(jumpHost.label) (\(jumpHost.hostname):\(jumpHost.port))"
            )
        } else {
            await auditLogManager?.record(
                category: .connection,
                action: automaticReconnect ? "Reconnect started" : "Connection started",
                outcome: .info,
                host: host
            )
        }

        // Clean up stale failed/disconnected sessions for this host before creating
        // a new one. This prevents accumulation of dead sessions in the list and ensures
        // transport-level resources are properly released.
        let staleSessionIDs = sessions
            .filter { $0.hostID == host.id && ($0.state == .failed || $0.state == .disconnected) }
            .map(\.id)
        for staleID in staleSessionIDs {
            await transport.disconnect(sessionID: staleID)
            removeSession(sessionID: staleID)
        }

        let sessionID = UUID()
        var session = Session(
            id: sessionID,
            kind: .ssh(hostID: host.id),
            hostLabel: host.label,
            username: host.username,
            hostname: host.hostname,
            port: host.port,
            state: .connecting,
            usesAgentForwarding: host.agentForwardingEnabled,
            jumpHostLabel: jumpHost?.label
        )

        sessions.insert(session, at: 0)
        let grid = TerminalGrid(columns: PTYConfiguration.default.columns, rows: PTYConfiguration.default.rows, maxScrollbackLines: configuredScrollbackLines)
        await grid.setLineFeedMode(true)
        terminalGrids[sessionID] = grid
        desiredPTYBySessionID[sessionID] = .default
        let parser = VTParser(grid: grid)
        vtParsers[sessionID] = parser

        // F.5: Create InputModeState and wire to VTParser so mode changes propagate.
        let modeState = InputModeState()
        inputModeActors[sessionID] = modeState
        await parser.setInputModeState(modeState)

        gridSnapshotsBySessionID[sessionID] = await grid.snapshot()
        gridSnapshotNonceBySessionID[sessionID] = 0
        shellBuffers[sessionID] = []
        bellEventNonceBySessionID[sessionID] = 0
        inputModeSnapshotsBySessionID[sessionID] = await modeState.snapshot()
        isRecordingBySessionID[sessionID] = false
        hasRecordingBySessionID[sessionID] = false
        isPlaybackRunningBySessionID[sessionID] = false
        bytesReceivedBySessionID[sessionID] = 0
        bytesSentBySessionID[sessionID] = 0

        do {
            var jumpHostConfig: JumpHostConfig? = nil
            if let jumpHost {
                let jumpFingerprint = try await resolveJumpHostFingerprint(for: jumpHost)
                jumpHostConfig = JumpHostConfig(host: jumpHost, expectedFingerprint: jumpFingerprint)
            }

            let details = try await transport.connect(sessionID: sessionID, to: host, jumpHostConfig: jumpHostConfig)

            try enforcePinnedHostKeyAlgorithm(for: host, details: details)

            if let challenge = try await evaluateKnownHost(for: host, details: details) {
                let expectation = challenge.expectedFingerprint ?? "none"
                await auditLogManager?.record(
                    category: .hostVerification,
                    action: "Host verification required",
                    outcome: .warning,
                    host: host,
                    sessionID: sessionID,
                    details: "Presented=\(challenge.presentedFingerprint); expected=\(expectation)."
                )
                await transport.disconnect(sessionID: sessionID)
                removeSession(sessionID: sessionID)
                throw SessionConnectionError.hostVerificationRequired(challenge)
            }

            try await transport.authenticate(sessionID: sessionID, to: host, passwordOverride: passwordOverride, keyPassphraseOverride: keyPassphraseOverride)

            session.state = .connected
            session.negotiatedKEX = details.negotiatedKEX
            session.negotiatedCipher = details.negotiatedCipher
            session.negotiatedHostKeyType = details.negotiatedHostKeyType
            session.negotiatedHostFingerprint = details.negotiatedHostFingerprint
            session.usesLegacyCrypto = details.usedLegacyAlgorithms
            session.securityAdvisory = details.securityAdvisory
            session.transportBackend = details.backend
            replaceSession(session)
            hostBySessionID[sessionID] = host
            if let jumpHost {
                jumpHostBySessionID[sessionID] = jumpHost
            }
            for (key, entry) in pendingReconnectHosts where entry.host.id == host.id {
                pendingReconnectHosts.removeValue(forKey: key)
            }

            let securityNote: String
            if details.usedLegacyAlgorithms {
                securityNote = "Connected with legacy algorithm fallback."
            } else {
                securityNote = "Connected with modern algorithm set."
            }
            await auditLogManager?.record(
                category: .authentication,
                action: "Authentication succeeded",
                outcome: .success,
                host: host,
                sessionID: sessionID,
                details: securityNote
            )

            if details.usedLegacyAlgorithms {
                await auditLogManager?.record(
                    category: .security,
                    action: "Legacy algorithms in active use",
                    outcome: .warning,
                    host: host,
                    sessionID: sessionID,
                    details: "KEX=\(details.negotiatedKEX); cipher=\(details.negotiatedCipher); hostKey=\(details.negotiatedHostKeyType)."
                )
            }

            if host.agentForwardingEnabled {
                await auditLogManager?.record(
                    category: .security,
                    action: "SSH agent forwarding enabled",
                    outcome: .warning,
                    host: host,
                    sessionID: sessionID,
                    details: "Remote host can request agent signatures while this session is active."
                )
            }

            try await openShell(for: session)
            startKeepaliveTimerIfNeeded()

            if let pfm = portForwardingManager {
                let enabledRules = host.portForwardingRules.filter(\.isEnabled)
                if !enabledRules.isEmpty {
                    await pfm.activateRules(enabledRules, sessionID: sessionID)
                    await auditLogManager?.record(
                        category: .portForwarding,
                        action: "Port forwarding rules activated",
                        outcome: .info,
                        host: host,
                        sessionID: sessionID,
                        details: "\(enabledRules.count) rule(s) activated."
                    )
                }
            }

            await auditLogManager?.record(
                category: .session,
                action: "Interactive shell opened",
                outcome: .success,
                host: host,
                sessionID: sessionID,
                details: "Backend=\(details.backend.rawValue); KEX=\(details.negotiatedKEX); cipher=\(details.negotiatedCipher)."
            )

            if automaticReconnect {
                removeOlderDisconnectedSessions(for: host.id, keepSessionID: sessionID)
            }

            await refreshKnownHosts()
            return session
        } catch let connectionError as SessionConnectionError {
            await auditLogManager?.record(
                category: .connection,
                action: "Connection blocked",
                outcome: .warning,
                host: host,
                sessionID: sessionID,
                details: connectionError.localizedDescription
            )
            removeSession(sessionID: sessionID)
            throw connectionError
        } catch {
            await auditLogManager?.record(
                category: .connection,
                action: automaticReconnect ? "Reconnect failed" : "Connection failed",
                outcome: .failure,
                host: host,
                sessionID: sessionID,
                details: error.localizedDescription
            )
            if automaticReconnect {
                removeSession(sessionID: sessionID)
            } else {
                session.state = .failed
                session.endedAt = .now
                session.errorMessage = error.localizedDescription
                replaceSession(session)
            }
            throw error
        }
    }

    func disconnect(sessionID: UUID) async {
        guard var session = sessions.first(where: { $0.id == sessionID }) else {
            return
        }

        let hostForSession = hostBySessionID[sessionID]

        manuallyDisconnectingSessions.insert(sessionID)
        defer { manuallyDisconnectingSessions.remove(sessionID) }

        pendingReconnectHosts.removeValue(forKey: sessionID)
        hostBySessionID.removeValue(forKey: sessionID)
        jumpHostBySessionID.removeValue(forKey: sessionID)

        if let pfm = portForwardingManager {
            await pfm.deactivateAll(for: sessionID)
        }

        if let shell = shellChannels[sessionID] {
            await shell.close()
        }
        finalizeRecordingIfNeeded(sessionID: sessionID)
        removeSessionArtifacts(sessionID: sessionID)

        if !session.isLocal {
            await transport.disconnect(sessionID: sessionID)
        }

        session.state = .disconnected
        session.endedAt = .now
        replaceSession(session)
        stopKeepaliveTimerIfIdle()

        await auditLogManager?.record(
            category: .session,
            action: "Session disconnected",
            outcome: .info,
            host: hostForSession,
            sessionID: sessionID
        )
    }

    /// Disconnect all active sessions.
    func disconnectAll() async {
        let activeSessionIDs = sessions
            .filter { $0.state == .connected || $0.state == .connecting }
            .map(\.id)
        for id in activeSessionIDs {
            await disconnect(sessionID: id)
        }
    }

    /// Duplicate a session by connecting to the same host (SSH) or opening a new local shell.
    @discardableResult
    func duplicateSession(_ sessionID: UUID) async throws -> Session? {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return nil }

        if session.isLocal {
            let cwd = workingDirectoryBySessionID[sessionID]
            return try await openLocalSession(
                shellPath: session.shellPath,
                workingDirectory: cwd
            )
        } else if let host = hostBySessionID[sessionID] {
            let jumpHost = jumpHostBySessionID[sessionID]
            return try await connect(to: host, jumpHost: jumpHost)
        }
        return nil
    }

    func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool = false) async {
        guard sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            await appendShellLine("Session is not connected.", to: sessionID)
            return
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        guard let shell = shellChannels[sessionID] else {
            await appendShellLine("Shell channel is not available.", to: sessionID)
            return
        }

        do {
            let payload = trimmed + "\n"
            try await shell.send(payload)
            lastActivityBySessionID[sessionID] = .now
            bytesSentBySessionID[sessionID, default: 0] += Int64(payload.utf8.count)
            sessionRecorder.recordInput(sessionID: sessionID, text: payload)
        } catch {
            await appendShellLine("Error: \(error.localizedDescription)", to: sessionID)
        }
    }

    func sendRawShellInput(sessionID: UUID, input: String) async {
        guard sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            await appendShellLine("Session is not connected.", to: sessionID)
            return
        }

        guard let shell = shellChannels[sessionID] else {
            await appendShellLine("Shell channel is not available.", to: sessionID)
            return
        }

        do {
            try await shell.send(input)
            bytesSentBySessionID[sessionID, default: 0] += Int64(input.utf8.count)
            sessionRecorder.recordInput(sessionID: sessionID, text: input)
        } catch {
            await appendShellLine("Error: \(error.localizedDescription)", to: sessionID)
        }
    }

    // MARK: - F.6 PTY Resize

    /// Resizes the remote PTY and terminal grid for a session.
    /// Called when the terminal view dimensions change.
    ///
    /// - Parameters:
    ///   - sessionID: The session to resize.
    ///   - columns: New column count.
    ///   - rows: New row count.
    func resizeTerminal(sessionID: UUID, columns: Int, rows: Int) async {
        // Ignore transient layout sizes from early view lifecycle passes.
        // These can briefly report tiny dimensions (e.g. 1xN) and break
        // remote shell wrapping for the session.
        guard columns >= 10, rows >= 4 else { return }

        desiredPTYBySessionID[sessionID] = PTYConfiguration(
            columns: columns,
            rows: rows,
            terminalType: PTYConfiguration.default.terminalType
        )

        // Resize the local terminal grid immediately (no debounce needed).
        if let grid = terminalGrids[sessionID] {
            await grid.resize(newColumns: columns, newRows: rows)
            let snapshot = await grid.snapshot()
            gridSnapshotsBySessionID[sessionID] = snapshot
            gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
        }

        // Debounce PTY resize to avoid flooding the shell with TIOCSWINSZ
        // calls during split pane divider dragging.
        pendingResizeTasks[sessionID]?.cancel()
        pendingResizeTasks[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard let self, let shell = self.shellChannels[sessionID] else { return }
            do {
                try await shell.resizePTY(columns: columns, rows: rows)
            } catch {
                // Non-fatal: log but don't surface to user.
            }
            self.pendingResizeTasks.removeValue(forKey: sessionID)
        }
    }

    func clearShellBuffer(sessionID: UUID) {
        guard let grid = terminalGrids[sessionID] else { return }
        Task { @MainActor in
            await grid.eraseInDisplay(mode: 3)
            await grid.moveCursorTo(row: 0, col: 0)
            let snapshot = await grid.snapshot()
            gridSnapshotsBySessionID[sessionID] = snapshot
            gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
            shellBuffers[sessionID] = await grid.visibleText()
        }
    }

    // MARK: - Scrollback Navigation

    /// Scroll the terminal viewport for a session by the given number of lines.
    /// Positive delta scrolls up (into scrollback), negative scrolls down (toward live).
    func scrollTerminal(sessionID: UUID, delta: Int) {
        guard let grid = terminalGrids[sessionID] else { return }
        let current = scrollOffsetBySessionID[sessionID, default: 0]
        Task { @MainActor in
            let maxOffset = await grid.scrollbackCount
            let newOffset = max(0, min(current + delta, maxOffset))
            scrollOffsetBySessionID[sessionID] = newOffset
            let snapshot = await grid.snapshot(scrollOffset: newOffset)
            gridSnapshotsBySessionID[sessionID] = snapshot
            gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
        }
    }

    /// Reset scroll position to the live terminal view (bottom).
    func scrollToBottom(sessionID: UUID) {
        guard let grid = terminalGrids[sessionID] else { return }
        scrollOffsetBySessionID[sessionID] = 0
        Task { @MainActor in
            let snapshot = await grid.snapshot()
            gridSnapshotsBySessionID[sessionID] = snapshot
            gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
        }
    }

    /// Whether the session is currently scrolled back from the live view.
    func isScrolledBack(sessionID: UUID) -> Bool {
        (scrollOffsetBySessionID[sessionID] ?? 0) > 0
    }

    func toggleRecording(sessionID: UUID) async {
        if isRecordingBySessionID[sessionID, default: false] {
            await stopRecording(sessionID: sessionID)
        } else {
            await startRecording(sessionID: sessionID)
        }
    }

    func startRecording(sessionID: UUID) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return
        }
        do {
            try sessionRecorder.startRecording(for: session)
            isRecordingBySessionID[sessionID] = true
            await appendShellLine("[Recorder] Started session capture.", to: sessionID)
        } catch {
            await appendShellLine("[Recorder] \(error.localizedDescription)", to: sessionID)
        }
    }

    func stopRecording(sessionID: UUID) async {
        do {
            let recordingURL = try sessionRecorder.stopRecording(sessionID: sessionID)
            isRecordingBySessionID[sessionID] = false
            hasRecordingBySessionID[sessionID] = true
            latestRecordingURLBySessionID[sessionID] = recordingURL
            await appendShellLine("[Recorder] Saved encrypted recording: \(recordingURL.lastPathComponent)", to: sessionID)
        } catch {
            await appendShellLine("[Recorder] \(error.localizedDescription)", to: sessionID)
        }
    }

    func playLastRecording(sessionID: UUID, speed: Double) async {
        guard !isPlaybackRunningBySessionID[sessionID, default: false] else {
            return
        }

        isPlaybackRunningBySessionID[sessionID] = true
        defer { isPlaybackRunningBySessionID[sessionID] = false }

        do {
            clearShellBuffer(sessionID: sessionID)
            await appendShellLine("[Recorder] Playback started (\(String(format: "%.1fx", speed))).", to: sessionID)
            try await sessionRecorder.playLatestRecording(sessionID: sessionID, speed: speed) { [weak self] step in
                await self?.applyPlaybackStep(step, to: sessionID)
            }
            await appendShellLine("[Recorder] Playback finished.", to: sessionID)
        } catch {
            await appendShellLine("[Recorder] Playback failed: \(error.localizedDescription)", to: sessionID)
        }
    }

    func exportLastRecordingAsCast(sessionID: UUID, columns: Int = 80, rows: Int = 24) async {
        do {
            let castURL = try sessionRecorder.exportLatestRecordingAsCast(
                sessionID: sessionID,
                columns: columns,
                rows: rows
            )
            await appendShellLine("[Recorder] Exported .cast: \(castURL.path(percentEncoded: false))", to: sessionID)
        } catch {
            await appendShellLine("[Recorder] Export failed: \(error.localizedDescription)", to: sessionID)
        }
    }

    func listRemoteDirectory(sessionID: UUID, path: String) async throws -> [SFTPDirectoryEntry] {
        guard sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            throw SSHTransportError.sessionNotFound
        }
        return try await transport.listDirectory(sessionID: sessionID, path: path)
    }

    func uploadFile(sessionID: UUID, localPath: String, remotePath: String) async throws -> SFTPTransferResult {
        guard sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            throw SSHTransportError.sessionNotFound
        }
        return try await transport.uploadFile(sessionID: sessionID, localPath: localPath, remotePath: remotePath)
    }

    func downloadFile(sessionID: UUID, remotePath: String, localPath: String) async throws -> SFTPTransferResult {
        guard sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            throw SSHTransportError.sessionNotFound
        }
        return try await transport.downloadFile(sessionID: sessionID, remotePath: remotePath, localPath: localPath)
    }

    func activeSession(for hostID: UUID) -> Session? {
        sessions.first(where: { $0.hostID == hostID && $0.state == .connected })
    }

    /// Returns the most relevant session for a host, prioritizing by state:
    /// connected > connecting > most-recently-ended (disconnected/failed).
    func mostRelevantSession(for hostID: UUID) -> Session? {
        let hostSessions = sessions.filter { $0.hostID == hostID }
        return hostSessions.first(where: { $0.state == .connected })
            ?? hostSessions.first(where: { $0.state == .connecting })
            ?? hostSessions
                .filter { $0.state == .disconnected || $0.state == .failed }
                .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
                .first
    }

    /// Total bytes received + sent for a session.
    func totalTraffic(for sessionID: UUID) -> (received: Int64, sent: Int64) {
        (
            received: bytesReceivedBySessionID[sessionID] ?? 0,
            sent: bytesSentBySessionID[sessionID] ?? 0
        )
    }

    func trustKnownHost(challenge: KnownHostVerificationChallenge) async throws {
        do {
            try await knownHostsStore.trust(challenge: challenge)
            await refreshKnownHosts()
            await auditLogManager?.record(
                category: .hostVerification,
                action: challenge.isMismatch ? "Host key override trusted" : "Host key trusted",
                outcome: .success,
                hostname: challenge.hostname,
                port: challenge.port,
                details: "Fingerprint=\(challenge.presentedFingerprint)."
            )
        } catch {
            await auditLogManager?.record(
                category: .hostVerification,
                action: "Host key trust failed",
                outcome: .failure,
                hostname: challenge.hostname,
                port: challenge.port,
                details: error.localizedDescription
            )
            throw error
        }
    }

    func clearKnownHosts() async {
        do {
            try await knownHostsStore.clearAll()
            await refreshKnownHosts()
            await auditLogManager?.record(
                category: .security,
                action: "Known hosts cleared",
                outcome: .warning
            )
        } catch {
            await auditLogManager?.record(
                category: .security,
                action: "Known hosts clear failed",
                outcome: .failure,
                details: error.localizedDescription
            )
            // Best-effort maintenance action; keep UI responsive on failure.
        }
    }

    func refreshKnownHosts() async {
        do {
            knownHosts = try await knownHostsStore.allEntries()
        } catch {
            // Best-effort read; avoid surfacing store errors globally.
            knownHosts = []
        }
    }

    private func openShell(for session: Session) async throws {
        let desiredPTY = sanitizedPTY(for: session.id)
        let channel = try await transport.openShell(
            sessionID: session.id,
            pty: desiredPTY,
            enableAgentForwarding: session.usesAgentForwarding
        )
        shellChannels[session.id] = channel

        // Wire response handler so the parser can send CPR/DA responses
        // back through the shell channel.
        if let parser = vtParsers[session.id] {
            let shellRef: any SSHShellChannel = channel
            await parser.setResponseHandler { @Sendable bytes in
                let response = String(bytes: bytes, encoding: .utf8) ?? ""
                guard !response.isEmpty else { return }
                try? await shellRef.send(response)
            }
        }

        // Safety net: if the first usable geometry arrived before shell open,
        // ensure remote PTY is synchronized immediately.
        do {
            try await channel.resizePTY(columns: desiredPTY.columns, rows: desiredPTY.rows)
        } catch {
            // Non-fatal: subsequent resize events will retry synchronization.
        }

        startParserReader(for: session.id, rawOutput: channel.rawOutput)
    }

    private func sanitizedPTY(for sessionID: UUID) -> PTYConfiguration {
        let current = desiredPTYBySessionID[sessionID] ?? .default
        return PTYConfiguration(
            columns: max(10, current.columns),
            rows: max(4, current.rows),
            terminalType: current.terminalType
        )
    }

    private func startParserReader(for sessionID: UUID, rawOutput: AsyncStream<Data>) {
        parserReaderTasks[sessionID]?.cancel()
        guard let parser = vtParsers[sessionID],
              let grid = terminalGrids[sessionID] else {
            return
        }

        let modeState = inputModeActors[sessionID]

        parserReaderTasks[sessionID] = Task { @MainActor in
            for await chunk in rawOutput {
                if Task.isCancelled {
                    break
                }
                await parser.feed(chunk)
                lastActivityBySessionID[sessionID] = .now
                bytesReceivedBySessionID[sessionID, default: 0] += Int64(chunk.count)

                // Only decode output text when recording is active.
                // This avoids large per-chunk UTF-8 decode overhead during bulk output.
                if sessionRecorder.isRecording(sessionID: sessionID) {
                    sessionRecorder.recordOutput(sessionID: sessionID, text: String(decoding: chunk, as: UTF8.self))
                }

                // When the terminal is in synchronized output mode (DECSET 2026),
                // the application has signaled that a batch update is in progress.
                // Skip snapshot generation to prevent rendering intermediate/partial
                // states that cause visual artifacts (garbled characters, partial
                // overwrites). The snapshot will be taken when sync mode ends.
                //
                // However, if sync mode toggled off *and back on* within this
                // single chunk, we must publish the intermediate visible frame
                // captured when sync re-enables — otherwise that frame is lost
                // and stale content ("ghost characters") persists on screen.
                if let syncExitSnap = await grid.consumeSyncExitSnapshot() {
                    scrollOffsetBySessionID[sessionID] = 0
                    cancelPendingSnapshotPublish(for: sessionID)
                    await publishGridState(
                        for: sessionID,
                        grid: grid,
                        modeState: modeState,
                        snapshotOverride: syncExitSnap
                    )
                }

                let inSyncMode = await grid.synchronizedOutput
                if inSyncMode { continue }

                // Auto-reset scroll offset when new output arrives.
                scrollOffsetBySessionID[sessionID] = 0

                // Frame-coalesced publish: parse every chunk immediately,
                // but publish at most once per display interval.
                scheduleCoalescedGridPublish(
                    for: sessionID,
                    grid: grid,
                    modeState: modeState
                )
            }

            await flushPendingSnapshotPublishIfNeeded(
                for: sessionID,
                grid: grid,
                modeState: modeState
            )

            // Stream ended — force-exit alternate buffer if the program
            // crashed or exited without sending ESC[?1049l. This prevents
            // alternate screen content from leaking into the primary buffer.
            if await grid.usingAlternateBuffer {
                await grid.disableAlternateBuffer()
                await publishGridState(for: sessionID, grid: grid, modeState: modeState)
            }

            // Detect disconnection.
            if !Task.isCancelled {
                await handleShellStreamEnded(sessionID: sessionID)
            }
        }
    }

    private func handleShellStreamEnded(sessionID: UUID) async {
        guard !manuallyDisconnectingSessions.contains(sessionID) else {
            return
        }

        guard var session = sessions.first(where: { $0.id == sessionID }) else {
            return
        }

        guard session.state == .connected else {
            return
        }

        // Local sessions: mark disconnected without reconnect attempts.
        if session.isLocal {
            session.state = .disconnected
            session.endedAt = .now
            session.errorMessage = "Shell process exited."
            replaceSession(session)
            finalizeRecordingIfNeeded(sessionID: sessionID)
            removeSessionArtifacts(sessionID: sessionID)
            return
        }

        session.state = .disconnected
        session.endedAt = .now
        session.errorMessage = "Connection lost. Reconnecting when network is available."
        replaceSession(session)
        stopKeepaliveTimerIfIdle()

        let host = hostBySessionID[sessionID]
        if let host {
            pendingReconnectHosts[sessionID] = (host: host, jumpHost: jumpHostBySessionID[sessionID])
        }

        await auditLogManager?.record(
            category: .session,
            action: "Connection lost",
            outcome: .warning,
            host: host,
            sessionID: sessionID,
            details: "Queued for automatic reconnect."
        )

        if let pfm = portForwardingManager {
            await pfm.deactivateAll(for: sessionID)
        }

        finalizeRecordingIfNeeded(sessionID: sessionID)
        removeSessionArtifacts(sessionID: sessionID)
        await transport.disconnect(sessionID: sessionID)
        scheduleReconnectAttempt(after: .seconds(1))
    }

    private func appendShellLine(_ line: String, to sessionID: UUID) async {
        guard let parser = vtParsers[sessionID],
              let grid = terminalGrids[sessionID] else { return }
        // Prepend CAN (0x18) to abort any in-progress escape sequence before
        // injecting the system message. Without this, if the previous SSH chunk
        // ended mid-escape (e.g. the last byte was ESC), the system message
        // bytes would be misinterpreted as part of that escape sequence.
        var bytes: [UInt8] = [0x18] // CAN — returns parser to ground state
        bytes.append(contentsOf: Array(("\r\n" + line + "\r\n").utf8))
        let data = Data(bytes)
        // Feed directly instead of spawning a detached Task to avoid racing
        // with the reader loop for snapshot updates. If another feed() is
        // in progress (reader loop), the data is queued by the VTParser's
        // reentrancy guard and the active feeder will process it — we skip
        // the snapshot because the reader loop will take one after draining
        // the queue.
        let didProcess = await parser.feed(data)
        if didProcess {
            let snapshot = await grid.snapshot()
            gridSnapshotsBySessionID[sessionID] = snapshot
            gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
            shellBuffers[sessionID] = await grid.visibleText()
        }
    }

    private func applyPlaybackStep(_ step: SessionPlaybackStep, to sessionID: UUID) async {
        guard step.stream == .output else { return }
        guard let parser = vtParsers[sessionID],
              let grid = terminalGrids[sessionID] else { return }
        let data = Data(step.text.utf8)
        let didProcess = await parser.feed(data)
        if didProcess {
            let snapshot = await grid.snapshot()
            gridSnapshotsBySessionID[sessionID] = snapshot
            gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
            shellBuffers[sessionID] = await grid.visibleText()
        }
    }

    private func replaceSession(_ updatedSession: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == updatedSession.id }) else {
            return
        }
        sessions[index] = updatedSession
    }

    private func removeSession(sessionID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }

        if let pfm = portForwardingManager {
            Task {
                await pfm.deactivateAll(for: sessionID)
            }
        }
        pendingReconnectHosts.removeValue(forKey: sessionID)
        hostBySessionID.removeValue(forKey: sessionID)
        jumpHostBySessionID.removeValue(forKey: sessionID)
        sessions.removeAll(where: { $0.id == sessionID })
        finalizeRecordingIfNeeded(sessionID: sessionID)
        hasRecordingBySessionID.removeValue(forKey: sessionID)
        latestRecordingURLBySessionID.removeValue(forKey: sessionID)
        removeSessionArtifacts(sessionID: sessionID)
    }

    private func finalizeRecordingIfNeeded(sessionID: UUID) {
        guard sessionRecorder.isRecording(sessionID: sessionID) else {
            return
        }

        Task { @MainActor in
            do {
                let recordingURL = try sessionRecorder.stopRecording(sessionID: sessionID)
                hasRecordingBySessionID[sessionID] = true
                latestRecordingURLBySessionID[sessionID] = recordingURL
            } catch {
                // Best-effort finalization when sessions disconnect unexpectedly.
            }
        }
    }

    private func removeSessionArtifacts(sessionID: UUID) {
        parserReaderTasks[sessionID]?.cancel()
        parserReaderTasks.removeValue(forKey: sessionID)
        cancelPendingSnapshotPublish(for: sessionID)
        shellChannels.removeValue(forKey: sessionID)
        terminalGrids.removeValue(forKey: sessionID)
        vtParsers.removeValue(forKey: sessionID)
        inputModeActors.removeValue(forKey: sessionID)
        desiredPTYBySessionID.removeValue(forKey: sessionID)
        shellBuffers.removeValue(forKey: sessionID)
        lastShellBufferPublishAtBySessionID.removeValue(forKey: sessionID)
        bellEventNonceBySessionID.removeValue(forKey: sessionID)
        inputModeSnapshotsBySessionID.removeValue(forKey: sessionID)
        gridSnapshotsBySessionID.removeValue(forKey: sessionID)
        gridSnapshotNonceBySessionID.removeValue(forKey: sessionID)
        isRecordingBySessionID[sessionID] = false
        isPlaybackRunningBySessionID[sessionID] = false
        workingDirectoryBySessionID.removeValue(forKey: sessionID)
        bytesReceivedBySessionID.removeValue(forKey: sessionID)
        bytesSentBySessionID.removeValue(forKey: sessionID)
    }

    private func shouldPublishShellBuffer(for sessionID: UUID, now: Date = .now) -> Bool {
        if let lastPublished = lastShellBufferPublishAtBySessionID[sessionID],
           now.timeIntervalSince(lastPublished) < shellBufferPublishInterval {
            return false
        }
        lastShellBufferPublishAtBySessionID[sessionID] = now
        return true
    }

    private func scheduleCoalescedGridPublish(
        for sessionID: UUID,
        grid: TerminalGrid,
        modeState: InputModeState?
    ) {
        guard pendingSnapshotPublishTasksBySessionID[sessionID] == nil else {
            return
        }

        pendingSnapshotPublishTasksBySessionID[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.snapshotPublishInterval)
            guard !Task.isCancelled else { return }
            self.pendingSnapshotPublishTasksBySessionID.removeValue(forKey: sessionID)
            await self.publishGridState(for: sessionID, grid: grid, modeState: modeState)
        }
    }

    private func flushPendingSnapshotPublishIfNeeded(
        for sessionID: UUID,
        grid: TerminalGrid,
        modeState: InputModeState?
    ) async {
        guard pendingSnapshotPublishTasksBySessionID[sessionID] != nil else {
            return
        }
        cancelPendingSnapshotPublish(for: sessionID)
        await publishGridState(for: sessionID, grid: grid, modeState: modeState)
    }

    private func cancelPendingSnapshotPublish(for sessionID: UUID) {
        pendingSnapshotPublishTasksBySessionID[sessionID]?.cancel()
        pendingSnapshotPublishTasksBySessionID.removeValue(forKey: sessionID)
    }

    private func publishGridState(
        for sessionID: UUID,
        grid: TerminalGrid,
        modeState: InputModeState?,
        snapshotOverride: GridSnapshot? = nil
    ) async {
        // Session may have been torn down while a scheduled publish was pending.
        guard terminalGrids[sessionID] != nil else { return }

        let snapshot: GridSnapshot
        if let snapshotOverride {
            snapshot = snapshotOverride
        } else {
            snapshot = await grid.snapshot()
        }
        gridSnapshotsBySessionID[sessionID] = snapshot
        gridSnapshotNonceBySessionID[sessionID, default: 0] += 1

        // Derive text lines from grid for fallback view, search, and password detection.
        if shouldPublishShellBuffer(for: sessionID) {
            shellBuffers[sessionID] = await grid.visibleText()
        }

        // F.8: Propagate bell events from VTParser → grid → UI.
        let bellCount = await grid.consumeBellCount()
        if bellCount > 0 {
            bellEventNonceBySessionID[sessionID, default: 0] += bellCount
        }

        // F.5: Propagate input mode changes to published snapshots.
        if let modeState {
            inputModeSnapshotsBySessionID[sessionID] = await modeState.snapshot()
        }

        // F.7: Propagate window title changes to published state.
        let title = await grid.windowTitle
        if !title.isEmpty {
            windowTitleBySessionID[sessionID] = title
        }

        // Propagate working directory from OSC 7.
        let cwd = await grid.workingDirectory
        if !cwd.isEmpty {
            workingDirectoryBySessionID[sessionID] = cwd
        }
    }

    // MARK: - SSH Keepalive

    private func startKeepaliveTimerIfNeeded() {
        guard keepaliveEnabled, keepaliveTask == nil else { return }
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.keepaliveInterval ?? 30))
                guard !Task.isCancelled else { break }
                await self?.sendKeepalives()
            }
        }
    }

    private func stopKeepaliveTimerIfIdle() {
        let hasConnectedSSHSession = sessions.contains { $0.state == .connected && !$0.isLocal }
        if !hasConnectedSSHSession {
            keepaliveTask?.cancel()
            keepaliveTask = nil
        }
    }

    private func sendKeepalives() async {
        let connectedSSHSessions = sessions.filter { $0.state == .connected && !$0.isLocal }
        for session in connectedSSHSessions {
            let lastActivity = lastActivityBySessionID[session.id] ?? .distantPast
            if Date.now.timeIntervalSince(lastActivity) < keepaliveInterval * 0.8 {
                continue
            }

            let alive = await transport.sendKeepalive(sessionID: session.id)
            if !alive {
                await handleShellStreamEnded(sessionID: session.id)
            }
        }
    }

    private func evaluateKnownHost(
        for host: Host,
        details: SSHConnectionDetails
    ) async throws -> KnownHostVerificationChallenge? {
        let fingerprint = details.negotiatedHostFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty, fingerprint.lowercased() != "unknown" else {
            throw SSHTransportError.transportFailure(message: "Unable to retrieve host key fingerprint for verification.")
        }

        let verification = try await knownHostsStore.evaluate(
            hostname: host.hostname,
            port: host.port,
            hostKeyType: details.negotiatedHostKeyType,
            presentedFingerprint: fingerprint
        )

        switch verification {
        case .trusted:
            return nil
        case let .requiresUserApproval(challenge):
            return challenge
        }
    }

    private func resolveJumpHostFingerprint(for jumpHost: Host) async throws -> String {
        let entries = try await knownHostsStore.allEntries()
        if let entry = entries.first(where: {
            $0.hostname == jumpHost.hostname && $0.port == jumpHost.port
        }) {
            return entry.fingerprint
        }

        let probeSessionID = UUID()
        let probeDetails = try await transport.connect(sessionID: probeSessionID, to: jumpHost)
        await transport.disconnect(sessionID: probeSessionID)

        let fingerprint = probeDetails.negotiatedHostFingerprint
        guard !fingerprint.isEmpty, fingerprint.lowercased() != "unknown" else {
            throw SSHTransportError.transportFailure(
                message: "Unable to retrieve fingerprint for jump host '\(jumpHost.label)'."
            )
        }

        let challenge = KnownHostVerificationChallenge(
            hostname: jumpHost.hostname,
            port: jumpHost.port,
            hostKeyType: probeDetails.negotiatedHostKeyType,
            presentedFingerprint: fingerprint,
            expectedFingerprint: nil
        )
        throw SessionConnectionError.hostVerificationRequired(challenge)
    }

    private func enforcePinnedHostKeyAlgorithm(
        for host: Host,
        details: SSHConnectionDetails
    ) throws {
        guard !host.pinnedHostKeyAlgorithms.isEmpty else {
            return
        }

        let pinned = Set(host.pinnedHostKeyAlgorithms.map { $0.lowercased() })
        let negotiated = details.negotiatedHostKeyType.lowercased()
        guard pinned.contains(negotiated) else {
            throw SessionConnectionError.hostKeyAlgorithmMismatch(
                host: host.label,
                expected: host.pinnedHostKeyAlgorithms,
                presented: details.negotiatedHostKeyType
            )
        }
    }

    private func removeOlderDisconnectedSessions(for hostID: UUID, keepSessionID: UUID) {
        let obsolete = sessions
            .filter { $0.hostID == hostID && $0.id != keepSessionID && $0.state != .connected }
            .map(\.id)

        for sessionID in obsolete {
            removeSession(sessionID: sessionID)
        }
    }

    private func handleNetworkStatusChange(isReachable: Bool) {
        let wasReachable = isNetworkReachable
        isNetworkReachable = isReachable

        if isReachable && !wasReachable {
            scheduleReconnectAttempt(after: .milliseconds(250))
        }
    }

    private func scheduleReconnectAttempt(after delay: Duration) {
        guard reconnectTask == nil else {
            return
        }

        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }

            await self.attemptPendingReconnects()
            self.reconnectTask = nil

            if self.isNetworkReachable && !self.pendingReconnectHosts.isEmpty {
                self.scheduleReconnectAttempt(after: .seconds(5))
            }
        }
    }

    private func attemptPendingReconnects() async {
        guard isNetworkReachable else {
            return
        }

        let snapshot = pendingReconnectHosts
        for (oldSessionID, entry) in snapshot {
            if activeSession(for: entry.host.id) != nil {
                pendingReconnectHosts.removeValue(forKey: oldSessionID)
                continue
            }

            do {
                _ = try await connect(to: entry.host, jumpHost: entry.jumpHost, automaticReconnect: true, passwordOverride: nil)
                pendingReconnectHosts.removeValue(forKey: oldSessionID)
            } catch SessionConnectionError.hostVerificationRequired {
                pendingReconnectHosts.removeValue(forKey: oldSessionID)
            } catch {
                // Keep entry in pending queue for a later retry.
            }
        }
    }

    // MARK: - Screenshot Mode Support

    func injectScreenshotSessions() async {
        let sampleSessions = ScreenshotSampleData.sessions
        sessions = sampleSessions

        for session in sampleSessions {
            let grid = TerminalGrid(
                columns: 80, rows: 24,
                maxScrollbackLines: 1000
            )
            await grid.setLineFeedMode(true)
            terminalGrids[session.id] = grid

            let parser = VTParser(grid: grid)
            vtParsers[session.id] = parser

            let modeState = InputModeState()
            inputModeActors[session.id] = modeState
            await parser.setInputModeState(modeState)

            desiredPTYBySessionID[session.id] = .default
            shellBuffers[session.id] = []
            bellEventNonceBySessionID[session.id] = 0
            isRecordingBySessionID[session.id] = false
            hasRecordingBySessionID[session.id] = false
            isPlaybackRunningBySessionID[session.id] = false

            // Inject realistic traffic counters
            bytesReceivedBySessionID[session.id] = Int64.random(in: 8_000...250_000)
            bytesSentBySessionID[session.id] = Int64.random(in: 1_000...50_000)

            // Feed realistic terminal output for the first (primary) session
            if session.id == sampleSessions.first?.id {
                let terminalText = ScreenshotSampleData.terminalOutput
                let data = Data(terminalText.utf8)
                await parser.feed(data)
            }

            let snapshot = await grid.snapshot()
            gridSnapshotsBySessionID[session.id] = snapshot
            gridSnapshotNonceBySessionID[session.id] = 1
            inputModeSnapshotsBySessionID[session.id] = await modeState.snapshot()
            shellBuffers[session.id] = await grid.visibleText()
        }
    }
}
