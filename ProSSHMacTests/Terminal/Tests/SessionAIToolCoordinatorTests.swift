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

    /// A timed-out command may still be running, at an `apt` [Y/n] for example: anything sent
    /// now would be typed into it.
    func testTimeoutSendsNothingToTheRunningCommand() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()

        let result = await manager.aiToolCoordinator.executeCommandAndWait(
            sessionID: sessionID,
            command: "apt upgrade",
            timeoutSeconds: 0.1
        )

        XCTAssertTrue(result.timedOut, "Command should have timed out")
        let payloads = await spy.sentPayloads
        XCTAssertEqual(payloads.count, 1, "Only the command line may be sent, got: \(payloads.debugDescription)")
    }

    /// The wrapper runs in each shell a host may use: the command sees the non-interactive
    /// settings, and afterwards the shell has its own values back, the new directory and the exit code.
    /// A line over 1,024 bytes never reaches a macOS shell, and the command shares the line.
    func testWrapperLeavesMostOfTheLineToTheCommand() {
        XCTAssertLessThan(SessionAIToolCoordinator.wrappedCommand("", token: "ABCDEF0123").utf8.count, 560)
    }

    func testWrapperScopesTheEnvironmentToTheCommandAndKeepsCd() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrapper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = "cd '\(directory.path)'; printf 'in:%s|%s|%s\\n' \"$PAGER\" \"$DEBIAN_FRONTEND\" \"${SYSTEMD_PAGER-unset}\"; "
            + "sh -c 'printf \"child:%s\\n\" \"$GIT_PAGER\"'; false"
        let wrapped = SessionAIToolCoordinator.wrappedCommand(command, token: "ABCDEF0123")
        let script = "PAGER='less -R'; export PAGER; unset GIT_PAGER DEBIAN_FRONTEND; cd /\n\(wrapped)\n"
            + "printf 'after:%s|%s|%s|%s\\n' \"$PAGER\" \"${GIT_PAGER-unset}\" \"${__o_PAGER-gone}\" \"$PWD\"\n"
            + "sh -c 'printf \"afterchild:%s\\n\" \"${DEBIAN_FRONTEND-unset}\"'\n"

        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/ksh", "/bin/dash"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertFalse(shells.isEmpty)
        for shell in shells {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let directoryPath = directory.resolvingSymlinksInPath().path

            XCTAssertTrue(output.contains("in:cat|noninteractive|\n"), "\(shell): \(output)")
            XCTAssertTrue(output.contains("child:cat\n"), "\(shell): \(output)")
            XCTAssertTrue(output.contains("\u{1B}]7777;PSW;ABCDEF0123;1\u{07}"), "\(shell) lost the exit code: \(output)")
            let after = try XCTUnwrap(output.components(separatedBy: "after:").last, shell)
            XCTAssertTrue(after.hasPrefix("less -R|unset|gone|"), "\(shell) leaked: \(output)")
            XCTAssertTrue(
                after.contains(directory.path) || after.contains(directoryPath),
                "\(shell) lost the cd: \(output)"
            )
            XCTAssertTrue(output.contains("afterchild:unset\n"), "\(shell) leaked to children: \(output)")
        }
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
        XCTAssertNil(manager.credentialPrompt, "the card goes with the wait")
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
        XCTAssertEqual(Array(payloads.dropFirst()), ["\u{03}"], "Ctrl+C goes to the waiting host, and nothing after it")
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
        XCTAssertNil(manager.credentialPrompt, "the card goes with the wait")
    }

    // MARK: - The card (Docs/CredentialPrompt.md Phase 2)

    func testCredentialPromptIsPublishedForTheCardAndFollowsTheWait() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let (execution, token) = try await startCommand("sudo whoami", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        XCTAssertNil(manager.credentialPrompt)

        feed("\u{1B}]7777;PSB;\(token)\u{07}[sudo] password for kevin: ", manager, sessionID)
        try await waitUntil { manager.credentialPrompt != nil }
        let request = try XCTUnwrap(manager.credentialPrompt)
        XCTAssertEqual(request.sessionID, sessionID)
        XCTAssertEqual(request.hostLabel, "Coordinator Test")
        XCTAssertEqual(request.prompt, "[sudo] password for kevin:")
        XCTAssertEqual(request.kind, .sudo)
        XCTAssertEqual(request.command, "sudo whoami")
        XCTAssertEqual(request.phase, .waiting)
        XCTAssertTrue(manager.isEnteringCredential(sessionID: sessionID))

        feed("\r\n", manager, sessionID)
        XCTAssertEqual(manager.credentialPrompt?.phase, .verifying)
        XCTAssertEqual(manager.credentialPrompt?.id, request.id, "the same card through Enter")
        feed("root\r\n", manager, sessionID)
        XCTAssertNil(manager.credentialPrompt)

        manager.aiToolCoordinator.completeToolCommand(sessionID: sessionID, token: token, exitCode: 0)
        _ = await execution.value
        XCTAssertNil(manager.credentialPrompt)
    }

    func testCancelCredentialPromptsInterruptsTheWaitingHostAndReturnsItsCommand() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let (execution, token) = try await startCommand("sudo -i", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        feed("\u{1B}]7777;PSB;\(token)\u{07}Password: ", manager, sessionID)
        try await waitUntil { manager.credentialPrompt != nil }

        await manager.cancelCredentialPrompts()

        let result = await execution.value
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.waitedForCredential)
        XCTAssertNil(manager.credentialPrompt)
        let payloads = await spy.sentPayloads
        XCTAssertEqual(payloads.dropFirst().first, "\u{03}", "Ctrl+C goes to the waiting host first")
    }

    // MARK: - Device CLI password prompts (Docs/CredentialPrompt.md Phase 3)

    func testDeviceEnablePasswordPausesWithoutTimeoutUntilAnswered() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let execution = try await startCLICommand("enable", on: manager, sessionID: sessionID, spy: spy, timeout: 0.6)

        feed("enable\r\nPassword: ", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID]?.phase == .waiting }
        let request = try XCTUnwrap(manager.credentialPrompt)
        XCTAssertEqual(request.prompt, "Password:")
        XCTAssertEqual(request.kind, .password)
        XCTAssertEqual(request.command, "enable")
        XCTAssertTrue(coordinator.isEnteringCredential(sessionID: sessionID))

        try await Task.sleep(for: .seconds(1.2))
        XCTAssertNotNil(coordinator.awaitingCredential[sessionID], "the timeout is suspended while waiting")

        feed("\r\n", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID]?.phase == .verifying }
        XCTAssertEqual(manager.credentialPrompt?.id, request.id)
        feed("router#", manager, sessionID)

        let result = await execution.value
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.finalPrompt, "router#")
        XCTAssertTrue(result.waitedForCredential)
        XCTAssertNil(manager.credentialPrompt)
    }

    func testDeviceWrongPasswordRaisesTheSameCardAgain() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let execution = try await startCLICommand("enable", on: manager, sessionID: sessionID, spy: spy, timeout: 5)

        feed("enable\r\nPassword: ", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID]?.phase == .waiting }
        let waitID = try XCTUnwrap(coordinator.awaitingCredential[sessionID]?.id)
        feed("\r\n", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID]?.phase == .verifying }
        feed("\r\nPassword: ", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID]?.phase == .waiting }
        XCTAssertEqual(coordinator.awaitingCredential[sessionID]?.id, waitID, "the card never blinks out between attempts")

        feed("\r\nrouter#", manager, sessionID)
        let result = await execution.value
        XCTAssertEqual(result.status, .completed)
        XCTAssertTrue(result.waitedForCredential)
    }

    func testDeclineAtADevicePasswordReturnsDeclinedAfterCtrlC() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let coordinator = manager.aiToolCoordinator
        let execution = try await startCLICommand("enable", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        feed("enable\r\nPassword: ", manager, sessionID)
        try await waitUntil { coordinator.awaitingCredential[sessionID] != nil }

        await coordinator.declineCredentialPrompt(sessionID: sessionID)

        let result = await execution.value
        XCTAssertEqual(result.status, .declined)
        XCTAssertTrue(result.waitedForCredential)
        XCTAssertNil(manager.credentialPrompt)
        let payloads = await spy.sentPayloads
        XCTAssertEqual(payloads, ["enable\r", "\u{03}"])
    }

    func testStopAtADevicePasswordSendsCtrlC() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let execution = try await startCLICommand("enable", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        feed("enable\r\nPassword: ", manager, sessionID)
        try await waitUntil { manager.credentialPrompt != nil }

        await manager.cancelCredentialPrompts()

        let result = await execution.value
        XCTAssertEqual(result.status, .failed)
        XCTAssertNil(manager.credentialPrompt)
        let payloads = await spy.sentPayloads
        XCTAssertEqual(payloads.last, "\u{03}")
    }

    func testCancellingADeviceCommandAtAPasswordSendsCtrlC() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let execution = try await startCLICommand("enable", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        feed("enable\r\nPassword: ", manager, sessionID)
        try await waitUntil { manager.credentialPrompt != nil }

        execution.cancel()

        let result = await execution.value
        XCTAssertEqual(result.status, .failed)
        XCTAssertNil(manager.credentialPrompt)
        let payloads = await spy.sentPayloads
        XCTAssertEqual(payloads.last, "\u{03}")
    }

    func testDevicePasswordLineFollowedByMoreOutputNeverPauses() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let execution = try await startCLICommand("show run | include Password:", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        feed("show run | include Password:\r\nPassword:\r\nrouter>", manager, sessionID)

        let result = await execution.value
        XCTAssertEqual(result.status, .completed)
        XCTAssertFalse(result.waitedForCredential)
        XCTAssertNil(manager.credentialPrompt)
    }

    // MARK: - Secret entry (Docs/CredentialPrompt.md Phase 1)

    func testCredentialPauseDuringSendDoesNotStartANewTimeout() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        var releaseSend = false
        spy.beforeStringSendReturns = { [self] payload in
            let marker = try token(from: payload)
            feed("\u{1B}]7777;PSB;\(marker)\u{07}Password: ", manager, sessionID)
            try await waitUntil { releaseSend }
        }
        let (execution, marker) = try await startCommand("sudo whoami", on: manager, sessionID: sessionID, spy: spy, timeout: 0.15)
        try await waitUntil { manager.credentialPrompt != nil }
        releaseSend = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(manager.credentialPrompt, "Registering the continuation after send must preserve the pause")
        manager.aiToolCoordinator.completeToolCommand(sessionID: sessionID, token: marker, exitCode: 0)
        let result = await execution.value
        XCTAssertFalse(result.timedOut)
    }

    func testPasswordIsNotRecordedWhenCompletionOccursDuringSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretSend.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionRecorder(recordingsDirectoryURL: directory)
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy(sessionRecorder: recorder)
        await manager.startRecording(sessionID: sessionID)
        let (execution, marker) = try await startCommand("sudo whoami", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        feed("\u{1B}]7777;PSB;\(marker)\u{07}Password: ", manager, sessionID)
        try await waitUntil { manager.credentialPrompt != nil }
        spy.beforeBytesSendReturns = {
            manager.aiToolCoordinator.completeToolCommand(sessionID: sessionID, token: marker, exitCode: 0)
        }
        let secret = "secret-during-send"
        await manager.sendRawShellInput(sessionID: sessionID, input: secret + "\r")
        _ = await execution.value
        XCTAssertNil(manager.credentialPrompt)
        XCTAssertTrue(spy.sentPayloads.contains(secret + "\r"))
        await manager.stopRecording(sessionID: sessionID)
        let recording = try recorder.loadLatestRecording(sessionID: sessionID)
        XCTAssertFalse(recording.chunks.map(\.text).joined().contains(secret))
        _ = await manager.terminalHistoryIndex.flushActiveCommand(sessionID: sessionID)
        let history = await manager.terminalHistoryIndex.recentCommands(sessionID: sessionID)
        XCTAssertFalse(history.contains { $0.command.contains(secret) })
    }

    func testDeviceAccessDeniedKeepsTheSameCredentialCard() async throws {
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy()
        let execution = try await startCLICommand("enable", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        feed("enable\r\nPassword: ", manager, sessionID)
        try await waitUntil { manager.credentialPrompt != nil }
        let originalID = manager.credentialPrompt?.id
        feed("\r\n% Access denied\r\n", manager, sessionID)
        try await waitUntil { manager.credentialPrompt?.phase == .verifying }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.credentialPrompt?.id, originalID)
        feed("Password: ", manager, sessionID)
        try await waitUntil { manager.credentialPrompt?.phase == .waiting }
        XCTAssertEqual(manager.credentialPrompt?.id, originalID)
        feed("\r\nrouter#", manager, sessionID)
        let result = await execution.value
        XCTAssertEqual(result.status, .completed)
    }

    /// A password typed at a copilot command's prompt reaches the host and is recorded nowhere.
    /// Host output takes the real path: parser reader, history index, recorder, engine, shellBuffers.
    func testTypedPasswordIsRecordedNowhere() async throws {
        let recordings = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecretEntry.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recordings) }
        let recorder = SessionRecorder(recordingsDirectoryURL: recordings)
        let (manager, sessionID, spy) = try await makeConnectedSessionWithSpy(sessionRecorder: recorder)
        let coordinator = manager.aiToolCoordinator
        manager.shellIOCoordinator.startParserReader(for: sessionID, rawOutput: spy.rawOutput)
        await manager.startRecording(sessionID: sessionID)

        func type(_ text: String) async {
            for byte in text.utf8 {
                await manager.sendRawShellInputBytes(
                    sessionID: sessionID, bytes: [byte], source: .hardwareKeyCapture, eventType: "key_down"
                )
            }
        }
        func screen() -> String {
            (manager.shellBuffers[sessionID] ?? []).joined(separator: "\n")
        }

        let (execution, token) = try await startCommand("sudo whoami", on: manager, sessionID: sessionID, spy: spy, timeout: 5)
        spy.emit("\u{1B}]7777;PSB;\(token)\u{07}[sudo] password for kevin: ")
        try await waitUntil { screen().contains("[sudo] password for kevin:") }
        XCTAssertNil(coordinator.awaitingCredential[sessionID], "the first key must land inside the idle window")
        await type("h")
        try await waitUntil { coordinator.awaitingCredential[sessionID]?.phase == .waiting }
        await type("unter2-SEC")
        await manager.sendRawShellInput(sessionID: sessionID, input: "RET")  // a paste
        await type("\r")
        let sent = await spy.sentPayloads.joined()
        XCTAssertTrue(sent.contains("hunter2-SECRET\r"), "the password must still reach the host")

        // The host never echoes a password.
        spy.emit("\r\nroot\r\n\u{1B}]7777;PSW;\(token);0\u{07}ops@host:~$ ")
        let result = await execution.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.waitedForCredential)
        XCTAssertNil(coordinator.awaitingCredential[sessionID])

        // An ordinary command afterwards is recorded as usual, with nothing glued onto it.
        await type("ls\r")
        spy.emit("ls\r\nfile.txt\r\nops@host:~$ ")
        try await waitUntil { screen().contains("file.txt") }

        func assertNoSecret(_ text: String, _ place: String, file: StaticString = #filePath, line: UInt = #line) {
            for fragment in ["hunter2", "SECRET", "unter2-SEC", "RET\r"] {
                XCTAssertFalse(text.contains(fragment), "\(place) contains '\(fragment)'", file: file, line: line)
            }
        }
        XCTAssertTrue(result.output.contains("root"))
        assertNoSecret(result.output, "the tool's commandOutput")
        assertNoSecret(screen(), "shellBuffers (and so the per-turn screen snapshot)")
        let engine = try XCTUnwrap(manager.engines[sessionID])
        assertNoSecret(await engine.visibleText().joined(separator: "\n"), "the terminal screen")

        let history = manager.terminalHistoryIndex
        assertNoSecret(await history.activeCommandRawOutput(sessionID: sessionID) ?? "", "the history index's raw output")
        _ = await history.flushActiveCommand(sessionID: sessionID)
        let commands = await history.recentCommands(sessionID: sessionID)
        XCTAssertEqual(commands.first?.command, "ls")
        for block in commands {
            assertNoSecret(block.command, "a history command")
            assertNoSecret(block.output, "a history command's output")
        }

        await manager.stopRecording(sessionID: sessionID)
        let recording = try recorder.loadLatestRecording(sessionID: sessionID)
        let input = recording.chunks.filter { $0.stream == .input }.map(\.text).joined()
        let output = recording.chunks.filter { $0.stream == .output }.map(\.text).joined()
        let payloads = await spy.sentPayloads
        let wrapper = try XCTUnwrap(payloads.first)
        XCTAssertEqual(input, wrapper + "ls\r", "the copilot's command and the ordinary one, nothing typed at the prompt")
        assertNoSecret(output, "the recording's output")
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

    /// Starts a device CLI command at a `router>` prompt once its line is sent.
    private func startCLICommand(
        _ command: String,
        on manager: SessionManager,
        sessionID: UUID,
        spy: SpyShellChannel,
        timeout: TimeInterval
    ) async throws -> Task<CLICommandResult, Never> {
        manager.shellBuffers[sessionID] = ["router> "]
        let before = await spy.sentPayloads.count
        let execution = Task {
            await manager.aiToolCoordinator.executeCLICommand(
                sessionID: sessionID, command: command, timeoutSeconds: timeout
            )
        }
        try await waitForPayloads(spy, count: before + 1)
        return execution
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
    private func makeConnectedSessionWithSpy(
        sessionRecorder: SessionRecorder = SessionRecorder()
    ) async throws -> (SessionManager, UUID, SpyShellChannel) {
        let manager = SessionManager(
            transport: MockSSHTransport(),
            knownHostsStore: CoordinatorTestKnownHostsStore(),
            sessionRecorder: sessionRecorder
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

        // Stop the original mock reader before replacing its channel. Its buffered connection
        // banner must not arrive inside the spy's scripted command/password output.
        let originalReader = manager.shellIOCoordinator.parserReaderTasks[sessionID]
        manager.shellIOCoordinator.cancelParserTask(for: sessionID)
        await originalReader?.value

        // Replace the mock shell channel with a spy that captures sent payloads.
        let spy = SpyShellChannel()
        manager.shellChannels[sessionID] = spy

        return (sessionID, spy)
    }
}

// MARK: - Test Doubles

/// Minimal spy that captures all `send()` payloads; produces output only through `emit`.
@MainActor private final class SpyShellChannel: SSHShellChannel {
    let rawOutput: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private(set) var sentPayloads: [String] = []
    var beforeStringSendReturns: ((String) async throws -> Void)?
    var beforeBytesSendReturns: (() -> Void)?

    init() {
        var captured: AsyncStream<Data>.Continuation?
        self.rawOutput = AsyncStream<Data> { captured = $0 }
        self.continuation = captured!
    }

    func send(_ input: String) async throws {
        sentPayloads.append(input)
        try await beforeStringSendReturns?(input)
    }

    func send(bytes: [UInt8]) async throws {
        sentPayloads.append(String(decoding: bytes, as: UTF8.self))
        beforeBytesSendReturns?()
    }

    func resizePTY(columns: Int, rows: Int) async throws {}

    /// Output as the host would send it.
    func emit(_ text: String) {
        continuation.yield(Data(text.utf8))
    }

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
