// Extracted from SessionManager.swift
import Foundation
#if DEBUG
import os.signpost
#endif

@MainActor final class TerminalRenderingCoordinator {
    private enum PublishDebounceMode {
        case none
        case alternateBuffer
        case promptRedraw
        case synchronizedOutput

        var requiresDebounce: Bool {
            self != .none
        }
    }

    weak var manager: SessionManager?

    // MARK: - Private rendering state (all moved from SessionManager)

    var gridSnapshotsBySessionID: [UUID: GridSnapshot] = [:]
    var pendingSnapshotPublishTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    /// First-scheduled timestamp for the current pending publish, used to cap debounce deferral.
    private var pendingSnapshotPublishStartedAtBySessionID: [UUID: Date] = [:]
    /// Per-session scroll offset (0 = live view, >0 = scrolled back N lines).
    var scrollOffsetBySessionID: [UUID: Int] = [:]
    /// Whether incoming output should preserve the current scrolled-back viewport.
    /// Enabled when user scrolls up, disabled when user scrolls toward live output.
    var preserveScrollAnchorBySessionID: [UUID: Bool] = [:]
    /// Cached scrollback count per session, updated on each scroll for bounds clamping.
    var cachedScrollbackCountBySessionID: [UUID: Int] = [:]
    /// Throttles expensive visible-text extraction/publishing during heavy output.
    var lastShellBufferPublishAtBySessionID: [UUID: Date] = [:]
    /// Tracks last bell event time per session for throughput mode rate-limiting.
    var lastBellTimeBySessionID: [UUID: Date] = [:]
    var pendingResizeTasks: [UUID: Task<Void, Never>] = [:]
    var desiredPTYBySessionID: [UUID: PTYConfiguration] = [:]

    /// Number of publish requests received in the current burst window per session.
    private var burstCountBySessionID: [UUID: Int] = [:]
    /// Start timestamp of the current burst window per session.
    private var burstWindowStartBySessionID: [UUID: Date] = [:]
    /// Whether auto-burst mode is active per session (true = use throughput intervals).
    private var autoBurstModeBySessionID: [UUID: Bool] = [:]
    /// Pending revert task — fires 200ms after the last publish request.
    private var burstRevertTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    /// When true, parsed output continues updating terminal state but UI snapshot publishes are deferred.
    private var isPublishingSuspended = false
    /// Sessions that received output while publishing was suspended and need one catch-up publish on resume.
    private var suspendedDirtySessionIDs: Set<UUID> = []
    /// Tracks sessions currently inside publishGridState so follow-up requests can collapse to latest state only.
    private var publishInFlightSessionIDs: Set<UUID> = []
    /// Sticky bit for "another publish is needed after the current one finishes".
    private var followUpPublishRequestedSessionIDs: Set<UUID> = []
    /// Snapshot override that must win over a later live re-snapshot when a
    /// publish request arrives while another publish is still in flight.
    private var pendingSnapshotOverridesBySessionID: [UUID: GridSnapshot] = [:]
    /// Snapshot override for a queued debounce task that should publish a
    /// captured frame instead of re-snapshotting from the engine later.
    private var pendingScheduledSnapshotOverridesBySessionID: [UUID: GridSnapshot] = [:]
    /// Force the next post-sync live publish to upload a full snapshot so
    /// stale rows from a prior synchronized frame cannot survive on the GPU.
    private var forceFullSnapshotNextPublishBySessionID: Set<UUID> = []
    /// Sessions currently redrawing a shell prompt after OSC 133 prompt/command-end markers.
    private var promptRedrawPendingSessionIDs: Set<UUID> = []
    #if DEBUG
    /// Deterministic test hook: queue one follow-up snapshot immediately after the
    /// next publish iteration for the given session.
    private var testingInjectedFollowUpSnapshotBySessionID: [UUID: GridSnapshot] = [:]
    #endif

