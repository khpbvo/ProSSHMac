// Extracted from SessionManager.swift
import Foundation
#if DEBUG
import os.signpost
#endif

@MainActor final class TerminalRenderingCoordinator {
    weak var manager: SessionManager?

    // MARK: - Private rendering state (all moved from SessionManager)

    var gridSnapshotsBySessionID: [UUID: GridSnapshot] = [:]
    var pendingSnapshotPublishTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    /// Per-session scroll offset (0 = live view, >0 = scrolled back N lines).
    var scrollOffsetBySessionID: [UUID: Int] = [:]
    /// Throttles expensive visible-text extraction/publishing during heavy output.
    var lastShellBufferPublishAtBySessionID: [UUID: Date] = [:]
    /// Tracks last bell event time per session for throughput mode rate-limiting.
    var lastBellTimeBySessionID: [UUID: Date] = [:]
    var pendingResizeTasks: [UUID: Task<Void, Never>] = [:]
    var desiredPTYBySessionID: [UUID: PTYConfiguration] = [:]

    private let shellBufferPublishInterval: TimeInterval = 1.0 / 30.0
    private let throughputShellBufferPublishInterval: TimeInterval = 1.0 / 5.0
    private let snapshotPublishInterval: Duration = .milliseconds(8)
    private let throughputSnapshotPublishInterval: Duration = .milliseconds(16)

    #if DEBUG
    private let perfSignpostLog = OSLog(subsystem: "com.prossh", category: "TerminalPerf")
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
        scrollOffsetBySessionID.removeValue(forKey: sessionID)
        gridSnapshotsBySessionID.removeValue(forKey: sessionID)
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
        let current = scrollOffsetBySessionID[sessionID, default: 0]
        Task { @MainActor [weak self] in
            guard let self, let manager = self.manager else { return }
            let maxOffset = await engine.scrollbackCount
            let newOffset = max(0, min(current + delta, maxOffset))
            self.scrollOffsetBySessionID[sessionID] = newOffset
            let snapshot = await engine.snapshot(scrollOffset: newOffset)
            self.gridSnapshotsBySessionID[sessionID] = snapshot
            manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
        }
    }

    func scrollToBottom(sessionID: UUID) {
        guard let manager, let engine = manager.engines[sessionID] else { return }
        scrollOffsetBySessionID[sessionID] = 0
        Task { @MainActor [weak self] in
            guard let self, let manager = self.manager else { return }
            let snapshot = await engine.snapshot()
            self.gridSnapshotsBySessionID[sessionID] = snapshot
            manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1
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
        scrollOffsetBySessionID[sessionID] = 0
        cancelPendingSnapshotPublish(for: sessionID)
        await publishGridState(
            for: sessionID,
            engine: engine,
            snapshotOverride: snapshotOverride
        )
    }

    func scheduleParsedChunkPublish(
        sessionID: UUID,
        engine: TerminalEngine
    ) {
        scrollOffsetBySessionID[sessionID] = 0
        scheduleCoalescedGridPublish(for: sessionID, engine: engine)
    }

    func flushPendingSnapshotPublishIfNeeded(
        for sessionID: UUID,
        engine: TerminalEngine
    ) async {
        guard pendingSnapshotPublishTasksBySessionID[sessionID] != nil else {
            return
        }
        cancelPendingSnapshotPublish(for: sessionID)
        await publishGridState(for: sessionID, engine: engine)
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
        #endif

        let snapshot: GridSnapshot
        if let snapshotOverride {
            snapshot = snapshotOverride
        } else {
            snapshot = await engine.snapshot()
        }
        gridSnapshotsBySessionID[sessionID] = snapshot
        manager.gridSnapshotNonceBySessionID[sessionID, default: 0] += 1

        if shouldPublishShellBuffer(for: sessionID) {
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
            if manager.throughputModeEnabled {
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

    // MARK: - Private helpers

    private func cancelPendingSnapshotPublish(for sessionID: UUID) {
        pendingSnapshotPublishTasksBySessionID[sessionID]?.cancel()
        pendingSnapshotPublishTasksBySessionID.removeValue(forKey: sessionID)
    }

    private func scheduleCoalescedGridPublish(
        for sessionID: UUID,
        engine: TerminalEngine
    ) {
        guard pendingSnapshotPublishTasksBySessionID[sessionID] == nil else {
            return
        }

        pendingSnapshotPublishTasksBySessionID[sessionID] = Task { @MainActor [weak self] in
            guard let self, let manager = self.manager else { return }
            let interval = manager.throughputModeEnabled
                ? self.throughputSnapshotPublishInterval
                : self.snapshotPublishInterval
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self.pendingSnapshotPublishTasksBySessionID.removeValue(forKey: sessionID)
            await self.publishGridState(for: sessionID, engine: engine)
        }
    }

    private func shouldPublishShellBuffer(for sessionID: UUID, now: Date = .now) -> Bool {
        guard let manager else { return true }
        let publishInterval = manager.throughputModeEnabled
            ? throughputShellBufferPublishInterval
            : shellBufferPublishInterval
        if let lastPublished = lastShellBufferPublishAtBySessionID[sessionID],
           now.timeIntervalSince(lastPublished) < publishInterval {
            return false
        }
        lastShellBufferPublishAtBySessionID[sessionID] = now
        return true
    }
}
