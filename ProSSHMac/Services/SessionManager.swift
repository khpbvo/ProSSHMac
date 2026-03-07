// swiftlint:disable file_length
import Foundation
import Combine
import Network

/// Reactive scroll position state for the terminal scrollbar overlay.
struct TerminalScrollState: Equatable {
    var scrollOffset: Int = 0
    var scrollbackCount: Int = 0
    var visibleRows: Int = 24
}

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
    @Published var bytesReceivedBySessionID: [UUID: Int64] = [:]
    @Published var bytesSentBySessionID: [UUID: Int64] = [:]
    @Published var latestCompletedCommandBlockBySessionID: [UUID: CommandBlock] = [:]
    @Published var commandCompletionNonceBySessionID: [UUID: Int] = [:]
    @Published var scrollStateBySessionID: [UUID: TerminalScrollState] = [:]

    let transport: any SSHTransporting
    private let knownHostsStore: any KnownHostsStoreProtocol
    private let auditLogManager: AuditLogManager?
    private let portForwardingManager: PortForwardingManager?
    private let totpStore: TOTPStore?
    let terminalHistoryIndex = TerminalHistoryIndex()
    var shellChannels: [UUID: any SSHShellChannel] = [:]
    var engines: [UUID: TerminalEngine] = [:]
    var hostBySessionID: [UUID: Host] = [:]
    var lastActivityBySessionID: [UUID: Date] = [:]
    var jumpHostBySessionID: [UUID: Host] = [:]
    var manuallyDisconnectingSessions: Set<UUID> = []
    let reconnectCoordinator: SessionReconnectCoordinator
    let keepaliveCoordinator: SessionKeepaliveCoordinator
    let renderingCoordinator: TerminalRenderingCoordinator
    let recordingCoordinator: SessionRecordingCoordinator
    let sftpCoordinator: SessionSFTPCoordinator
    let aiToolCoordinator: SessionAIToolCoordinator
    let shellIOCoordinator: SessionShellIOCoordinator
    var latestPublishedCommandBlockIDBySessionID: [UUID: UUID] = [:]

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
        totpStore: TOTPStore? = nil
    ) {
        self.transport = transport
        self.knownHostsStore = knownHostsStore
        self.auditLogManager = auditLogManager
        self.portForwardingManager = portForwardingManager
        self.totpStore = totpStore
        let coord = SessionReconnectCoordinator()
        self.reconnectCoordinator = coord
        self.keepaliveCoordinator = SessionKeepaliveCoordinator()
        let renderCoord = TerminalRenderingCoordinator()
        self.renderingCoordinator = renderCoord
        let recordCoord = SessionRecordingCoordinator()
        self.recordingCoordinator = recordCoord
        let sftpCoord = SessionSFTPCoordinator()
        self.sftpCoordinator = sftpCoord
        let aiToolCoord = SessionAIToolCoordinator()
        self.aiToolCoordinator = aiToolCoord
        let shellIOCoord = SessionShellIOCoordinator()
        self.shellIOCoordinator = shellIOCoord

        Task { @MainActor [weak self] in
            await self?.refreshKnownHosts()
        }

        coord.manager = self
        coord.start()
        keepaliveCoordinator.manager = self
        renderCoord.manager = self
        recordCoord.manager = self
        sftpCoord.manager = self
        aiToolCoord.manager = self
        shellIOCoord.manager = self
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

            shellIOCoordinator.startParserReader(for: sessionID, rawOutput: channel.rawOutput)

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
        renderingCoordinator.applicationDidBecomeInactive()
        reconnectCoordinator.applicationDidEnterBackground()
    }

    func applicationDidBecomeActive() {
        reconnectCoordinator.applicationDidBecomeActive()
        Task { @MainActor [weak self] in
            await self?.renderingCoordinator.applicationDidBecomeActive()
        }
    }

    func applicationDidBecomeInactive() {
        renderingCoordinator.applicationDidBecomeInactive()
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

            var effectivePasswordOverride = passwordOverride
            if host.authMethod == .keyboardInteractive,
               let config = host.totpConfiguration,
               let secret = try? await totpStore?.retrieveSecret(forHostID: host.id) {
                let result = TOTPGenerator().generateSmartCode(secret: secret, configuration: config)
                effectivePasswordOverride = result.code
                await auditLogManager?.record(
                    category: .authentication,
                    action: "TOTP 2FA auto-fill",
                    outcome: .info,
                    host: host,
                    sessionID: sessionID,
                    details: "Code valid for \(result.secondsRemaining)s, issuer: \(config.issuer ?? "unknown")"
                )
            }

            try await transport.authenticate(sessionID: sessionID, to: host, passwordOverride: effectivePasswordOverride, keyPassphraseOverride: keyPassphraseOverride)

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
        recordingCoordinator.finalizeIfNeeded(sessionID: sessionID)
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
        await shellIOCoordinator.sendShellInput(sessionID: sessionID, input: input, suppressEcho: suppressEcho)
    }

    func sendRawShellInput(sessionID: UUID, input: String) async {
        await shellIOCoordinator.sendRawShellInput(sessionID: sessionID, input: input)
    }

    func sendRawShellInputBytes(
        sessionID: UUID,
        bytes: [UInt8],
        source: RawShellInputSource = .programmatic,
        eventType: String = "unknown"
    ) async {
        await shellIOCoordinator.sendRawShellInputBytes(
            sessionID: sessionID,
            bytes: bytes,
            source: source,
            eventType: eventType
        )
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

    func scrollToRow(sessionID: UUID, row: Int) {
        renderingCoordinator.scrollToRow(sessionID: sessionID, row: row)
    }

    func cachedScrollbackCount(for sessionID: UUID) -> Int {
        renderingCoordinator.cachedScrollbackCountBySessionID[sessionID] ?? 0
    }

    func gridSnapshot(for sessionID: UUID) -> GridSnapshot? {
        renderingCoordinator.gridSnapshot(for: sessionID)
    }

    // MARK: - Recording (delegates to recordingCoordinator)

    func toggleRecording(sessionID: UUID) async {
        await recordingCoordinator.toggleRecording(sessionID: sessionID)
    }

    func startRecording(sessionID: UUID) async {
        await recordingCoordinator.startRecording(sessionID: sessionID)
    }

    func stopRecording(sessionID: UUID) async {
        await recordingCoordinator.stopRecording(sessionID: sessionID)
    }

    func playLastRecording(sessionID: UUID, speed: Double) async {
        await recordingCoordinator.playLastRecording(sessionID: sessionID, speed: speed)
    }

    func exportLastRecordingAsCast(sessionID: UUID, columns: Int = 80, rows: Int = 24) async {
        await recordingCoordinator.exportLastRecordingAsCast(sessionID: sessionID, columns: columns, rows: rows)
    }

    func listRemoteDirectory(sessionID: UUID, path: String) async throws -> [SFTPDirectoryEntry] {
        try await sftpCoordinator.listRemoteDirectory(sessionID: sessionID, path: path)
    }

    func uploadFile(sessionID: UUID, localPath: String, remotePath: String) async throws -> SFTPTransferResult {
        try await sftpCoordinator.uploadFile(sessionID: sessionID, localPath: localPath, remotePath: remotePath)
    }

    func uploadFile(sessionID: UUID, localPath: String, remotePath: String, progressHandler: (@Sendable (Int64, Int64) -> Void)?) async throws -> SFTPTransferResult {
        try await sftpCoordinator.uploadFile(sessionID: sessionID, localPath: localPath, remotePath: remotePath, progressHandler: progressHandler)
    }

    func downloadFile(sessionID: UUID, remotePath: String, localPath: String) async throws -> SFTPTransferResult {
        try await sftpCoordinator.downloadFile(sessionID: sessionID, remotePath: remotePath, localPath: localPath)
    }

    func downloadFile(sessionID: UUID, remotePath: String, localPath: String, progressHandler: (@Sendable (Int64, Int64) -> Void)?) async throws -> SFTPTransferResult {
        try await sftpCoordinator.downloadFile(sessionID: sessionID, remotePath: remotePath, localPath: localPath, progressHandler: progressHandler)
    }

    func executeCommandAndWait(
        sessionID: UUID,
        command: String,
        timeoutSeconds: TimeInterval = 30
    ) async -> CommandExecutionResult {
        await aiToolCoordinator.executeCommandAndWait(sessionID: sessionID, command: command, timeoutSeconds: timeoutSeconds)
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

        shellIOCoordinator.startParserReader(for: session.id, rawOutput: channel.rawOutput)
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
            recordingCoordinator.finalizeIfNeeded(sessionID: sessionID)
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
        recordingCoordinator.finalizeIfNeeded(sessionID: sessionID)
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
        recordingCoordinator.finalizeIfNeeded(sessionID: sessionID)
        hasRecordingBySessionID.removeValue(forKey: sessionID)
        latestRecordingURLBySessionID.removeValue(forKey: sessionID)
        removeSessionArtifacts(sessionID: sessionID)
        Task { [terminalHistoryIndex] in
            await terminalHistoryIndex.removeSession(sessionID: sessionID)
        }
    }

    private func removeSessionArtifacts(sessionID: UUID) {
        shellIOCoordinator.cancelParserTask(for: sessionID)
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
        scrollStateBySessionID.removeValue(forKey: sessionID)
    }

    func publishCommandCompletion(_ block: CommandBlock) {
        aiToolCoordinator.publishCommandCompletion(block)
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