    private let shellBufferPublishInterval: TimeInterval = 1.0 / 30.0
    private let throughputShellBufferPublishInterval: TimeInterval = 1.0 / 5.0
    private let snapshotPublishInterval: Duration = .milliseconds(8)
    private let throughputSnapshotPublishInterval: Duration = .milliseconds(16)
    private let alternateBufferSnapshotPublishInterval: Duration = .milliseconds(16)
    private let promptRedrawSnapshotPublishInterval: Duration = .milliseconds(24)
    private let synchronizedOutputSnapshotPublishInterval: Duration = .milliseconds(40)
    private let alternateBufferMaxPublishDeferral: TimeInterval = 0.050
    private let promptRedrawMaxPublishDeferral: TimeInterval = 0.050
    private let synchronizedOutputMaxPublishDeferral: TimeInterval = 0.250
    private let burstWindowDuration: TimeInterval = 0.016  // 16ms
    private let burstThreshold = 3                         // requests within window to activate
    private let burstRevertDelay: Duration = .milliseconds(200)

    #if DEBUG
    private let perfSignpostLog = OSLog(subsystem: "com.prossh", category: "TerminalPerf")
    private var _dbgPublishCount = 0
    private var _dbgWindowStart = Date.now
    #endif

    init() {}

    nonisolated deinit {}

    // MARK: - PTY initialization / cleanup

    func initializePTY(for sessionID: UUID) {
        desiredPTYBySessionID[sessionID] = .default
    }

    func sanitizedPTY(for sessionID: UUID) -> PTYConfiguration {
        let current = desiredPTYBySessionID[sessionID] ?? .default
        return PTYConfiguration(
            columns: max(10, current.columns),
            rows: max(4, current.rows),
            terminalType: current.terminalType
        )
    }

    func cleanupSession(_ sessionID: UUID) {
        pendingResizeTasks[sessionID]?.cancel()
        pendingResizeTasks.removeValue(forKey: sessionID)
        cancelPendingSnapshotPublish(for: sessionID)
        desiredPTYBySessionID.removeValue(forKey: sessionID)
        lastShellBufferPublishAtBySessionID.removeValue(forKey: sessionID)
        lastBellTimeBySessionID.removeValue(forKey: sessionID)
        pendingSnapshotPublishStartedAtBySessionID.removeValue(forKey: sessionID)
        scrollOffsetBySessionID.removeValue(forKey: sessionID)
        preserveScrollAnchorBySessionID.removeValue(forKey: sessionID)
        cachedScrollbackCountBySessionID.removeValue(forKey: sessionID)
        gridSnapshotsBySessionID.removeValue(forKey: sessionID)
        burstCountBySessionID.removeValue(forKey: sessionID)
        burstWindowStartBySessionID.removeValue(forKey: sessionID)
        autoBurstModeBySessionID.removeValue(forKey: sessionID)
        burstRevertTasksBySessionID[sessionID]?.cancel()
        burstRevertTasksBySessionID.removeValue(forKey: sessionID)
        suspendedDirtySessionIDs.remove(sessionID)
        publishInFlightSessionIDs.remove(sessionID)
        followUpPublishRequestedSessionIDs.remove(sessionID)
        pendingSnapshotOverridesBySessionID.removeValue(forKey: sessionID)
        pendingScheduledSnapshotOverridesBySessionID.removeValue(forKey: sessionID)
        forceFullSnapshotNextPublishBySessionID.remove(sessionID)
        promptRedrawPendingSessionIDs.remove(sessionID)
    }

    // MARK: - App lifecycle

    func applicationDidBecomeInactive() {
        guard !isPublishingSuspended else { return }
        isPublishingSuspended = true

        for sessionID in pendingSnapshotPublishTasksBySessionID.keys {
            suspendedDirtySessionIDs.insert(sessionID)
        }

        for sessionID in Array(pendingSnapshotPublishTasksBySessionID.keys) {
            cancelPendingSnapshotPublish(for: sessionID)
        }

        resetBurstState()
    }

    func applicationDidBecomeActive() async {
        let wasSuspended = isPublishingSuspended
        isPublishingSuspended = false
        resetBurstState()

        guard wasSuspended, let manager else { return }
        let sessionIDs = Array(suspendedDirtySessionIDs)
        suspendedDirtySessionIDs.removeAll()

        for sessionID in sessionIDs {
            guard let engine = manager.engines[sessionID] else { continue }
            lastShellBufferPublishAtBySessionID.removeValue(forKey: sessionID)
            await publishLatestGridState(for: sessionID, engine: engine)
        }
    }

