// ShellIntegrationEchoFilterTests.swift
// ProSSHMac
//
// Bug 90: the shell-integration line typed into a remote shell must leave no trace on the
// screen, in the history index or in a recording.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class ShellIntegrationEchoFilterTests: XCTestCase {

    private let token = "A1B2C3D4E5"
    private let prompt = "user@host:~$ "

    // MARK: - The injected line

    func testInjectionLineEndsWithTheMarkerAfterTheGuardAndFitsOneLine() throws {
        for type in [ShellIntegrationType.zsh, .bash, .fish, .posixSh] {
            let script = try XCTUnwrap(ShellIntegrationScripts.sshInjectionScript(for: type))
            let line = try XCTUnwrap(ShellIntegrationScripts.sshInjectionLine(for: type, token: token))
            XCTAssertTrue(line.hasPrefix(script + "; printf "), "\(type): the marker must follow the closed guard")
            XCTAssertTrue(line.hasSuffix("'\(token)'"), "\(type): the token is a separate printf argument")
            XCTAssertTrue(line.contains("7777;PSI;%s"), "\(type)")
            XCTAssertTrue(line.contains("[K'"), "\(type): CR + erase-line must follow the marker")
            XCTAssertFalse(line.contains("\n"), "\(type)")
            XCTAssertFalse(line.contains("\u{1B}"), "\(type): the echo must never contain the marker bytes")
            XCTAssertLessThan(line.utf8.count, 1_024, "\(type): a longer line never reaches a macOS shell")
        }
        XCTAssertNil(ShellIntegrationScripts.sshInjectionLine(for: .none, token: token))
        XCTAssertNil(ShellIntegrationScripts.sshInjectionLine(for: .ciscoIOS, token: token))
    }

    // MARK: - The filter

    func testReadlineEchoIsHiddenAndOnePromptRemains() async throws {
        let engine = TerminalEngine(columns: 80, rows: 24)
        await engine.feed(Array("Welcome to Ubuntu\r\n\(prompt)".utf8))

        var filter = ShellIntegrationEchoFilter(token: token)
        var released = false
        let stream = Array(bashOutput(forLine: line(.bash)).utf8)
        for offset in stride(from: 0, to: stream.count, by: 13) {
            let chunk = Data(stream[offset..<min(offset + 13, stream.count)])
            if released {
                await engine.feed(chunk)
            } else if let visible = filter.process(chunk) {
                released = true
                await engine.feed(visible)
            }
        }

        XCTAssertTrue(released, "The marker must end the hold")
        let screen = await engine.visibleText().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        XCTAssertEqual(screen, ["Welcome to Ubuntu", "user@host:~$"])
        let cursor = await engine.cursor
        XCTAssertEqual(cursor.row, 1)
        XCTAssertEqual(cursor.col, prompt.count, "The new prompt must start at column 0 of the old one")
    }

    func testAMarkerWithAnotherTokenKeepsHolding() {
        var filter = ShellIntegrationEchoFilter(token: token)
        let other = String(decoding: ShellIntegrationScripts.injectionEndMarker(token: "FFFFFFFFFF"), as: UTF8.self)
        XCTAssertNil(filter.process(Data("echo\r\n\(other)\(prompt)".utf8)))
        let mine = String(decoding: ShellIntegrationScripts.injectionEndMarker(token: token), as: UTF8.self)
        XCTAssertEqual(filter.process(Data("\(mine)\r\u{1B}[K\(prompt)".utf8)), Data("\r\u{1B}[K\(prompt)".utf8))
    }

    func testByteCapPassesEverythingHeldInOrder() {
        var filter = ShellIntegrationEchoFilter(token: token, byteCap: 32)
        XCTAssertNil(filter.process(Data("bash: syntax error ".utf8)))
        XCTAssertEqual(
            filter.process(Data("near unexpected token\r\n".utf8)),
            Data("bash: syntax error near unexpected token\r\n".utf8)
        )
    }

    func testRequestedReleasePassesEverythingHeldOnTheNextBatch() {
        var filter = ShellIntegrationEchoFilter(token: token)
        XCTAssertNil(filter.process(Data("fish: Unknown command\r\n\(prompt)".utf8)))
        filter.requestRelease()
        XCTAssertEqual(filter.process(Data()), Data("fish: Unknown command\r\n\(prompt)".utf8))
    }

    // MARK: - Injection through a session

    func testInjectionWaitsForAPromptHidesTheEchoAndRecordsNothing() async throws {
        let (manager, sessionID, spy) = try await makeSession()
        spy.emit("\r\nWelcome to Ubuntu 24.04 LTS\r\n")
        let injection = Task { await manager.shellIOCoordinator.injectShellIntegration(sessionID: sessionID, type: .bash) }

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(spy.sentPayloads.isEmpty, "Nothing may be sent while the cursor sits at column 0")

        spy.emit(prompt)
        let result = await injection.value
        XCTAssertEqual(result, .injected)
        let payload = try XCTUnwrap(spy.sentPayloads.first)
        XCTAssertEqual(spy.sentPayloads.count, 1)
        XCTAssertEqual(payload, try XCTUnwrap(ShellIntegrationScripts.sshInjectionLine(for: .bash, token: tokenIn(payload))) + "\n")

        let columns = try await XCTUnwrapAsync(await manager.engines[sessionID]?.columns)
        // A title sequence after the shell's output tells the test when all of it was parsed.
        spy.emit(bashOutput(forLine: String(payload.dropLast()), columns: columns) + "\u{1B}]0;parsed\u{07}")
        let deadline = ContinuousClock.now + .seconds(5)
        while await manager.engines[sessionID]?.windowTitle != "parsed" {
            guard ContinuousClock.now < deadline else { return XCTFail("The output never reached the parser") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let screen = await screenText(manager, sessionID)
        XCTAssertFalse(screen.contains("__PROSSH"), screen)
        XCTAssertEqual(screen.components(separatedBy: "user@host:~$").count - 1, 1, screen)
        XCTAssertFalse(screen.contains("PSI"), screen)
        let commands = await manager.terminalHistoryIndex.recentCommands(sessionID: sessionID)
        XCTAssertTrue(commands.isEmpty, "The setup line is not a user command")
    }

    func testShellThatNeverLooksReadyGetsNothing() async throws {
        let (manager, sessionID, spy) = try await makeSession()
        manager.shellIOCoordinator.shellIntegrationTiming.readinessTimeout = .milliseconds(700)
        spy.emit("\r\nRunning a login menu...\r\n")

        let result = await manager.shellIOCoordinator.injectShellIntegration(sessionID: sessionID, type: .bash)
        XCTAssertEqual(result, .skipped(.notReady))
        XCTAssertTrue(spy.sentPayloads.isEmpty)
    }

    func testUserTypingBeforeThePromptIsReadySkipsTheInjection() async throws {
        let (manager, sessionID, spy) = try await makeSession()
        spy.emit("\r\nWelcome\r\n")
        let injection = Task { await manager.shellIOCoordinator.injectShellIntegration(sessionID: sessionID, type: .bash) }
        try await Task.sleep(for: .milliseconds(100))
        await manager.sendRawShellInput(sessionID: sessionID, input: "ls")
        spy.emit(prompt + "ls")

        let result = await injection.value
        XCTAssertEqual(result, .skipped(.userInput))
        XCTAssertEqual(spy.sentPayloads, ["ls"])
    }

    func testMissingMarkerReleasesHeldOutputAfterTheTimeout() async throws {
        let (manager, sessionID, spy) = try await makeSession()
        manager.shellIOCoordinator.shellIntegrationTiming.releaseTimeout = .milliseconds(400)
        spy.emit("\r\n\(prompt)")
        let result = await manager.shellIOCoordinator.injectShellIntegration(sessionID: sessionID, type: .bash)
        XCTAssertEqual(result, .injected)

        spy.emit("fish: Unknown command: then\r\nmyhost> ")
        try await Task.sleep(for: .milliseconds(150))
        let held = await screenText(manager, sessionID)
        XCTAssertFalse(held.contains("Unknown command"), "Output is held until the marker or the timeout")

        try await waitForScreen(manager, sessionID) { $0.contains("Unknown command") && $0.contains("myhost>") }
    }

    // MARK: - Real shells

    func testRealBashShowsNoSetupLine() async throws {
        try await assertRealShellShowsNoSetupLine(shellPath: "/bin/bash", type: .bash)
    }

    func testRealZshShowsNoSetupLine() async throws {
        try await assertRealShellShowsNoSetupLine(shellPath: "/bin/zsh", type: .zsh)
    }

    private func assertRealShellShowsNoSetupLine(shellPath: String, type: ShellIntegrationType) async throws {
        let manager = SessionManager(transport: MockSSHTransport(), knownHostsStore: EchoFilterTestKnownHostsStore())
        // The marker, not the timeout, must end the hold.
        manager.shellIOCoordinator.shellIntegrationTiming.releaseTimeout = .seconds(30)
        let session = try await manager.openLocalSession(shellPath: shellPath)
        defer { Task { await manager.disconnect(sessionID: session.id) } }

        let result = await manager.shellIOCoordinator.injectShellIntegration(sessionID: session.id, type: type)
        XCTAssertEqual(result, .injected)
        let deadline = ContinuousClock.now + .seconds(8)
        while manager.shellIOCoordinator.isHoldingShellIntegrationEcho(sessionID: session.id) {
            guard ContinuousClock.now < deadline else {
                return XCTFail("\(shellPath) never printed the end marker")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300))
        let screen = await screenText(manager, session.id)
        XCTAssertFalse(screen.contains("__PROSSH"), "\(shellPath) screen:\n\(screen)")
        XCTAssertFalse(screen.contains("PSI"), "\(shellPath) screen:\n\(screen)")
        let commands = await manager.terminalHistoryIndex.recentCommands(sessionID: session.id)
        XCTAssertTrue(commands.isEmpty, "The setup line is not a user command")
    }

    // MARK: - Helpers

    private func line(_ type: ShellIntegrationType) -> String {
        ShellIntegrationScripts.sshInjectionLine(for: type, token: token)!
    }

    private func tokenIn(_ payload: String) throws -> String {
        let pattern = try NSRegularExpression(pattern: "'([0-9A-F]{10})'\\n$")
        let match = try XCTUnwrap(pattern.firstMatch(in: payload, range: NSRange(payload.startIndex..., in: payload)))
        return String(payload[try XCTUnwrap(Range(match.range(at: 1), in: payload))])
    }

    /// What bash prints for the typed line at a `columns`-wide prompt, as recorded from a real pty:
    /// readline's echo with ` \r` at each wrap, CR LF, the script's marks, the end marker and
    /// CR + erase-line, then PROMPT_COMMAND's marks and the new prompt.
    private func bashOutput(forLine line: String, columns: Int = 80) -> String {
        var echo = ""
        var column = prompt.count
        for character in line {
            echo.append(character)
            column += 1
            if column == columns {
                echo += " \r"
                column = 0
            }
        }
        let token = line.suffix(11).dropLast()
        let marker = String(decoding: ShellIntegrationScripts.injectionEndMarker(token: String(token)), as: UTF8.self)
        return echo + "\r\n"
            + "\u{1B}]133;C\u{1B}\\\u{1B}]133;A\u{1B}\\\u{1B}]133;C\u{1B}\\"
            + marker + "\r\u{1B}[K"
            + "\u{1B}]133;D;0\u{1B}\\\u{1B}]133;A\u{1B}\\" + prompt
    }

    private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }

    private func screenText(_ manager: SessionManager, _ sessionID: UUID) async -> String {
        await manager.engines[sessionID]?.visibleText().joined(separator: "\n") ?? ""
    }

    private func waitForScreen(
        _ manager: SessionManager,
        _ sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: (String) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let screen = await screenText(manager, sessionID)
            if condition(screen) { return }
            guard ContinuousClock.now < deadline else {
                return XCTFail("Screen never matched:\n\(screen)", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// An SSH session whose shell channel is a spy, read by the real parser pipeline.
    private func makeSession() async throws -> (SessionManager, UUID, EchoFilterSpyShellChannel) {
        let manager = SessionManager(transport: MockSSHTransport(), knownHostsStore: EchoFilterTestKnownHostsStore())
        let host = Host(
            id: UUID(), label: "Echo Filter Test", folder: nil, hostname: "echo.test.local", port: 22,
            username: "ops", authMethod: .password, keyReference: nil, certificateReference: nil,
            passwordReference: nil, jumpHost: nil, algorithmPreferences: nil, pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: false, legacyModeEnabled: false, tags: [], notes: nil,
            lastConnected: nil, createdAt: .now
        )
        let session = try await manager.connect(to: host)
        let originalReader = manager.shellIOCoordinator.parserReaderTasks[session.id]
        manager.shellIOCoordinator.cancelParserTask(for: session.id)
        await originalReader?.value

        let spy = EchoFilterSpyShellChannel()
        manager.shellChannels[session.id] = spy
        manager.shellIOCoordinator.startParserReader(for: session.id, rawOutput: spy.rawOutput)
        manager.bytesSentBySessionID[session.id] = 0
        return (manager, session.id, spy)
    }
}

// MARK: - Test Doubles

@MainActor private final class EchoFilterSpyShellChannel: SSHShellChannel {
    let rawOutput: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private(set) var sentPayloads: [String] = []

    init() {
        var captured: AsyncStream<Data>.Continuation?
        self.rawOutput = AsyncStream<Data> { captured = $0 }
        self.continuation = captured!
    }

    func send(_ input: String) async throws { sentPayloads.append(input) }
    func send(bytes: [UInt8]) async throws { sentPayloads.append(String(decoding: bytes, as: UTF8.self)) }
    func resizePTY(columns: Int, rows: Int) async throws {}
    func emit(_ text: String) { continuation.yield(Data(text.utf8)) }
    func close() async { continuation.finish() }
}

@MainActor private final class EchoFilterTestKnownHostsStore: KnownHostsStoreProtocol {
    func allEntries() async throws -> [KnownHostEntry] { [] }
    func evaluate(hostname: String, port: UInt16, hostKeyType: String, presentedFingerprint: String) async throws -> KnownHostVerificationResult { .trusted }
    func trust(challenge: KnownHostVerificationChallenge) async throws {}
    func clearAll() async throws {}
}
#endif
