// SessionManagerRenderingPathTests.swift
// ProSSHV2
//
// Targeted regression tests for nonce-driven snapshot publishing.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class SessionManagerRenderingPathTests: XCTestCase {

    @MainActor
    func testNonceDrivenSnapshotFetchAfterResize() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first else {
            XCTFail("Expected at least one injected session")
            return
        }

        let initialNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        let initialSnapshot = manager.gridSnapshot(for: session.id)
        XCTAssertNotNil(initialSnapshot)

        await manager.resizeTerminal(sessionID: session.id, columns: 96, rows: 28)

        let updatedNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        let updatedSnapshot = manager.gridSnapshot(for: session.id)

        XCTAssertGreaterThan(updatedNonce, initialNonce)
        XCTAssertEqual(updatedSnapshot?.columns, 96)
        XCTAssertEqual(updatedSnapshot?.rows, 28)
        XCTAssertNotEqual(updatedSnapshot?.columns, initialSnapshot?.columns)
        XCTAssertNotEqual(updatedSnapshot?.rows, initialSnapshot?.rows)
    }

    @MainActor
    func testNonceDrivenSnapshotFetchAfterScroll() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first else {
            XCTFail("Expected at least one injected session")
            return
        }

        let initialNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        manager.scrollTerminal(sessionID: session.id, delta: 10)
        await waitForNonceIncrement(manager: manager, sessionID: session.id, baseline: initialNonce)

        let updatedNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        let updatedSnapshot = manager.gridSnapshot(for: session.id)

        XCTAssertGreaterThan(updatedNonce, initialNonce)
        XCTAssertNotNil(updatedSnapshot)
    }

    @MainActor
    func testLocalSessionStreamsProgressiveCommandOutput() async throws {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )

        let session = try await manager.openLocalSession(
            shellPath: "/bin/zsh",
            workingDirectory: "/tmp"
        )
        defer {
            Task { await manager.closeSession(sessionID: session.id) }
        }

        let marker = "PROSSH_LOCAL_STREAM_DONE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        await manager.sendShellInput(
            sessionID: session.id,
            input: "for i in 1 2 3; do echo PROSSH_LOCAL_STREAM_$i; sleep 0.15; done; echo \(marker)"
        )

        let sawOutput = await waitForShellBufferContains(
            manager: manager,
            sessionID: session.id,
            text: marker,
            timeout: .seconds(8)
        )
        XCTAssertTrue(sawOutput, "Expected progressive local command output to appear in shell buffer.")
    }

    @MainActor
    func testInactiveRenderingDefersPublishUntilResume() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        let baselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        let marker = "PROSSH_INACTIVE_RENDER_\(UUID().uuidString.prefix(8))"

        manager.applicationDidBecomeInactive()
        _ = await engine.feed(Data(("\r\n\(marker)\r\n").utf8))
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(manager.gridSnapshotNonceBySessionID[session.id, default: -1], baselineNonce)
        XCTAssertFalse(manager.shellBuffers[session.id, default: []].joined(separator: "\n").contains(marker))

        await manager.renderingCoordinator.applicationDidBecomeActive()
        await waitForNonceIncrement(manager: manager, sessionID: session.id, baseline: baselineNonce)

        XCTAssertEqual(manager.gridSnapshotNonceBySessionID[session.id, default: -1], baselineNonce + 1)
        XCTAssertTrue(manager.shellBuffers[session.id, default: []].joined(separator: "\n").contains(marker))
    }

    @MainActor
    func testInactiveRenderingCollapsesMultipleDeferredPublishesIntoSingleCatchUp() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        let baselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        let markerA = "PROSSH_DEFERRED_A_\(UUID().uuidString.prefix(6))"
        let markerB = "PROSSH_DEFERRED_B_\(UUID().uuidString.prefix(6))"

        manager.applicationDidBecomeInactive()
        _ = await engine.feed(Data(("\r\n\(markerA)\r\n").utf8))
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)
        _ = await engine.feed(Data(("\r\n\(markerB)\r\n").utf8))
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(manager.gridSnapshotNonceBySessionID[session.id, default: -1], baselineNonce)

        await manager.renderingCoordinator.applicationDidBecomeActive()
        await waitForNonceIncrement(manager: manager, sessionID: session.id, baseline: baselineNonce)

        let catchUpNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        XCTAssertEqual(catchUpNonce, baselineNonce + 1)

        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(manager.gridSnapshotNonceBySessionID[session.id, default: -1], catchUpNonce)

        let shellBufferText = manager.shellBuffers[session.id, default: []].joined(separator: "\n")
        XCTAssertTrue(shellBufferText.contains(markerA))
        XCTAssertTrue(shellBufferText.contains(markerB))
    }

    @MainActor
    func testAlternateBufferResetsOnEntryButAllowsViewportScrollbackAfterward() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        let seededLines = (1...60)
            .map { "ALT_SCROLL_SEED_\($0)" }
            .joined(separator: "\r\n") + "\r\n"
        _ = await engine.feed(Data(seededLines.utf8))
        await manager.renderingCoordinator.publishGridState(for: session.id, engine: engine)

        let preAltBaselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        manager.scrollTerminal(sessionID: session.id, delta: 4)
        await waitForNonceIncrement(manager: manager, sessionID: session.id, baseline: preAltBaselineNonce)
        XCTAssertEqual(manager.scrollStateBySessionID[session.id]?.scrollOffset, 4)

        _ = await engine.feed(Data("\u{1B}[?1049h".utf8))
        await manager.renderingCoordinator.publishGridState(for: session.id, engine: engine)

        let stateInAlt = manager.scrollStateBySessionID[session.id]
        let altScrollbackCount = stateInAlt?.scrollbackCount ?? 0
        XCTAssertEqual(stateInAlt?.scrollOffset, 0)
        XCTAssertGreaterThan(altScrollbackCount, 0)

        let targetOffset = min(6, altScrollbackCount)
        XCTAssertGreaterThan(targetOffset, 0)

        let altScrollBaselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        manager.scrollTerminal(sessionID: session.id, delta: targetOffset)
        await waitForNonceIncrement(manager: manager, sessionID: session.id, baseline: altScrollBaselineNonce)

        XCTAssertEqual(manager.scrollStateBySessionID[session.id]?.scrollOffset, targetOffset)
        XCTAssertEqual(manager.scrollStateBySessionID[session.id]?.scrollbackCount, altScrollbackCount)

        let liveAltBaselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        _ = await engine.feed(Data("ALT".utf8))
        await manager.renderingCoordinator.publishGridState(for: session.id, engine: engine)

        XCTAssertGreaterThan(manager.gridSnapshotNonceBySessionID[session.id, default: -1], liveAltBaselineNonce)
        XCTAssertEqual(manager.scrollStateBySessionID[session.id]?.scrollOffset, targetOffset)
        XCTAssertEqual(manager.scrollStateBySessionID[session.id]?.scrollbackCount, altScrollbackCount)
    }

    @MainActor
    func testSynchronizedOutputFallbackPublishesLiveSnapshotWithoutWaitingForSyncExit() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        _ = await engine.feed(Data("OLD".utf8))
        await manager.renderingCoordinator.publishGridState(for: session.id, engine: engine)
        let baselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]

        _ = await engine.feed(Data("\u{1B}[?2026h\u{1B}[2J\u{1B}[HLIVE".utf8))
        let liveSyncSnapshot = await engine.liveSnapshot()
        manager.renderingCoordinator.scheduleSynchronizedOutputFallbackPublish(
            sessionID: session.id,
            engine: engine,
            snapshotOverride: liveSyncSnapshot
        )

        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            manager.gridSnapshotNonceBySessionID[session.id, default: -1],
            baselineNonce,
            "Synchronized-output fallback should still debounce briefly before publishing."
        )

        await waitForNonceIncrement(manager: manager, sessionID: session.id, baseline: baselineNonce)

        guard let snapshot = manager.gridSnapshot(for: session.id) else {
            XCTFail("Expected a published snapshot after the synchronized-output fallback.")
            return
        }

        XCTAssertEqual(snapshotText(snapshot, row: 0, startCol: 0, count: 4), "LIVE")
    }

    @MainActor
    func testAlternateBufferSplitRedrawPublishesOnlyAfterQuiescentWindow() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        _ = await engine.feed(Data("\u{1B}[?1049h\u{1B}[2J\u{1B}[1;1HHEL".utf8))

        let baselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

        try? await Task.sleep(for: .milliseconds(12))
        XCTAssertEqual(
            manager.gridSnapshotNonceBySessionID[session.id, default: -1],
            baselineNonce,
            "Alternate-screen redraw should not publish the partial frame immediately."
        )

        _ = await engine.feed(Data("LO".utf8))
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

        try? await Task.sleep(for: .milliseconds(12))
        XCTAssertEqual(
            manager.gridSnapshotNonceBySessionID[session.id, default: -1],
            baselineNonce,
            "Rescheduling within the quiescent window should keep waiting for the completed frame."
        )

        await waitForNonceIncrement(manager: manager, sessionID: session.id, baseline: baselineNonce)

        guard let snapshot = manager.gridSnapshot(for: session.id) else {
            XCTFail("Expected a published snapshot after the quiescent window.")
            return
        }

        XCTAssertEqual(snapshotText(snapshot, row: 0, startCol: 0, count: 5), "HELLO")
    }

    @MainActor
    func testAlternateBufferSustainedRedrawDoesNotForceIntermediatePublishAtFiftyMilliseconds() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        _ = await engine.feed(Data("\u{1B}[?1049h".utf8))
        await manager.renderingCoordinator.publishGridState(for: session.id, engine: engine)

        let baselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        let redrawFragments = [
            "\u{1B}[2J\u{1B}[1;1HF",
            "\u{1B}[2J\u{1B}[1;1HFR",
            "\u{1B}[2J\u{1B}[1;1HFRA",
            "\u{1B}[2J\u{1B}[1;1HFRAM"
        ]

        for fragment in redrawFragments {
            _ = await engine.feed(Data(fragment.utf8))
            await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)
            try? await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(
                manager.gridSnapshotNonceBySessionID[session.id, default: -1],
                baselineNonce,
                "Long alternate-buffer redraw bursts should keep coalescing instead of forcing a publish after ~50ms."
            )
        }

        _ = await engine.feed(Data("\u{1B}[2J\u{1B}[1;1HFRAME DONE".utf8))
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

        try? await Task.sleep(for: .milliseconds(12))
        XCTAssertEqual(
            manager.gridSnapshotNonceBySessionID[session.id, default: -1],
            baselineNonce,
            "The completed frame should still wait for the quiescent debounce before publishing."
        )

        await waitForNonceIncrement(manager: manager, sessionID: session.id, baseline: baselineNonce)

        guard let snapshot = manager.gridSnapshot(for: session.id) else {
            XCTFail("Expected a published snapshot after the sustained redraw settled.")
            return
        }

        XCTAssertEqual(snapshotText(snapshot, row: 0, startCol: 0, count: 10), "FRAME DONE")
    }

    @MainActor
    func testAlternateBufferInputModeRefreshesBeforeDebouncedPublish() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        _ = await engine.feed(Data("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h".utf8))

        let baselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        await manager.renderingCoordinator.refreshInputModeSnapshot(sessionID: session.id, engine: engine)
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

        XCTAssertEqual(
            manager.gridSnapshotNonceBySessionID[session.id, default: -1],
            baselineNonce,
            "Alternate-buffer redraw should still be debounced."
        )
        XCTAssertEqual(manager.inputModeSnapshotsBySessionID[session.id]?.mouseTracking, .x10)
        XCTAssertEqual(manager.inputModeSnapshotsBySessionID[session.id]?.mouseEncoding, .sgr)
    }

    @MainActor
    func testAlternateBufferPublishDoesNotRewriteShellBuffer() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        manager.shellBuffers[session.id] = ["KEEP_MAIN_BUFFER"]

        _ = await engine.feed(Data("\u{1B}[?1049h\u{1B}[2J\u{1B}[1;1HALT".utf8))
        await manager.renderingCoordinator.publishGridState(for: session.id, engine: engine)

        XCTAssertEqual(
            manager.shellBuffers[session.id],
            ["KEEP_MAIN_BUFFER"],
            "Alternate-buffer publishes should skip shell-buffer extraction so TUI redraws stay on the fast path."
        )
    }

    @MainActor
    func testSemanticPromptRedrawPublishesOnlyAfterQuiescentWindow() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        let promptRow = await engine.cursor.row
        await manager.renderingCoordinator.noteSemanticPromptEvent(sessionID: session.id, event: .commandEnd(exitCode: 0))

        _ = await engine.feed(Data("\rPROM".utf8))

        let baselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

        try? await Task.sleep(for: .milliseconds(12))
        XCTAssertEqual(
            manager.gridSnapshotNonceBySessionID[session.id, default: -1],
            baselineNonce,
            "Prompt redraw should wait for the quiescent window instead of showing an intermediate line."
        )

        _ = await engine.feed(Data("PT".utf8))
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

        try? await Task.sleep(for: .milliseconds(12))
        XCTAssertEqual(
            manager.gridSnapshotNonceBySessionID[session.id, default: -1],
            baselineNonce,
            "Rescheduling within the prompt redraw window should still suppress the partial frame."
        )

        await waitForNonceIncrement(manager: manager, sessionID: session.id, baseline: baselineNonce)

        guard let snapshot = manager.gridSnapshot(for: session.id) else {
            XCTFail("Expected a published snapshot after the prompt redraw settled.")
            return
        }

        XCTAssertEqual(snapshotText(snapshot, row: promptRow, startCol: 0, count: 6), "PROMPT")
    }

    @MainActor
    func testSemanticPromptEventsArmQuiescentPublishBeforeScheduling() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        let baselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        _ = await engine.feed(Data("\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}\r\u{1B}[J".utf8))
        let promptRow = await engine.cursor.row
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

        try? await Task.sleep(for: .milliseconds(12))
        XCTAssertEqual(
            manager.gridSnapshotNonceBySessionID[session.id, default: -1],
            baselineNonce,
            "Scheduling immediately after OSC 133 prompt markers should already be inside the prompt quiescent window."
        )

        _ = await engine.feed(Data("PROMPT".utf8))
        await manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)
        await waitForNonceIncrement(manager: manager, sessionID: session.id, baseline: baselineNonce)

        guard let snapshot = manager.gridSnapshot(for: session.id) else {
            XCTFail("Expected a published snapshot after the prompt redraw settled.")
            return
        }

        XCTAssertEqual(snapshotText(snapshot, row: promptRow, startCol: 0, count: 6), "PROMPT")
    }

    @MainActor
    func testSyncExitSnapshotOverrideSurvivesInFlightPublishAndWinsFollowUpFlush() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        _ = await engine.feed(Data("\u{1B}[2J\u{1B}[HOVERRIDE".utf8))
        let syncExitSnapshot = await engine.snapshot()

        _ = await engine.feed(Data("\u{1B}[2J\u{1B}[HLATEST".utf8))

        manager.renderingCoordinator.testingSetPublishInFlight(sessionID: session.id, inFlight: true)
        await manager.renderingCoordinator.publishSyncExitSnapshot(
            sessionID: session.id,
            engine: engine,
            snapshotOverride: syncExitSnapshot
        )
        manager.renderingCoordinator.testingSetPublishInFlight(sessionID: session.id, inFlight: false)

        await manager.renderingCoordinator.flushPendingSnapshotPublishIfNeeded(
            for: session.id,
            engine: engine
        )

        guard let publishedSnapshot = manager.gridSnapshot(for: session.id) else {
            XCTFail("Expected a published snapshot after the follow-up flush.")
            return
        }

        XCTAssertEqual(
            snapshotText(publishedSnapshot, row: 0, startCol: 0, count: 8),
            "OVERRIDE",
            "A sync-exit snapshot captured before later parser activity must not be replaced by a fresh live snapshot when the follow-up publish flushes."
        )
    }

    @MainActor
    func testMultipleSyncExitSnapshotsFromOneParserBatchCollapseToLatestFrame() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        _ = await engine.feed(Data("\u{1B}[2J\u{1B}[HEARLY".utf8))
        let earlySnapshot = await engine.snapshot()

        _ = await engine.feed(Data("\u{1B}[2J\u{1B}[HLATEST".utf8))
        let latestSnapshot = await engine.snapshot()

        let baselineNonce = manager.gridSnapshotNonceBySessionID[session.id, default: -1]
        await manager.renderingCoordinator.publishSyncExitSnapshots(
            sessionID: session.id,
            engine: engine,
            snapshotOverrides: [earlySnapshot, latestSnapshot]
        )

        XCTAssertEqual(
            manager.gridSnapshotNonceBySessionID[session.id, default: -1],
            baselineNonce + 1,
            "A parser batch with multiple completed sync frames should publish only the final frame instead of replaying every obsolete intermediate snapshot."
        )

        guard let publishedSnapshot = manager.gridSnapshot(for: session.id) else {
            XCTFail("Expected a published snapshot after the coalesced sync batch.")
            return
        }

        XCTAssertNil(
            publishedSnapshot.dirtyRange,
            "Coalesced sync batches should still force a full upload so earlier full-screen clears cannot leave stale rows behind."
        )
        XCTAssertEqual(snapshotText(publishedSnapshot, row: 0, startCol: 0, count: 6), "LATEST")
    }

    @MainActor
    func testFirstLivePublishAfterSyncExitForcesFullSnapshotUpload() async {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: InMemoryKnownHostsStore()
        )
        await manager.injectScreenshotSessions()

        guard let session = manager.sessions.first,
              let engine = manager.engines[session.id] else {
            XCTFail("Expected an injected session with an engine")
            return
        }

        _ = await engine.feed(Data("\u{1B}[2J\u{1B}[HSYNCFRAME".utf8))
        let syncExitSnapshot = await engine.snapshot()

        await manager.renderingCoordinator.publishSyncExitSnapshot(
            sessionID: session.id,
            engine: engine,
            snapshotOverride: syncExitSnapshot
        )

        _ = await engine.feed(Data("\u{1B}[HPOSTSYNC".utf8))
        await manager.renderingCoordinator.publishGridState(for: session.id, engine: engine)

        guard let publishedSnapshot = manager.gridSnapshot(for: session.id) else {
            XCTFail("Expected a published snapshot after the post-sync live publish.")
            return
        }

        XCTAssertNil(
            publishedSnapshot.dirtyRange,
            "The first ordinary publish after a synchronized redraw should force a full upload so stale rows from the old frame cannot survive."
        )
        XCTAssertEqual(snapshotText(publishedSnapshot, row: 0, startCol: 0, count: 8), "POSTSYNC")
    }

    @MainActor
    private func waitForNonceIncrement(
        manager: SessionManager,
        sessionID: UUID,
        baseline: Int
    ) async {
        for _ in 0..<50 {
            if manager.gridSnapshotNonceBySessionID[sessionID, default: -1] > baseline {
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func waitForShellBufferContains(
        manager: SessionManager,
        sessionID: UUID,
        text: String,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if manager.shellBuffers[sessionID, default: []].joined(separator: "\n").contains(text) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(40))
        }

        return manager.shellBuffers[sessionID, default: []].joined(separator: "\n").contains(text)
    }

    private func snapshotText(
        _ snapshot: GridSnapshot,
        row: Int,
        startCol: Int,
        count: Int
    ) -> String {
        var out = ""
        for col in startCol..<(startCol + count) {
            let idx = row * snapshot.columns + col
            guard idx >= 0, idx < snapshot.cells.count else { continue }
            let cp = snapshot.cells[idx].glyphIndex
            if cp == 0 {
                out.append(contentsOf: " ")
            } else if let scalar = UnicodeScalar(cp) {
                out.append(Character(scalar))
            }
        }
        return out
    }
}

private actor InMemoryKnownHostsStore: KnownHostsStoreProtocol {
    func allEntries() async throws -> [KnownHostEntry] { [] }

    func evaluate(
        hostname: String,
        port: UInt16,
        hostKeyType: String,
        presentedFingerprint: String
    ) async throws -> KnownHostVerificationResult {
        .trusted
    }

    func trust(challenge: KnownHostVerificationChallenge) async throws {}

    func clearAll() async throws {}
}
#endif