    // MARK: - Resize

    func resizeTerminal(sessionID: UUID, columns: Int, rows: Int) async {
        guard let manager else { return }
        guard columns >= 10, rows >= 4 else { return }

        desiredPTYBySessionID[sessionID] = PTYConfiguration(
            columns: columns,
            rows: rows,
            terminalType: PTYConfiguration.default.terminalType
        )

        if let engine = manager.engines[sessionID] {
            await engine.resize(newColumns: columns, newRows: rows)
            let snapshot = await engine.snapshot()
            gridSnapshotsBySessionID[sessionID] = snapshot
            manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
            cachedScrollbackCountBySessionID[sessionID] = await engine.scrollbackCount
        }

        pendingResizeTasks[sessionID]?.cancel()
        pendingResizeTasks[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard let self, let manager = self.manager,
                  let shell = manager.shellChannels[sessionID] else { return }
            do {
                try await shell.resizePTY(columns: columns, rows: rows)
            } catch {
                // Non-fatal: log but don't surface to user.
            }
            self.pendingResizeTasks.removeValue(forKey: sessionID)
        }
    }

    // MARK: - Shell buffer

    func clearShellBuffer(sessionID: UUID) {
        guard let manager, let engine = manager.engines[sessionID] else { return }
        Task { @MainActor [weak self] in
            guard let self, let manager = self.manager else { return }
            await engine.eraseInDisplay(mode: 3)
            await engine.moveCursorTo(row: 0, col: 0)
            let snapshot = await engine.snapshot()
            self.gridSnapshotsBySessionID[sessionID] = snapshot
            manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
            manager.shellBuffers[sessionID] = await engine.visibleText()
        }
    }

    // MARK: - Scrollback navigation

    func scrollTerminal(sessionID: UUID, delta: Int) {
        guard let manager, let engine = manager.engines[sessionID] else { return }
        Task { @MainActor [weak self] in
            guard let self, let manager = self.manager else { return }
            let current = self.scrollOffsetBySessionID[sessionID, default: 0]
            let maxOffset = await engine.scrollbackCount
            self.cachedScrollbackCountBySessionID[sessionID] = maxOffset
            let newOffset = max(0, min(current + delta, maxOffset))
            self.scrollOffsetBySessionID[sessionID] = newOffset
            if newOffset == 0 {
                self.preserveScrollAnchorBySessionID[sessionID] = false
            } else if delta > 0 {
                // Scrolling up means "hold this viewport while output arrives".
                self.preserveScrollAnchorBySessionID[sessionID] = true
            } else if delta < 0 {
                // Scrolling down means user is heading toward live output.
                self.preserveScrollAnchorBySessionID[sessionID] = false
            }
            let snapshot = await engine.snapshot(scrollOffset: newOffset)
            self.gridSnapshotsBySessionID[sessionID] = snapshot
            manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
            self.publishScrollState(sessionID: sessionID, scrollOffset: newOffset, scrollbackCount: maxOffset)
        }
    }

    func scrollToRow(sessionID: UUID, row: Int) {
        guard let manager, let engine = manager.engines[sessionID] else { return }
        Task { @MainActor [weak self] in
            guard let self, let manager = self.manager else { return }
            let maxOffset = await engine.scrollbackCount
            self.cachedScrollbackCountBySessionID[sessionID] = maxOffset
            let clampedRow = max(0, min(row, maxOffset))
            let previousOffset = self.scrollOffsetBySessionID[sessionID, default: 0]
            self.scrollOffsetBySessionID[sessionID] = clampedRow
            if clampedRow == 0 {
                self.preserveScrollAnchorBySessionID[sessionID] = false
            } else if clampedRow > previousOffset {
                self.preserveScrollAnchorBySessionID[sessionID] = true
            } else if clampedRow < previousOffset {
                self.preserveScrollAnchorBySessionID[sessionID] = false
            }
            let snapshot = await engine.snapshot(scrollOffset: clampedRow)
            self.gridSnapshotsBySessionID[sessionID] = snapshot
            manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
            self.publishScrollState(sessionID: sessionID, scrollOffset: clampedRow, scrollbackCount: maxOffset)
        }
    }

