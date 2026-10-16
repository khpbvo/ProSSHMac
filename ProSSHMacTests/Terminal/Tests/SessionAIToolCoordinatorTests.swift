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

    /// A scripted device: echo, one page and a `--More--` pager, then the rest and the prompt.
    func testCLICommandPagesThroughAFakeDeviceAndLeavesOutputVisible() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        manager.shellBuffers[sessionID] = ["Switch# "]
        let execution = Task {
            await manager.aiToolCoordinator.executeCLICommand(
                sessionID: sessionID, command: "show running-config", timeoutSeconds: 5
            )
        }
        try await waitForPayloads(spy, count: 1)
        let firstPayloads = await spy.sentPayloads
        XCTAssertEqual(firstPayloads, ["show running-config\r"], "sent as Enter would, no shell wrapper")

        func device(_ text: String) -> Data {
            let chunk = Data(text.utf8)
            let visible = manager.aiToolCoordinator.filterToolOutput(sessionID: sessionID, chunk: chunk)
            XCTAssertEqual(visible, chunk, "device output must stay visible in the terminal")
            return visible
        }
        _ = device("show running-config\r\nhostname Switch\r\n")
        _ = device("interface Gi0/1\r\n --More-- ")
        try await waitForPayloads(spy, count: 2)
        let pagerPayloads = await spy.sentPayloads
        XCTAssertEqual(pagerPayloads.last, " ", "the pager is answered with Space")

        _ = device(String(repeating: "\u{08}", count: 10) + " shutdown\r\nend\r\nSwitch#")
        let result = await execution.value
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.output, "hostname Switch\ninterface Gi0/1\n shutdown\nend")
        XCTAssertEqual(result.finalPrompt, "Switch#")
        XCTAssertEqual(result.pagesAdvanced, 1)
        let finalPayloads = await spy.sentPayloads
        XCTAssertEqual(finalPayloads.count, 2, "one command, one page")
    }

    // MARK: - Credential prompts (Docs/CredentialPrompt.md Phase 0)

    func testPasswordPromptPausesTheCommandWithoutTimeoutUntilTheUserAnswers() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let (execution, token) = try await startCommand("sudo whoami", on: manager, sessionID: sessionID, spy: spy, timeout: 0.6)

        feed("\u{1B}]7777;PSB;\(token)\u{07}[sudo] password for kevin: ", manager, sessionID)
        XCTAssertNil(coordinator.awaitingCredential[sessionID], "a prompt counts only after the idle window")
        try await waitUntil { coordinator.awaitingCredential[sessionID]?.phase == .waiting }
        let wait = try XCTUnwrap(coordinator.awaitingCredential[sessionID])
        XCTAssertEqual(wait.prompt, "[sudo] password for kevin:")
        XCTAssertEqual(wait.kind, .sudo)
        XCTAssertEqual(wait.command, "sudo whoami")

        try await Task.sleep(for: .seconds(1.2))
        XCTAssertNotNil(coordinator.awaitingCredential[sessionID], "the timeout is suspended while waiting")

        feed("\r\n", manager, sessionID)
        XCTAssertEqual(coordinator.awaitingCredential[sessionID]?.phase, .verifying)
        feed("root\r\n", manager, sessionID)
        XCTAssertNil(coordinator.awaitingCredential[sessionID], "output past the prompt ends the wait")
        coordinator.completeToolCommand(sessionID: sessionID, token: token, exitCode: 0)

        let result = await execution.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.waitedForCredential)
        XCTAssertFalse(result.declinedCredential)
        XCTAssertEqual(result.output, "[sudo] password for kevin: \nroot")
    }

    func testPasswordLineFollowedByMoreOutputNeverPauses() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let (execution, token) = try await startCommand("cat notes.txt", on: manager, sessionID: sessionID, spy: spy, timeout: 0.8)

        feed("\u{1B}]7777;PSB;\(token)\u{07}Password:", manager, sessionID)
        try await Task.sleep(for: .milliseconds(50))
        feed(" stored in the vault\r\ndone", manager, sessionID)

        let result = await execution.value
        XCTAssertTrue(result.timedOut, "the normal timeout still applies")
        XCTAssertFalse(result.waitedForCredential)
        XCTAssertNil(coordinator.awaitingCredential[sessionID])
    }

    func testWrongPasswordsKeepTheWaitUntilSudoGivesUp() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let (execution, token) = try await startCommand("sudo true", on: manager, sessionID: sessionID, spy: spy, timeout: 5)

        feed("\u{1B}]7777;PSB;\(token)\u{07}[sudo] password for kevin: ", manager, sessionID)
        for _ in 0..<2 {
            try await waitUntil { coordinator.awaitingCredential[sessionID]?.phase == .waiting }
            feed("\r\n", manager, sessionID)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(coordinator.awaitingCredential[sessionID]?.phase, .verifying)
            feed("Sorry, try again.\r\n[sudo] password for kevin: ", manager, sessionID)
            XCTAssertNotNil(coordinator.awaitingCredential[sessionID], "the wait never disappears between attempts")
        }
        try await waitUntil { coordinator.awaitingCredential[sessionID]?.phase == .waiting }
        feed("\r\nsudo: 3 incorrect password attempts\r\n", manager, sessionID)
        XCTAssertNil(coordinator.awaitingCredential[sessionID])
        coordinator.completeToolCommand(sessionID: sessionID, token: token, exitCode: 1)

        let result = await execution.value
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.waitedForCredential)
        XCTAssertTrue(result.output.hasSuffix("sudo: 3 incorrect password attempts"))
    }

    func testPwfeedbackAsterisksDoNotEndTheWait() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let (execution, token) = try await startCommand("sudo -v", on: manager, sessionID: sessionID, spy: spy, timeout: 5)

        feed("\u{1B}]7777;PSB;\(token)\u{07}[sudo] password for kevin: ", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID]?.phase == .waiting }
        for _ in 0..<3 {
            feed("*", manager, sessionID)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(coordinator.awaitingCredential[sessionID]?.phase, .waiting)
        XCTAssertEqual(coordinator.awaitingCredential[sessionID]?.prompt, "[sudo] password for kevin:")

        coordinator.completeToolCommand(sessionID: sessionID, token: token, exitCode: 0)
        _ = await execution.value
    }

    func testDeclineSendsCtrlCAndReturnsDeclined() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let (execution, token) = try await startCommand("sudo apt update", on: manager, sessionID: sessionID, spy: spy, timeout: 5)

        feed("\u{1B}]7777;PSB;\(token)\u{07}[sudo] password for kevin: ", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID] != nil }
        await coordinator.declineCredentialPrompt(sessionID: sessionID)

        let result = await execution.value
        XCTAssertTrue(result.declinedCredential)
        XCTAssertTrue(result.waitedForCredential)
        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.exitCode)
        XCTAssertNil(coordinator.awaitingCredential[sessionID])
        let payloads = await spy.sentPayloads
        XCTAssertEqual(payloads.last, "\u{03}")
    }

    func testCancellationWhileWaitingSendsCtrlC() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let (execution, token) = try await startCommand("sudo -i", on: manager, sessionID: sessionID, spy: spy, timeout: 5)

        feed("\u{1B}]7777;PSB;\(token)\u{07}Password: ", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID] != nil }
        execution.cancel()

        let result = await execution.value
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.waitedForCredential)
        XCTAssertNil(coordinator.awaitingCredential[sessionID])
        let payloads = await spy.sentPayloads
        XCTAssertEqual(payloads.count, 3)
        XCTAssertEqual(payloads.dropFirst().first, "\u{03}", "Ctrl+C goes to the waiting host first")
        XCTAssertEqual(payloads.last, "\u{1B}[0m\n")
    }

    func testSecondSessionPromptsAfterTheFirstResolves() async throws {
        let (manager, firstID, firstSpy) = try await makeConnectedSessionWithSpy()
        let (secondID, secondSpy) = try await addConnectedSession(to: manager, label: "Second")
        let coordinator = manager.aiToolCoordinator

        for (sessionID, spy, otherID) in [(firstID, firstSpy, secondID), (secondID, secondSpy, firstID)] {
            let (execution, token) = try await startCommand("sudo id", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
            feed("\u{1B}]7777;PSB;\(token)\u{07}[sudo] password for kevin: ", manager, sessionID)
            try await waitUntil { coordinator.awaitingCredential[sessionID] != nil }
            XCTAssertNil(coordinator.awaitingCredential[otherID])
            XCTAssertEqual(coordinator.awaitingCredential.count, 1)
            feed("\r\nuid=0(root)\r\n", manager, sessionID)
            coordinator.completeToolCommand(sessionID: sessionID, token: token, exitCode: 0)
            let result = await execution.value
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(result.waitedForCredential)
            XCTAssertTrue(coordinator.awaitingCredential.isEmpty)
        }
    }

    func testSupersedeWhileWaitingInterruptsThePromptBeforeTheNewCommand() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let (first, firstToken) = try await startCommand("sudo ls /root", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        feed("\u{1B}]7777;PSB;\(firstToken)\u{07}[sudo] password for kevin: ", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID] != nil }

        let (second, secondToken) = try await startCommand("uptime", on: manager, sessionID: sessionID, spy: spy, timeout: 5, expectedPayloads: 3)
        let firstResult = await first.value
        XCTAssertTrue(firstResult.timedOut)
        XCTAssertEqual(firstResult.output, "A newer command started in this session.")
        XCTAssertTrue(firstResult.waitedForCredential)
        try await Task.sleep(for: .milliseconds(100))
        let payloads = await spy.sentPayloads
        XCTAssertEqual(payloads.count, 3, "no reset line after a supersede: it would be typed into the new command")
        XCTAssertEqual(payloads[1], "\u{03}", "the new command must not be typed into the password prompt")
        XCTAssertTrue(payloads[2].contains(secondToken))
        XCTAssertNil(coordinator.awaitingCredential[sessionID])

        coordinator.completeToolCommand(sessionID: sessionID, token: secondToken, exitCode: 0)
        let secondResult = await second.value
        XCTAssertFalse(secondResult.waitedForCredential)
    }

    func testTimeoutRestartsInFullOnceTheUserAnswers() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let (execution, token) = try await startCommand("sudo sleep 60", on: manager, sessionID: sessionID, spy: spy, timeout: 0.6)

        feed("\u{1B}]7777;PSB;\(token)\u{07}[sudo] password for kevin: ", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID] != nil }
        try await Task.sleep(for: .seconds(1))
        let answeredAt = ContinuousClock.now
        feed("\r\n", manager, sessionID)

        let result = await execution.value
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.waitedForCredential)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - answeredAt, .milliseconds(550))
        XCTAssertNil(coordinator.awaitingCredential[sessionID])
    }

    func testSessionEndingWhileWaitingReturnsTheCommand() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let (execution, token) = try await startCommand("sudo reboot", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        feed("\u{1B}]7777;PSB;\(token)\u{07}[sudo] password for kevin: ", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID] != nil }

        await manager.disconnect(sessionID: sessionID)
        let result = await execution.value
        XCTAssertEqual(result.output, "The session ended before the command finished.")
        XCTAssertTrue(result.waitedForCredential)
        XCTAssertNil(coordinator.awaitingCredential[sessionID])
    }

    // MARK: - Helpers

    private func waitForPayloads(_ spy: SpyShellChannel, count: Int) async throws {
        for _ in 0..<200 {
            if await spy.sentPayloads.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(count) payloads")
    }

    /// Starts an awaited command and returns it with its marker token once the wrapper is sent.
    private func startCommand(
        _ command: String,
        on manager: SessionManager,
        sessionID: UUID,
        spy: SpyShellChannel,
        timeout: TimeInterval,
        expectedPayloads: Int? = nil
    ) async throws -> (Task<CommandExecutionResult, Never>, String) {
        let before = await spy.sentPayloads.count
        let execution = Task {
            await manager.aiToolCoordinator.executeCommandAndWait(
                sessionID: sessionID, command: command, timeoutSeconds: timeout
            )
        }
        try await waitForPayloads(spy, count: expectedPayloads ?? before + 1)
        let payloads = await spy.sentPayloads
        let payload = try XCTUnwrap(payloads.last)
        return (execution, try token(from: payload))
    }

    private func token(from payload: String) throws -> String {
        let tokenPattern = try NSRegularExpression(pattern: "'([0-9A-F]{10})'")
        let match = try XCTUnwrap(tokenPattern.firstMatch(in: payload, range: NSRange(payload.startIndex..., in: payload)))
        let tokenRange = try XCTUnwrap(Range(match.range(at: 1), in: payload))
        return String(payload[tokenRange])
    }

    /// Host output as the parser reader hands it to the coordinator.
    private func feed(_ text: String, _ manager: SessionManager, _ sessionID: UUID) {
        _ = manager.aiToolCoordinator.filterToolOutput(sessionID: sessionID, chunk: Data(text.utf8))
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Condition not met within \(timeout)", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Creates a SessionManager with a connected session, then swaps in a SpyShellChannel.
    private func makeConnectedSessionWithSpy() async throws -> (SessionManager, UUID, SpyShellChannel) {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: CoordinatorTestKnownHostsStore()
        )
        let (sessionID, spy) = try await addConnectedSession(to: manager, label: "Coordinator Test")
        return (manager, sessionID, spy)
    }

    private func addConnectedSession(to manager: SessionManager, label: String) async throws -> (UUID, SpyShellChannel) {
        let host = Host(
            id: UUID(),
            label: label,
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

        return (sessionID, spy)
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
