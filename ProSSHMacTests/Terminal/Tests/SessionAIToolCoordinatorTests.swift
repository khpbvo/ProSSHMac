// SessionAIToolCoordinatorTests.swift
// ProSSHMac
//
// Regression tests for SessionAIToolCoordinator marker wrapping (Issue #9).

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class SessionAIToolCoordinatorTests: XCTestCase {

    // MARK: - Phase 1 regression: marker must not contain SGR escape sequences

    /// The AI command marker used to wrap commands with `\033[8m` (SGR hidden).
    /// If the inner command failed catastrophically, the reset `\033[0m` never fired,
    /// leaving all subsequent terminal text invisible. This test ensures the marker
    /// printf contains no SGR escapes at all.
    func testWrappedCommandContainsNoSGREscapeSequences() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()

        // Use a very short timeout — we only care about the sent command, not the result.
        _ = await manager.aiToolCoordinator.executeCommandAndWait(
            sessionID: sessionID,
            command: "echo hello",
            timeoutSeconds: 0.1
        )

        let payloads = await spy.sentPayloads
        // Expect at least 2 sends: the wrapped command + SGR reset on timeout.
        XCTAssertGreaterThanOrEqual(payloads.count, 1, "Expected at least the wrapped command send")

        let wrappedCommand = payloads[0]

        // Must contain the marker pattern.
        XCTAssertTrue(wrappedCommand.contains("__PSW_"), "Wrapped command should contain marker prefix")

        // Must NOT contain any SGR escape sequences (\x1B[...m).
        let escapePattern = #"\x1B\["#
        let hasEscape = wrappedCommand.range(of: escapePattern, options: .regularExpression) != nil
        XCTAssertFalse(hasEscape, "Wrapped command must not contain SGR escape sequences, got: \(wrappedCommand)")
    }

    // MARK: - Phase 2 regression: SGR reset must be sent on timeout

    /// When `executeCommandAndWait` times out, it must send `\033[0m` to reset
    /// any stuck SGR attributes on the terminal.
    func testTimeoutSendsSGRReset() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()

        let result = await manager.aiToolCoordinator.executeCommandAndWait(
            sessionID: sessionID,
            command: "sleep 999",
            timeoutSeconds: 0.1
        )

        XCTAssertTrue(result.timedOut, "Command should have timed out")

        let payloads = await spy.sentPayloads
        // The last send should be the SGR reset.
        guard let lastPayload = payloads.last else {
            XCTFail("Expected at least one send after timeout")
            return
        }
        XCTAssertTrue(
            lastPayload.contains("\u{1B}[0m"),
            "Timeout should send SGR reset (\\033[0m), got: \(lastPayload.debugDescription)"
        )
    }

    // MARK: - Helpers

    /// Creates a SessionManager with a connected session, then swaps in a SpyShellChannel.
    private func makeConnectedSessionWithSpy() async throws -> (SessionManager, UUID, SpyShellChannel) {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: CoordinatorTestKnownHostsStore()
        )

        let host = Host(
            id: UUID(),
            label: "Coordinator Test",
            folder: nil,
            hostname: "coordinator.test.local",
            port: 22,
            username: "ops",
            authMethod: .password,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: false,
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: .now
        )

        let session = try await manager.connect(to: host)
        let sessionID = session.id

        // Replace the mock shell channel with a spy that captures sent payloads.
        let spy = SpyShellChannel()
        manager.shellChannels[sessionID] = spy

        return (manager, sessionID, spy)
    }
}

// MARK: - Test Doubles

/// Minimal spy that captures all `send()` payloads without producing output.
private actor SpyShellChannel: SSHShellChannel {
    nonisolated let rawOutput: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private(set) var sentPayloads: [String] = []

    init() {
        var captured: AsyncStream<Data>.Continuation?
        self.rawOutput = AsyncStream<Data> { captured = $0 }
        self.continuation = captured!
    }

    func send(_ input: String) async throws {
        sentPayloads.append(input)
    }

    func resizePTY(columns: Int, rows: Int) async throws {}

    func close() async {
        continuation.finish()
    }
}

private actor CoordinatorTestKnownHostsStore: KnownHostsStoreProtocol {
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