    func scrollToBottom(sessionID: UUID) {
        guard let manager, let engine = manager.engines[sessionID] else { return }
        scrollOffsetBySessionID[sessionID] = 0
        preserveScrollAnchorBySessionID[sessionID] = false
        Task { @MainActor [weak self] in
            guard let self, let manager = self.manager else { return }
            let snapshot = await engine.snapshot()
            self.gridSnapshotsBySessionID[sessionID] = snapshot
            manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
            let scrollbackCount = await engine.scrollbackCount
            self.cachedScrollbackCountBySessionID[sessionID] = scrollbackCount
            self.publishScrollState(sessionID: sessionID, scrollOffset: 0, scrollbackCount: scrollbackCount)
        }
    }

    func isScrolledBack(sessionID: UUID) -> Bool {
        (scrollOffsetBySessionID[sessionID] ?? 0) > 0
    }

    func gridSnapshot(for sessionID: UUID) -> GridSnapshot? {
        gridSnapshotsBySessionID[sessionID]
    }

    // MARK: - Shell line injection

    func appendShellLine(_ line: String, to sessionID: UUID) async {
        guard let manager, let engine = manager.engines[sessionID] else { return }
        var bytes: [UInt8] = [0x18] // CAN — returns parser to ground state
        bytes.append(contentsOf: Array(("\r\n" + line + "\r\n").utf8))
        let data = Data(bytes)
        let didProcess = await engine.feed(data)
        if didProcess {
            let snapshot = await engine.snapshot()
            gridSnapshotsBySessionID[sessionID] = snapshot
            manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
            manager.shellBuffers[sessionID] = await engine.visibleText()
        }
    }

    // MARK: - Playback

    func applyPlaybackStep(_ step: SessionPlaybackStep, to sessionID: UUID) async {
        guard let manager else { return }
        guard step.stream == .output else { return }
        guard let engine = manager.engines[sessionID] else { return }
        let data = Data(step.text.utf8)
        let didProcess = await engine.feed(data)
        if didProcess {
            let snapshot = await engine.snapshot()
            gridSnapshotsBySessionID[sessionID] = snapshot
            manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
            manager.shellBuffers[sessionID] = await engine.visibleText()
        }
    }

    // MARK: - Snapshot publishing pipeline

    func publishSyncExitSnapshot(
        sessionID: UUID,
        engine: TerminalEngine,
        snapshotOverride: GridSnapshot
    ) async {
        await publishSyncExitSnapshots(
            sessionID: sessionID,
            engine: engine,
            snapshotOverrides: [snapshotOverride]
        )
    }

    func publishSyncExitSnapshots(
        sessionID: UUID,
        engine: TerminalEngine,
        snapshotOverrides: [GridSnapshot]
    ) async {
        guard let latestSnapshotOverride = snapshotOverrides.last else { return }
        scrollOffsetBySessionID[sessionID] = 0
        preserveScrollAnchorBySessionID[sessionID] = false
        forceFullSnapshotNextPublishBySessionID.insert(sessionID)
        cancelPendingSnapshotPublish(for: sessionID)
        await publishLatestGridState(
            for: sessionID,
            engine: engine,
            snapshotOverride: latestSnapshotOverride
        )
    }

    func refreshInputModeSnapshot(
        sessionID: UUID,
        engine: TerminalEngine
    ) async {
        guard let manager else { return }
        manager.inputModeSnapshotsBySessionID[sessionID] = await engine.inputModeSnapshot()
    }

    func scheduleParsedChunkPublish(
        sessionID: UUID,
        engine: TerminalEngine
    ) async {
        let debounceMode: PublishDebounceMode
        if await engine.usingAlternateBuffer {
            debounceMode = .alternateBuffer
        } else if promptRedrawPendingSessionIDs.contains(sessionID) {
            debounceMode = .promptRedraw
        } else {
            debounceMode = .none
        }
        scheduleCoalescedGridPublish(
            for: sessionID,
            engine: engine,
            debounceMode: debounceMode
        )
    }

