// swiftlint:disable file_length
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
    @Published var shellBuffers: [UUID: [String]] = [:]
    @Published var bellEventNonceBySessionID: [UUID: Int] = [:]
    @Published var inputModeSnapshotsBySessionID: [UUID: InputModeSnapshot] = [:]
    @Published var gridSnapshotNonceBySessionID: [UUID: Int] = [:]
    @Published var windowTitleBySessionID: [UUID: String] = [:]
    @Published private(set) var knownHosts: [KnownHostEntry] = []
    @Published var isRecordingBySessionID: [UUID: Bool] = [:]
    @Published var hasRecordingBySessionID: [UUID: Bool] = [:]
    @Published var isPlaybackRunningBySessionID: [UUID: Bool] = [:]
    @Published var latestRecordingURLBySessionID: [UUID: URL] = [:]
    @Published var workingDirectoryBySessionID: [UUID: String] = [:]
    @Published private(set) var bytesReceivedBySessionID: [UUID: Int64] = [:]
    @Published private(set) var bytesSentBySessionID: [UUID: Int64] = [:]
    @Published private(set) var latestCompletedCommandBlockBySessionID: [UUID: CommandBlock] = [:]
    @Published private(set) var commandCompletionNonceBySessionID: [UUID: Int] = [:]

    let transport: any SSHTransporting
    private let knownHostsStore: any KnownHostsStoreProtocol
    private let auditLogManager: AuditLogManager?
    private let portForwardingManager: PortForwardingManager?
    private let sessionRecorder: SessionRecorder
    let terminalHistoryIndex = TerminalHistoryIndex()
    var shellChannels: [UUID: any SSHShellChannel] = [:]
    private var parserReaderTasks: [UUID: Task<Void, Never>] = [:]
    var engines: [UUID: TerminalEngine] = [:]
    var hostBySessionID: [UUID: Host] = [:]
    var lastActivityBySessionID: [UUID: Date] = [:]
    var jumpHostBySessionID: [UUID: Host] = [:]
    var manuallyDisconnectingSessions: Set<UUID> = []
    let reconnectCoordinator: SessionReconnectCoordinator
    let keepaliveCoordinator: SessionKeepaliveCoordinator
    let renderingCoordinator: TerminalRenderingCoordinator
    private var latestPublishedCommandBlockIDBySessionID: [UUID: UUID] = [:]

    /// Runtime throughput policy. When enabled, expensive non-render work is throttled:
    /// - Snapshot publish interval relaxed from 8ms to 16ms (~60fps → ~30fps)
    /// - Shell buffer text extraction throttled from 30Hz to 5Hz
    /// - Bell events rate-limited to 1 per second per session
    /// - Session recorder uses chunk coalescing (64KB / 100ms flush)
    /// Toggle via: `defaults write com.prossh terminal.throughput.mode.enabled -bool true`
    var throughputModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "terminal.throughput.mode.enabled")
    }

    var configuredScrollbackLines: Int {
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
        let coord = SessionReconnectCoordinator()
        self.reconnectCoordinator = coord
        self.keepaliveCoordinator = SessionKeepaliveCoordinator()
        let renderCoord = TerminalRenderingCoordinator()
        self.renderingCoordinator = renderCoord

        Task { @MainActor [weak self] in
            await self?.refreshKnownHosts()
        }

        coord.manager = self
        coord.start()
        keepaliveCoordinator.manager = self
        renderCoord.manager = self
    }

    nonisolated deinit {}

    func connect(to host: Host, jumpHost: Host? = nil, passwordOverride: String? = nil, keyPassphraseOverride: String? = nil) async throws -> Session {
        try await connect(to: host, jumpHost: jumpHost, automaticReconnect: false, passwordOverride: passwordOverride, keyPassphraseOverride: keyPassphraseOverride)
    }

    func reconnectConnect(host: Host, jumpHost: Host?) async throws -> Session {
        try await connect(to: host, jumpHost: jumpHost, automaticReconnect: true, passwordOverride: nil)
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
        let engine = TerminalEngine(columns: PTYConfiguration.default.columns, rows: PTYConfiguration.default.rows, maxScrollbackLines: configuredScrollbackLines)
        await engine.setLineFeedMode(true)
        await configureHistoryTracking(for: session, engine: engine)
        engines[sessionID] = engine
        renderingCoordinator.initializePTY(for: sessionID)

        renderingCoordinator.gridSnapshotsBySessionID[sessionID] = await engine.snapshot()
        gridSnapshotNonceBySessionID[sessionID] = 0
        shellBuffers[sessionID] = []
        bellEventNonceBySessionID[sessionID] = 0
        inputModeSnapshotsBySessionID[sessionID] = await engine.inputModeSnapshot()
        isRecordingBySessionID[sessionID] = false
        hasRecordingBySessionID[sessionID] = false
        isPlaybackRunningBySessionID[sessionID] = false
        bytesReceivedBySessionID[sessionID] = 0
        bytesSentBySessionID[sessionID] = 0

        do {
            let desiredPTY = renderingCoordinator.sanitizedPTY(for: sessionID)
            let channel = try await LocalShellChannel.spawn(
                columns: desiredPTY.columns,
                rows: desiredPTY.rows,
                shellPath: resolvedShell,
                workingDirectory: workingDirectory
            )
            shellChannels[sessionID] = channel

            // Wire response handler so the parser can send CPR/DA responses
            // back through the shell channel.
            if let engine = engines[sessionID] {
                let shellRef: any SSHShellChannel = channel
                await engine.setResponseHandler { @Sendable bytes in
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
        reconnectCoordinator.applicationDidEnterBackground()
    }

    func applicationDidBecomeActive() {
        reconnectCoordinator.applicationDidBecomeActive()
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
        let engine = TerminalEngine(columns: PTYConfiguration.default.columns, rows: PTYConfiguration.default.rows, maxScrollbackLines: configuredScrollbackLines)
        await engine.setLineFeedMode(true)
        await configureHistoryTracking(for: session, engine: engine, shellIntegration: host.shellIntegration)
        engines[sessionID] = engine
        renderingCoordinator.initializePTY(for: sessionID)

        renderingCoordinator.gridSnapshotsBySessionID[sessionID] = await engine.snapshot()
        gridSnapshotNonceBySessionID[sessionID] = 0
        shellBuffers[sessionID] = []
        bellEventNonceBySessionID[sessionID] = 0
        inputModeSnapshotsBySessionID[sessionID] = await engine.inputModeSnapshot()
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
            reconnectCoordinator.removePendingForHost(host.id)

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
            keepaliveCoordinator.startIfNeeded()

            // Inject shell integration script for SSH sessions (Unix shell types only).
            // Uses compact single-line version to minimize terminal echo noise.
            if let script = ShellIntegrationScripts.sshInjectionScript(for: host.shellIntegration.type) {
                let sid = sessionID
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    await self?.sendRawShellInput(sessionID: sid, input: script + "\n")
                }
            }

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

        reconnectCoordinator.cancelPending(sessionID: sessionID)
        hostBySessionID.removeValue(forKey: sessionID)
        jumpHostBySessionID.removeValue(forKey: sessionID)

        if let pfm = portForwardingManager {
            await pfm.deactivateAll(for: sessionID)
        }

        if let shell = shellChannels[sessionID] {
            await shell.close()
        }
        if let completedBlock = await terminalHistoryIndex.flushActiveCommand(sessionID: sessionID, at: .now) {
            publishCommandCompletion(completedBlock)
        }
        finalizeRecordingIfNeeded(sessionID: sessionID)
        removeSessionArtifacts(sessionID: sessionID)

        if !session.isLocal {
            await transport.disconnect(sessionID: sessionID)
        }

        session.state = .disconnected
        session.endedAt = .now
        replaceSession(session)
        keepaliveCoordinator.stopIfIdle()

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
            await renderingCoordinator.appendShellLine("Session is not connected.", to: sessionID)
            return
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        guard let shell = shellChannels[sessionID] else {
            await renderingCoordinator.appendShellLine("Shell channel is not available.", to: sessionID)
            return
        }

        do {
            let payload = trimmed + "\n"
            try await shell.send(payload)
            lastActivityBySessionID[sessionID] = .now
            bytesSentBySessionID[sessionID, default: 0] += Int64(payload.utf8.count)
            sessionRecorder.recordInput(sessionID: sessionID, text: payload)
            await terminalHistoryIndex.recordCommandInput(
                sessionID: sessionID,
                command: trimmed,
                at: .now,
                source: .userInput
            )
        } catch {
            await renderingCoordinator.appendShellLine("Error: \(error.localizedDescription)", to: sessionID)
        }
    }

    func sendRawShellInput(sessionID: UUID, input: String) async {
        guard sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            await renderingCoordinator.appendShellLine("Session is not connected.", to: sessionID)
            return
        }

        guard let shell = shellChannels[sessionID] else {
            await renderingCoordinator.appendShellLine("Shell channel is not available.", to: sessionID)
            return
        }

        do {
            try await shell.send(input)
            bytesSentBySessionID[sessionID, default: 0] += Int64(input.utf8.count)
            sessionRecorder.recordInput(sessionID: sessionID, text: input)
            await terminalHistoryIndex.recordRawInput(
                sessionID: sessionID,
                input: input,
                at: .now
            )
        } catch {
            await renderingCoordinator.appendShellLine("Error: \(error.localizedDescription)", to: sessionID)
        }
    }

    // MARK: - F.6 PTY Resize (delegates to renderingCoordinator)

    func resizeTerminal(sessionID: UUID, columns: Int, rows: Int) async {
        await renderingCoordinator.resizeTerminal(sessionID: sessionID, columns: columns, rows: rows)
    }

    func clearShellBuffer(sessionID: UUID) {
        renderingCoordinator.clearShellBuffer(sessionID: sessionID)
    }

    // MARK: - Scrollback Navigation (delegates to renderingCoordinator)

    func scrollTerminal(sessionID: UUID, delta: Int) {
        renderingCoordinator.scrollTerminal(sessionID: sessionID, delta: delta)
    }

    func scrollToBottom(sessionID: UUID) {
        renderingCoordinator.scrollToBottom(sessionID: sessionID)
    }

    func isScrolledBack(sessionID: UUID) -> Bool {
        renderingCoordinator.isScrolledBack(sessionID: sessionID)
    }

    func gridSnapshot(for sessionID: UUID) -> GridSnapshot? {
        renderingCoordinator.gridSnapshot(for: sessionID)
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
            await renderingCoordinator.appendShellLine("[Recorder] Started session capture.", to: sessionID)
        } catch {
            await renderingCoordinator.appendShellLine("[Recorder] \(error.localizedDescription)", to: sessionID)
        }
    }

    func stopRecording(sessionID: UUID) async {
        do {
            let recordingURL = try sessionRecorder.stopRecording(sessionID: sessionID)
            isRecordingBySessionID[sessionID] = false
            hasRecordingBySessionID[sessionID] = true
            latestRecordingURLBySessionID[sessionID] = recordingURL
            await renderingCoordinator.appendShellLine("[Recorder] Saved encrypted recording: \(recordingURL.lastPathComponent)", to: sessionID)
        } catch {
            await renderingCoordinator.appendShellLine("[Recorder] \(error.localizedDescription)", to: sessionID)
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
            await renderingCoordinator.appendShellLine("[Recorder] Playback started (\(String(format: "%.1fx", speed))).", to: sessionID)
            try await sessionRecorder.playLatestRecording(sessionID: sessionID, speed: speed) { [weak self] step in
                await self?.renderingCoordinator.applyPlaybackStep(step, to: sessionID)
            }
            await renderingCoordinator.appendShellLine("[Recorder] Playback finished.", to: sessionID)
        } catch {
            await renderingCoordinator.appendShellLine("[Recorder] Playback failed: \(error.localizedDescription)", to: sessionID)
        }
    }

    func exportLastRecordingAsCast(sessionID: UUID, columns: Int = 80, rows: Int = 24) async {
        do {
            let castURL = try sessionRecorder.exportLatestRecordingAsCast(
                sessionID: sessionID,
                columns: columns,
                rows: rows
            )
            await renderingCoordinator.appendShellLine("[Recorder] Exported .cast: \(castURL.path(percentEncoded: false))", to: sessionID)
        } catch {
            await renderingCoordinator.appendShellLine("[Recorder] Export failed: \(error.localizedDescription)", to: sessionID)
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

    func recentCommandBlocks(sessionID: UUID, limit: Int = 20) async -> [CommandBlock] {
        await terminalHistoryIndex.recentCommands(sessionID: sessionID, limit: limit)
    }

    func searchCommandHistory(sessionID: UUID, query: String, limit: Int = 20) async -> [CommandBlock] {
        await terminalHistoryIndex.searchCommands(sessionID: sessionID, query: query, limit: limit)
    }

    func commandOutput(sessionID: UUID, blockID: UUID) async -> String? {
        await terminalHistoryIndex.commandOutput(sessionID: sessionID, blockID: blockID)
    }

    func executeCommandAndWait(
        sessionID: UUID,
        command: String,
        timeoutSeconds: TimeInterval = 30
    ) async -> CommandExecutionResult {
        let marker = "__PROSSH_CMD_WAIT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let wrappedCommand = "{ \(command); __prossh_s=$?; printf '\\n\(marker):%s\\n' \"$__prossh_s\"; }"

        guard sessions.contains(where: { $0.id == sessionID && $0.state == .connected }),
              let shell = shellChannels[sessionID] else {
            return CommandExecutionResult(output: "Session is not connected.", exitCode: nil, timedOut: false, blockID: nil)
        }

        do {
            let payload = wrappedCommand + "\n"
            try await shell.send(payload)
            lastActivityBySessionID[sessionID] = .now
            bytesSentBySessionID[sessionID, default: 0] += Int64(payload.utf8.count)
            sessionRecorder.recordInput(sessionID: sessionID, text: payload)
            await terminalHistoryIndex.recordCommandInput(
                sessionID: sessionID,
                command: wrappedCommand,
                at: .now,
                source: .userInput
            )
        } catch {
            return CommandExecutionResult(output: "Error sending command: \(error.localizedDescription)", exitCode: nil, timedOut: false, blockID: nil)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let blocks = await terminalHistoryIndex.searchCommands(
                sessionID: sessionID,
                query: marker,
                limit: 8
            )
            if let block = blocks.first(where: { $0.output.contains(marker) }) {
                let parsed = parseWrappedCommandOutput(block.output, marker: marker)
                return CommandExecutionResult(
                    output: parsed.output,
                    exitCode: parsed.exitCode,
                    timedOut: false,
                    blockID: block.id
                )
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return CommandExecutionResult(output: "", exitCode: nil, timedOut: true, blockID: nil)
    }

    private func parseWrappedCommandOutput(_ output: String, marker: String) -> (output: String, exitCode: Int?) {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let markerPrefix = "\(marker):"
        guard let markerRange = normalized.range(of: markerPrefix, options: .backwards) else {
            return (normalized.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let statusStart = markerRange.upperBound
        let statusSlice = normalized[statusStart...]
        let statusValue = statusSlice.prefix { $0.isNumber || $0 == "-" }
        let exitCode = Int(statusValue)
        let cleanOutput = normalized[..<markerRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(cleanOutput), exitCode)
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
        let desiredPTY = renderingCoordinator.sanitizedPTY(for: session.id)
        let channel = try await transport.openShell(
            sessionID: session.id,
            pty: desiredPTY,
            enableAgentForwarding: session.usesAgentForwarding
        )
        shellChannels[session.id] = channel

        // Wire response handler so the parser can send CPR/DA responses
        // back through the shell channel.
        if let engine = engines[session.id] {
            let shellRef: any SSHShellChannel = channel
            await engine.setResponseHandler { @Sendable bytes in
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

    private func configureHistoryTracking(for session: Session, engine: TerminalEngine,
                                          shellIntegration: ShellIntegrationConfig = .init()) async {
        let historyIndex = terminalHistoryIndex
        await historyIndex.registerSession(
            sessionID: session.id,
            username: session.username,
            hostname: session.hostname,
            shellIntegration: shellIntegration
        )
        await engine.setSemanticPromptEventHandler { [weak self] event in
            let completedBlock = await historyIndex.recordSemanticEvent(
                sessionID: session.id,
                event: event
            )
            if let completedBlock {
                await self?.publishCommandCompletion(completedBlock)
            }
        }
    }

    private func startParserReader(for sessionID: UUID, rawOutput: AsyncStream<Data>) {
        parserReaderTasks[sessionID]?.cancel()
        guard let engine = engines[sessionID] else {
            return
        }

        parserReaderTasks[sessionID] = Task.detached(priority: .userInitiated) { [weak self] in
            for await chunk in rawOutput {
                if Task.isCancelled {
                    break
                }
                await engine.feed(chunk)
                await self?.recordParsedChunk(sessionID: sessionID, chunk: chunk)

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
                if let syncExitSnap = await engine.consumeSyncExitSnapshot() {
                    await self?.renderingCoordinator.publishSyncExitSnapshot(
                        sessionID: sessionID,
                        engine: engine,
                        snapshotOverride: syncExitSnap
                    )
                }

                let inSyncMode = await engine.synchronizedOutput
                if inSyncMode { continue }

                // Auto-reset scroll offset when new output arrives.
                await self?.renderingCoordinator.scheduleParsedChunkPublish(
                    sessionID: sessionID,
                    engine: engine
                )
            }

            await self?.renderingCoordinator.flushPendingSnapshotPublishIfNeeded(
                for: sessionID,
                engine: engine
            )

            // Stream ended — force-exit alternate buffer if the program
            // crashed or exited without sending ESC[?1049l. This prevents
            // alternate screen content from leaking into the primary buffer.
            if await engine.usingAlternateBuffer {
                await engine.disableAlternateBuffer()
                await self?.renderingCoordinator.publishGridState(for: sessionID, engine: engine)
            }

            // Detect disconnection.
            if !Task.isCancelled {
                await self?.handleShellStreamEndedInternal(sessionID: sessionID)
            }
        }
    }

    private func recordParsedChunk(sessionID: UUID, chunk: Data) async {
        lastActivityBySessionID[sessionID] = .now
        bytesReceivedBySessionID[sessionID, default: 0] += Int64(chunk.count)
        await terminalHistoryIndex.recordOutputChunk(
            sessionID: sessionID,
            data: chunk,
            at: .now
        )

        // Capture output directly as bytes to avoid a per-chunk UTF-8 decode.
        if sessionRecorder.isRecording(sessionID: sessionID) {
            // Sync coalescing state with throughput mode policy.
            if sessionRecorder.coalescingEnabled != throughputModeEnabled {
                sessionRecorder.coalescingEnabled = throughputModeEnabled
            }
            sessionRecorder.recordOutputData(sessionID: sessionID, data: chunk)
        }
    }

    func handleShellStreamEndedInternal(sessionID: UUID) async {
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
            if let completedBlock = await terminalHistoryIndex.flushActiveCommand(sessionID: sessionID, at: .now) {
                publishCommandCompletion(completedBlock)
            }
            finalizeRecordingIfNeeded(sessionID: sessionID)
            removeSessionArtifacts(sessionID: sessionID)
            return
        }

        session.state = .disconnected
        session.endedAt = .now
        session.errorMessage = "Connection lost. Reconnecting when network is available."
        replaceSession(session)
        keepaliveCoordinator.stopIfIdle()

        let host = hostBySessionID[sessionID]
        let jumpHost = jumpHostBySessionID[sessionID]

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

        if let completedBlock = await terminalHistoryIndex.flushActiveCommand(sessionID: sessionID, at: .now) {
            publishCommandCompletion(completedBlock)
        }
        finalizeRecordingIfNeeded(sessionID: sessionID)
        removeSessionArtifacts(sessionID: sessionID)
        await transport.disconnect(sessionID: sessionID)
        reconnectCoordinator.scheduleReconnect(for: sessionID, host: host, jumpHost: jumpHost)
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
        reconnectCoordinator.cancelPending(sessionID: sessionID)
        hostBySessionID.removeValue(forKey: sessionID)
        jumpHostBySessionID.removeValue(forKey: sessionID)
        sessions.removeAll(where: { $0.id == sessionID })
        finalizeRecordingIfNeeded(sessionID: sessionID)
        hasRecordingBySessionID.removeValue(forKey: sessionID)
        latestRecordingURLBySessionID.removeValue(forKey: sessionID)
        removeSessionArtifacts(sessionID: sessionID)
        Task { [terminalHistoryIndex] in
            await terminalHistoryIndex.removeSession(sessionID: sessionID)
        }
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
        renderingCoordinator.cleanupSession(sessionID)
        shellChannels.removeValue(forKey: sessionID)
        engines.removeValue(forKey: sessionID)
        shellBuffers.removeValue(forKey: sessionID)
        bellEventNonceBySessionID.removeValue(forKey: sessionID)
        inputModeSnapshotsBySessionID.removeValue(forKey: sessionID)
        gridSnapshotNonceBySessionID.removeValue(forKey: sessionID)
        isRecordingBySessionID[sessionID] = false
        isPlaybackRunningBySessionID[sessionID] = false
        workingDirectoryBySessionID.removeValue(forKey: sessionID)
        bytesReceivedBySessionID.removeValue(forKey: sessionID)
        bytesSentBySessionID.removeValue(forKey: sessionID)
        latestCompletedCommandBlockBySessionID.removeValue(forKey: sessionID)
        commandCompletionNonceBySessionID.removeValue(forKey: sessionID)
        latestPublishedCommandBlockIDBySessionID.removeValue(forKey: sessionID)
    }

    func publishCommandCompletion(_ block: CommandBlock) {
        let sessionID = block.sessionID
        if latestPublishedCommandBlockIDBySessionID[sessionID] == block.id {
            return
        }

        latestPublishedCommandBlockIDBySessionID[sessionID] = block.id
        latestCompletedCommandBlockBySessionID[sessionID] = block
        commandCompletionNonceBySessionID[sessionID, default: 0] += 1
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

    // MARK: - Screenshot Mode Support

    func injectScreenshotSessions() async {
        let sampleSessions = ScreenshotSampleData.sessions
        sessions = sampleSessions

        for session in sampleSessions {
            let engine = TerminalEngine(
                columns: 80, rows: 24,
                maxScrollbackLines: 1000
            )
            await engine.setLineFeedMode(true)
            await configureHistoryTracking(for: session, engine: engine)
            engines[session.id] = engine

            renderingCoordinator.initializePTY(for: session.id)
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
                await engine.feed(data)
            }

            let snapshot = await engine.snapshot()
            renderingCoordinator.gridSnapshotsBySessionID[session.id] = snapshot
            gridSnapshotNonceBySessionID[session.id] = 1
            inputModeSnapshotsBySessionID[session.id] = await engine.inputModeSnapshot()
            shellBuffers[session.id] = await engine.visibleText()
        }
    }
}
