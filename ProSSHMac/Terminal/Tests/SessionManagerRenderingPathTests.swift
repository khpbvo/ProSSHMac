// SessionManagerRenderingPathTests.swift
// ProSSHV2
//
// Targeted regression tests for nonce-driven snapshot publishing.

#if canImport(XCTest)
import XCTest

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