    func scheduleSynchronizedOutputFallbackPublish(
        sessionID: UUID,
        engine: TerminalEngine,
        snapshotOverride: GridSnapshot
    ) {
        scheduleCoalescedGridPublish(
            for: sessionID,
            engine: engine,
            debounceMode: .synchronizedOutput,
            snapshotOverride: snapshotOverride
        )
    }

    func noteSemanticPromptEvent(sessionID: UUID, event: SemanticPromptEvent) {
        switch event {
        case .promptStart, .commandEnd:
            promptRedrawPendingSessionIDs.insert(sessionID)
        case .commandStart:
            promptRedrawPendingSessionIDs.remove(sessionID)
        case .promptEnd:
            break
        }
    }

    func flushPendingSnapshotPublishIfNeeded(
        for sessionID: UUID,
        engine: TerminalEngine
    ) async {
        if isPublishingSuspended {
            suspendedDirtySessionIDs.insert(sessionID)
            cancelPendingSnapshotPublish(for: sessionID)
            return
        }

        let hasPendingTask = pendingSnapshotPublishTasksBySessionID[sessionID] != nil
        let hasFollowUpRequest = followUpPublishRequestedSessionIDs.contains(sessionID)
        let publishIsInFlight = publishInFlightSessionIDs.contains(sessionID)

        guard hasPendingTask || hasFollowUpRequest || publishIsInFlight else {
            return
        }

        if publishIsInFlight {
            requestFollowUpPublish(sessionID: sessionID)
            return
        }

        cancelPendingSnapshotPublish(for: sessionID)
        followUpPublishRequestedSessionIDs.remove(sessionID)
        let snapshotOverride = pendingScheduledSnapshotOverridesBySessionID.removeValue(forKey: sessionID)
            ?? pendingSnapshotOverridesBySessionID.removeValue(forKey: sessionID)
        await publishLatestGridState(
            for: sessionID,
            engine: engine,
            snapshotOverride: snapshotOverride
        )
    }

