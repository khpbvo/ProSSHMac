// SessionAIToolCoordinatorTests.swift
// ProSSHMac
//
// Regression tests for invisible AI command completion and echoed-input filtering.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class SessionAIToolCoordinatorTests: XCTestCase {

    func testPrivateOSCCompletionHidesEchoAndReturnsOutputAndExitCode() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let execution = Task {
            await manager.aiToolCoordinator.executeCommandAndWait(
                sessionID: sessionID, command: "printf hello", timeoutSeconds: 3
            )
        }
        for _ in 0..<100 {
            if !(await spy.sentPayloads).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sentPayloads = await spy.sentPayloads
        let payload = try XCTUnwrap(sentPayloads.first)
        XCTAssertTrue(payload.contains("\\033]7777;PSW;"))
        XCTAssertFalse(payload.contains("__PSW_"))
        XCTAssertFalse(payload.contains("\u{1B}[8m"))
        let tokenPattern = try NSRegularExpression(pattern: "'([0-9A-F]{10})'")
        let match = try XCTUnwrap(tokenPattern.firstMatch(in: payload, range: NSRange(payload.startIndex..., in: payload)))
        let tokenRange = try XCTUnwrap(Range(match.range(at: 1), in: payload))
        let token = String(payload[tokenRange])

        let echoed = payload.replacingOccurrences(of: "\n", with: "\r\n")
        let stream = Array((echoed + "\u{1B}]7777;PSB;\(token)\u{07}hello\r\n\u{1B}]7777;PSW;\(token);7\u{07}").utf8)
        let engine = try XCTUnwrap(manager.engines[sessionID])
        var visible = Data()
        for offset in stride(from: 0, to: stream.count, by: 13) {
            let chunk = Data(stream[offset..<min(offset + 13, stream.count)])
            let filtered = manager.aiToolCoordinator.filterToolOutput(sessionID: sessionID, chunk: chunk)
            visible.append(filtered)
            await engine.feed(filtered)
        }
        let result = await execution.value
        XCTAssertEqual(result.output, "hello")
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.timedOut)
        let visibleText = String(decoding: visible, as: UTF8.self)
        XCTAssertFalse(visibleText.contains("printf hello"))
        XCTAssertTrue(visibleText.contains("\u{1B}]7777;PSW;\(token);7\u{07}"), "Private OSC must reach the parser")
        let screenText = await engine.visibleText().joined()
        XCTAssertFalse(screenText.contains("PSW"))
    }

    func testLocalZshToolCycleLeavesNoWrapperOnScreen() async throws {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: CoordinatorTestKnownHostsStore()
        )
        let session = try await manager.openLocalSession(shellPath: "/bin/zsh")
        let result = await manager.executeCommandAndWait(
            sessionID: session.id,
            command: "printf 'tool-cycle-ok\\n'; false",
            timeoutSeconds: 8
        )
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.output, "tool-cycle-ok")
        let screen = await manager.engines[session.id]?.visibleText().joined(separator: "\n") ?? ""
        XCTAssertTrue(screen.contains("tool-cycle-ok"))
        XCTAssertFalse(screen.contains("7777;PSW"))
        XCTAssertFalse(screen.contains("__ps=$?"))
        let malformed = await manager.executeCommandAndWait(
            sessionID: session.id, command: "if", timeoutSeconds: 3
        )
        XCTAssertFalse(malformed.timedOut, "A syntax error must still reach the private completion event")
        XCTAssertNotEqual(malformed.exitCode, 0)
        XCTAssertFalse(malformed.output.contains("7777;PSW"))
        await manager.disconnect(sessionID: session.id)
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
@MainActor private final class SpyShellChannel: SSHShellChannel {
    let rawOutput: AsyncStream<Data>
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

    func send(bytes: [UInt8]) async throws {
        sentPayloads.append(String(decoding: bytes, as: UTF8.self))
    }

    func resizePTY(columns: Int, rows: Int) async throws {}

    func close() async {
        continuation.finish()
    }
}

@MainActor private final class CoordinatorTestKnownHostsStore: KnownHostsStoreProtocol {
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
