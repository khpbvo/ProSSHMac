#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class TerminalHistoryIndexTests: XCTestCase {

    @MainActor
    func testSemanticCommandEndFinalizesCommandBlock() async {
        let index = TerminalHistoryIndex(maxBlocksPerSession: 20)
        let sessionID = UUID()

        await index.registerSession(sessionID: sessionID, username: "kevin", hostname: "box")
        _ = await index.observeVisibleLines(sessionID: sessionID, lines: ["kevin@box:~$"], at: .now)
        await index.recordCommandInput(sessionID: sessionID, command: "ls -la", at: .now, source: .userInput)
        _ = await index.observeVisibleLines(
            sessionID: sessionID,
            lines: ["kevin@box:~$ ls -la", "README.md", "docs", "kevin@box:~$"],
            at: .now
        )
        await index.recordOutputChunk(
            sessionID: sessionID,
            data: Data("README.md\ndocs\n".utf8),
            at: .now
        )
        _ = await index.recordSemanticEvent(sessionID: sessionID, event: .commandEnd(exitCode: 0), at: .now)

        let recent = await index.recentCommands(sessionID: sessionID, limit: 10)
        let first = recent[0]
        let firstCommand = first.command
        let firstExitCode = first.exitCode
        let firstBoundarySource = first.boundarySource
        let firstOutput = first.output
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(firstCommand, "ls -la")
        XCTAssertEqual(firstExitCode, 0)
        XCTAssertEqual(firstBoundarySource, .osc133)
        XCTAssertTrue(firstOutput.contains("README.md"))
        XCTAssertTrue(firstOutput.contains("docs"))
    }

    @MainActor
    func testPromptHeuristicFinalizesWhenOSCNotAvailable() async {
        let index = TerminalHistoryIndex(maxBlocksPerSession: 20)
        let sessionID = UUID()

        await index.registerSession(sessionID: sessionID, username: "kevin", hostname: "box")
        _ = await index.observeVisibleLines(sessionID: sessionID, lines: ["kevin@box:~$"], at: .now)
        await index.recordCommandInput(sessionID: sessionID, command: "pwd", at: .now, source: .userInput)

        _ = await index.observeVisibleLines(
            sessionID: sessionID,
            lines: ["kevin@box:~$ pwd", "/home/kevin"],
            at: .now
        )
        await index.recordOutputChunk(sessionID: sessionID, data: Data("/home/kevin\n".utf8), at: .now)
        _ = await index.observeVisibleLines(
            sessionID: sessionID,
            lines: ["kevin@box:~$ pwd", "/home/kevin", "kevin@box:~$"],
            at: .now
        )

        let recent = await index.recentCommands(sessionID: sessionID, limit: 10)
        let first = recent[0]
        let firstCommand = first.command
        let firstBoundarySource = first.boundarySource
        let firstOutput = first.output
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(firstCommand, "pwd")
        XCTAssertEqual(firstBoundarySource, .heuristicPrompt)
        XCTAssertTrue(firstOutput.contains("/home/kevin"))
    }

    @MainActor
    func testRawInputCaptureStartsCommandOnEnter() async {
        let index = TerminalHistoryIndex(maxBlocksPerSession: 20)
        let sessionID = UUID()

        await index.registerSession(sessionID: sessionID, username: "kevin", hostname: "box")
        let t0 = Date()
        _ = await index.observeVisibleLines(sessionID: sessionID, lines: ["kevin@box:~$"], at: t0)
        await index.recordRawInput(sessionID: sessionID, input: "echo hello", at: t0.addingTimeInterval(0.05))
        await index.recordRawInput(sessionID: sessionID, input: "\r", at: t0.addingTimeInterval(0.06))
        await index.recordOutputChunk(
            sessionID: sessionID,
            data: Data("hello\n".utf8),
            at: t0.addingTimeInterval(0.10)
        )
        _ = await index.observeVisibleLines(
            sessionID: sessionID,
            lines: ["kevin@box:~$ echo hello", "hello", "kevin@box:~$"],
            at: t0.addingTimeInterval(0.35)
        )

        let recent = await index.recentCommands(sessionID: sessionID, limit: 10)
        XCTAssertEqual(recent.count, 1)
        let firstCommand = recent[0].command
        XCTAssertEqual(firstCommand, "echo hello")
    }

    @MainActor
    func testSearchMatchesCommandAndOutput() async {
        let index = TerminalHistoryIndex(maxBlocksPerSession: 20)
        let sessionID = UUID()

        await index.registerSession(sessionID: sessionID, username: "kevin", hostname: "box")

        _ = await index.observeVisibleLines(sessionID: sessionID, lines: ["kevin@box:~$"], at: .now)
        await index.recordCommandInput(sessionID: sessionID, command: "uname -a", at: .now, source: .userInput)
        await index.recordOutputChunk(sessionID: sessionID, data: Data("Linux box 6.8.0\n".utf8), at: .now)
        _ = await index.recordSemanticEvent(sessionID: sessionID, event: .commandEnd(exitCode: 0), at: .now)

        await index.recordCommandInput(sessionID: sessionID, command: "cat /etc/os-release", at: .now, source: .userInput)
        await index.recordOutputChunk(sessionID: sessionID, data: Data("NAME=Ubuntu\n".utf8), at: .now)
        _ = await index.recordSemanticEvent(sessionID: sessionID, event: .commandEnd(exitCode: 0), at: .now)

        let kernelResults = await index.searchCommands(sessionID: sessionID, query: "linux", limit: 10)
        let kernelFirstCommand = kernelResults[0].command
        XCTAssertEqual(kernelResults.count, 1)
        XCTAssertEqual(kernelFirstCommand, "uname -a")

        let commandResults = await index.searchCommands(sessionID: sessionID, query: "os-release", limit: 10)
        let commandFirst = commandResults[0].command
        XCTAssertEqual(commandResults.count, 1)
        XCTAssertEqual(commandFirst, "cat /etc/os-release")
    }

    /// The output cap used to be applied on every append, which cost four O(n)
    /// passes over the whole buffer per chunk. It is now applied once, at read
    /// time, over a byte buffer trimmed in amortized batches — the retained window
    /// must still be the last `maxOutputCharacters` characters.
    @MainActor
    func testRawOutputRetainsMostRecentCharacterWindow() async {
        let cap = 2_000
        let index = TerminalHistoryIndex(maxBlocksPerSession: 20, maxOutputCharacters: cap)
        let sessionID = UUID()

        await index.registerSession(sessionID: sessionID, username: "kevin", hostname: "box")
        await index.recordCommandInput(sessionID: sessionID, command: "flood", at: .now, source: .userInput)

        // Well past the amortized trim threshold (4x the cap in bytes, trimmed at
        // 2x that), in many small chunks.
        for chunk in 0..<4_000 {
            await index.recordOutputChunk(
                sessionID: sessionID,
                data: Data(String(format: "%07d\n", chunk).utf8),
                at: .now
            )
        }

        let raw = await index.activeCommandRawOutput(sessionID: sessionID)
        guard let output = raw else { return XCTFail("expected raw output") }
        XCTAssertLessThanOrEqual(output.count, cap)
        XCTAssertTrue(output.hasSuffix("0003999\n"), "the newest output must survive the trim")
        XCTAssertFalse(output.contains("0000000\n"), "the oldest output must be dropped")
    }

    /// Trimming a UTF-8 byte buffer can cut mid-sequence. The retained window must
    /// still decode cleanly rather than surfacing replacement characters.
    @MainActor
    func testRawOutputTrimDoesNotSplitMultiByteCharacters() async {
        let index = TerminalHistoryIndex(maxBlocksPerSession: 20, maxOutputCharacters: 2_000)
        let sessionID = UUID()

        await index.registerSession(sessionID: sessionID, username: "kevin", hostname: "box")
        await index.recordCommandInput(sessionID: sessionID, command: "unicode", at: .now, source: .userInput)

        // 3-byte characters, so the trim boundary rarely lands on a lead byte.
        for _ in 0..<2_000 {
            await index.recordOutputChunk(sessionID: sessionID, data: Data("日本語テスト\n".utf8), at: .now)
        }

        let raw = await index.activeCommandRawOutput(sessionID: sessionID)
        guard let output = raw else { return XCTFail("expected raw output") }
        XCTAssertFalse(output.contains("\u{FFFD}"), "trim split a multi-byte sequence")
        XCTAssertTrue(output.hasSuffix("日本語テスト\n"))
    }

    /// NUL bytes were stripped before and must still be.
    @MainActor
    func testRawOutputStripsNulBytes() async {
        let index = TerminalHistoryIndex(maxBlocksPerSession: 20)
        let sessionID = UUID()

        await index.registerSession(sessionID: sessionID, username: "kevin", hostname: "box")
        await index.recordCommandInput(sessionID: sessionID, command: "nuls", at: .now, source: .userInput)
        await index.recordOutputChunk(sessionID: sessionID, data: Data([0x61, 0x00, 0x62]), at: .now)

        let raw = await index.activeCommandRawOutput(sessionID: sessionID)
        XCTAssertEqual(raw, "ab")
    }

    @MainActor
    func testRingBufferCapacityDropsOldestBlocks() async {
        let index = TerminalHistoryIndex(maxBlocksPerSession: 2)
        let sessionID = UUID()

        await index.registerSession(sessionID: sessionID, username: "kevin", hostname: "box")

        for command in ["one", "two", "three"] {
            await index.recordCommandInput(sessionID: sessionID, command: command, at: .now, source: .userInput)
            _ = await index.recordSemanticEvent(sessionID: sessionID, event: .commandEnd(exitCode: 0), at: .now)
        }

        let recent = await index.recentCommands(sessionID: sessionID, limit: 10)
        let commands = [recent[0].command, recent[1].command]
        XCTAssertEqual(commands, ["three", "two"])
    }
}
#endif