    func publishGridState(
        for sessionID: UUID,
        engine: TerminalEngine,
        snapshotOverride: GridSnapshot? = nil
    ) async {
        guard let manager else { return }
        guard manager.engines[sessionID] != nil else { return }
        #if DEBUG
        let signpostID = OSSignpostID(log: perfSignpostLog)
        os_signpost(.begin, log: perfSignpostLog, name: "PublishGridState", signpostID: signpostID)
        defer {
            os_signpost(.end, log: perfSignpostLog, name: "PublishGridState", signpostID: signpostID)
        }
        _dbgPublishCount += 1
        let _elapsed = Date.now.timeIntervalSince(_dbgWindowStart)
        if _elapsed >= 0.1 {
            let rate = Double(_dbgPublishCount) / _elapsed
            print("[RenderCoord] snapshot rate: \(String(format: "%.1f", rate))/s (\(_dbgPublishCount) in \(String(format: "%.0f", _elapsed * 1000))ms)")
            _dbgPublishCount = 0
            _dbgWindowStart = Date.now
        }
        #endif

        let previousScrollbackCount = cachedScrollbackCountBySessionID[sessionID] ?? 0
        let previousUsingAlternateBuffer = gridSnapshotsBySessionID[sessionID]?.usingAlternateBuffer ?? false
        let scrollbackCount = await engine.scrollbackCount
        let usingAlternateBuffer = await engine.usingAlternateBuffer
        var currentOffset = scrollOffsetBySessionID[sessionID] ?? 0
        if usingAlternateBuffer && !previousUsingAlternateBuffer {
            currentOffset = 0
            preserveScrollAnchorBySessionID[sessionID] = false
        }
        let shouldPreserveAnchor = preserveScrollAnchorBySessionID[sessionID, default: currentOffset > 0]
        if !usingAlternateBuffer,
           shouldPreserveAnchor,
           currentOffset > 0,
           scrollbackCount > previousScrollbackCount {
            // Keep the same visible viewport while new lines append below.
            currentOffset += (scrollbackCount - previousScrollbackCount)
        }
        currentOffset = max(0, min(currentOffset, scrollbackCount))
        scrollOffsetBySessionID[sessionID] = currentOffset
        if currentOffset == 0 {
            preserveScrollAnchorBySessionID[sessionID] = false
        }
        cachedScrollbackCountBySessionID[sessionID] = scrollbackCount

        let snapshot: GridSnapshot
        if let snapshotOverride {
            snapshot = snapshotOverride
        } else if currentOffset > 0 {
            snapshot = await engine.snapshot(scrollOffset: currentOffset)
        } else {
            snapshot = await engine.snapshot()
        }
        let shouldForceFullSnapshot = forceFullSnapshotNextPublishBySessionID.contains(sessionID)
        let publishedSnapshot: GridSnapshot
        if shouldForceFullSnapshot {
            publishedSnapshot = GridSnapshot(
                cells: snapshot.cells,
                dirtyRange: nil,
                cursorRow: snapshot.cursorRow,
                cursorCol: snapshot.cursorCol,
                cursorVisible: snapshot.cursorVisible,
                cursorStyle: snapshot.cursorStyle,
                columns: snapshot.columns,
                rows: snapshot.rows,
                usingAlternateBuffer: snapshot.usingAlternateBuffer,
                graphemeOverrides: snapshot.graphemeOverrides
            )
            if snapshotOverride == nil {
                forceFullSnapshotNextPublishBySessionID.remove(sessionID)
            }
        } else {
            publishedSnapshot = snapshot
        }
        gridSnapshotsBySessionID[sessionID] = publishedSnapshot
        manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1

        publishScrollState(
            sessionID: sessionID,
            scrollOffset: currentOffset,
            scrollbackCount: scrollbackCount
        )

        if !usingAlternateBuffer && shouldPublishShellBuffer(for: sessionID) {
            let visibleLines = await engine.visibleText()
            manager.shellBuffers[sessionID] = visibleLines
            if let completedBlock = await manager.terminalHistoryIndex.observeVisibleLines(
                sessionID: sessionID,
                lines: visibleLines,
                at: .now
            ) {
                manager.publishCommandCompletion(completedBlock)
            }
        }

        let bellCount = await engine.consumeBellCount()
        if bellCount > 0 {
            if isInBurstMode(for: sessionID) {
                let now = Date()
                let lastBell = lastBellTimeBySessionID[sessionID] ?? .distantPast
                if now.timeIntervalSince(lastBell) >= 1.0 {
                    manager.bellEventNonceBySessionID[sessionID, default: 0] += 1
                    lastBellTimeBySessionID[sessionID] = now
                }
            } else {
                manager.bellEventNonceBySessionID[sessionID, default: 0] += bellCount
            }
        }

        manager.inputModeSnapshotsBySessionID[sessionID] = await engine.inputModeSnapshot()

        let title = await engine.windowTitle
        if !title.isEmpty {
            manager.windowTitleBySessionID[sessionID] = title
        }

        let cwd = await engine.workingDirectory
        if !cwd.isEmpty {
            manager.workingDirectoryBySessionID[sessionID] = cwd
        }
    }

    // MARK: - Scroll state publishing

    private func publishScrollState(sessionID: UUID, scrollOffset: Int, scrollbackCount: Int) {
        guard let manager else { return }
        let visibleRows = desiredPTYBySessionID[sessionID]?.rows ?? PTYConfiguration.default.rows
        manager.scrollStateBySessionID[sessionID] = TerminalScrollState(
            scrollOffset: scrollOffset,
            scrollbackCount: scrollbackCount,
            visibleRows: visibleRows
        )
    }

    // MARK: - Private helpers

    private func isInBurstMode(for sessionID: UUID) -> Bool {
        (manager?.throughputModeEnabled ?? false) || (autoBurstModeBySessionID[sessionID] == true)
    }

