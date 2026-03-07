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
        manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

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
        manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)
        _ = await engine.feed(Data(("\r\n\(markerB)\r\n").utf8))
        manager.renderingCoordinator.scheduleParsedChunkPublish(sessionID: session.id, engine: engine)

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