    private func updateBurstState(for sessionID: UUID) {
        let now = Date()
        let windowStart = burstWindowStartBySessionID[sessionID] ?? now

        if now.timeIntervalSince(windowStart) > burstWindowDuration {
            burstCountBySessionID[sessionID] = 1
            burstWindowStartBySessionID[sessionID] = now
        } else {
            burstCountBySessionID[sessionID, default: 0] += 1
        }

        let count = burstCountBySessionID[sessionID, default: 0]
        if count > burstThreshold, autoBurstModeBySessionID[sessionID] != true {
            autoBurstModeBySessionID[sessionID] = true
            #if DEBUG
            print("[RenderCoord] burst mode ON  session=\(sessionID.uuidString.prefix(8)) count=\(count)")
            #endif
        }

        burstRevertTasksBySessionID[sessionID]?.cancel()
        burstRevertTasksBySessionID[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.burstRevertDelay ?? .milliseconds(200))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.autoBurstModeBySessionID[sessionID] == true {
                self.autoBurstModeBySessionID[sessionID] = false
                self.burstCountBySessionID.removeValue(forKey: sessionID)
                self.burstWindowStartBySessionID.removeValue(forKey: sessionID)
                #if DEBUG
                print("[RenderCoord] burst mode OFF session=\(sessionID.uuidString.prefix(8))")
                #endif
            }
            self.burstRevertTasksBySessionID.removeValue(forKey: sessionID)
        }
    }

    private func resetBurstState() {
        burstCountBySessionID.removeAll()
        burstWindowStartBySessionID.removeAll()
        autoBurstModeBySessionID.removeAll()

        for task in burstRevertTasksBySessionID.values {
            task.cancel()
        }
        burstRevertTasksBySessionID.removeAll()
    }

    private func cancelPendingSnapshotPublish(for sessionID: UUID) {
        pendingSnapshotPublishTasksBySessionID[sessionID]?.cancel()
        pendingSnapshotPublishTasksBySessionID.removeValue(forKey: sessionID)
        pendingSnapshotPublishStartedAtBySessionID.removeValue(forKey: sessionID)
        pendingScheduledSnapshotOverridesBySessionID.removeValue(forKey: sessionID)
    }

    private func scheduleCoalescedGridPublish(
        for sessionID: UUID,
        engine: TerminalEngine,
        debounceMode: PublishDebounceMode,
        snapshotOverride: GridSnapshot? = nil
    ) {
        if isPublishingSuspended {
            suspendedDirtySessionIDs.insert(sessionID)
            return
        }

        if let snapshotOverride {
            pendingScheduledSnapshotOverridesBySessionID[sessionID] = snapshotOverride
        }

        updateBurstState(for: sessionID)

        if publishInFlightSessionIDs.contains(sessionID) {
            requestFollowUpPublish(sessionID: sessionID)
            return
        }

        let now = Date()
        let firstScheduledAt = pendingSnapshotPublishStartedAtBySessionID[sessionID] ?? now

        if let existingTask = pendingSnapshotPublishTasksBySessionID[sessionID] {
            guard debounceMode.requiresDebounce else {
                return
            }

            let pendingAge = now.timeIntervalSince(firstScheduledAt)
            guard pendingAge < maxPublishDeferral(for: debounceMode) else {
                return
            }

            existingTask.cancel()
            pendingSnapshotPublishTasksBySessionID.removeValue(forKey: sessionID)
        }

        pendingSnapshotPublishStartedAtBySessionID[sessionID] = firstScheduledAt

        pendingSnapshotPublishTasksBySessionID[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let interval: Duration
            if debounceMode.requiresDebounce {
                interval = self.publishInterval(for: debounceMode)
            } else {
                interval = self.isInBurstMode(for: sessionID)
                    ? self.throughputSnapshotPublishInterval
                    : self.snapshotPublishInterval
            }
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self.pendingSnapshotPublishTasksBySessionID.removeValue(forKey: sessionID)
            self.pendingSnapshotPublishStartedAtBySessionID.removeValue(forKey: sessionID)
            let snapshotOverride = self.pendingScheduledSnapshotOverridesBySessionID.removeValue(forKey: sessionID)
            await self.publishLatestGridState(
                for: sessionID,
                engine: engine,
                snapshotOverride: snapshotOverride
            )
        }
    }

    private func publishLatestGridState(
        for sessionID: UUID,
        engine: TerminalEngine,
        snapshotOverride: GridSnapshot? = nil
    ) async {
        if isPublishingSuspended {
            suspendedDirtySessionIDs.insert(sessionID)
            return
        }

        if publishInFlightSessionIDs.contains(sessionID) {
            requestFollowUpPublish(
                sessionID: sessionID,
                snapshotOverride: snapshotOverride
            )
            return
        }

        publishInFlightSessionIDs.insert(sessionID)
        defer {
            publishInFlightSessionIDs.remove(sessionID)
            promptRedrawPendingSessionIDs.remove(sessionID)
        }

        var nextSnapshotOverride = snapshotOverride

        while true {
            // Once a publish actually starts, any older stored override has either
            // been selected explicitly for this publish or is now stale and must
            // not be replayed by an unrelated follow-up request.
            pendingSnapshotOverridesBySessionID.removeValue(forKey: sessionID)

            await publishGridState(
                for: sessionID,
                engine: engine,
                snapshotOverride: nextSnapshotOverride
            )
            #if DEBUG
            if let injectedSnapshotOverride = testingInjectedFollowUpSnapshotBySessionID.removeValue(forKey: sessionID) {
                requestFollowUpPublish(
                    sessionID: sessionID,
                    snapshotOverride: injectedSnapshotOverride
                )
            }
            #endif

            guard followUpPublishRequestedSessionIDs.remove(sessionID) != nil else {
                return
            }

            if isPublishingSuspended {
                suspendedDirtySessionIDs.insert(sessionID)
                return
            }

            nextSnapshotOverride = pendingSnapshotOverridesBySessionID.removeValue(forKey: sessionID)
        }
    }

    private func shouldPublishShellBuffer(for sessionID: UUID, now: Date = .now) -> Bool {
        let publishInterval = isInBurstMode(for: sessionID)
            ? throughputShellBufferPublishInterval
            : shellBufferPublishInterval
        if let lastPublished = lastShellBufferPublishAtBySessionID[sessionID],
           now.timeIntervalSince(lastPublished) < publishInterval {
            return false
        }
        lastShellBufferPublishAtBySessionID[sessionID] = now
        return true
    }

    private func publishInterval(for debounceMode: PublishDebounceMode) -> Duration {
        switch debounceMode {
        case .none:
            return snapshotPublishInterval
        case .alternateBuffer:
            return alternateBufferSnapshotPublishInterval
        case .promptRedraw:
            return promptRedrawSnapshotPublishInterval
        case .synchronizedOutput:
            return synchronizedOutputSnapshotPublishInterval
        }
    }

    private func maxPublishDeferral(for debounceMode: PublishDebounceMode) -> TimeInterval {
        switch debounceMode {
        case .none:
            return 0
        case .alternateBuffer:
            return alternateBufferMaxPublishDeferral
        case .promptRedraw:
            return promptRedrawMaxPublishDeferral
        case .synchronizedOutput:
            return synchronizedOutputMaxPublishDeferral
        }
    }

    private func requestFollowUpPublish(
        sessionID: UUID,
        snapshotOverride: GridSnapshot? = nil
    ) {
        followUpPublishRequestedSessionIDs.insert(sessionID)
        if let snapshotOverride {
            pendingSnapshotOverridesBySessionID[sessionID] = snapshotOverride
        }
    }

#if DEBUG
    func testingSetPublishInFlight(sessionID: UUID, inFlight: Bool) {
        if inFlight {
            publishInFlightSessionIDs.insert(sessionID)
        } else {
            publishInFlightSessionIDs.remove(sessionID)
        }
    }

    func testingHasPublishInFlight(sessionID: UUID) -> Bool {
        publishInFlightSessionIDs.contains(sessionID)
    }

    func testingQueueFollowUpAfterCurrentPublish(
        sessionID: UUID,
        snapshotOverride: GridSnapshot
    ) {
        testingInjectedFollowUpSnapshotBySessionID[sessionID] = snapshotOverride
    }
#endif
}
