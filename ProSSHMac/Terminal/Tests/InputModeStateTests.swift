// InputModeStateTests.swift
// ProSSHV2
//
// D.2 — Input mode state tracking and VTParser synchronization tests.

#if canImport(XCTest)
import XCTest

final class InputModeStateTests: XCTestCase {

    func testDefaultModeStateIsDisabled() async {
        let state = InputModeState()
        let snapshot = await state.snapshot()
        XCTAssertFalse(snapshot.applicationCursorKeys)
        XCTAssertFalse(snapshot.applicationKeypad)
        XCTAssertFalse(snapshot.bracketedPasteMode)
        XCTAssertEqual(snapshot.mouseTracking, .none)
        XCTAssertEqual(snapshot.mouseEncoding, .x10)
    }

    func testTrackDECCKMFromParser() async {
        let grid = TerminalGrid(columns: 80, rows: 24)
        let parser = VTParser(grid: grid)
        let modeState = InputModeState()
        await parser.setInputModeState(modeState)

        await parser.feed(Array("\u{1B}[?1h".utf8))
        var snapshot = await modeState.snapshot()
        XCTAssertTrue(snapshot.applicationCursorKeys)

        await parser.feed(Array("\u{1B}[?1l".utf8))
        snapshot = await modeState.snapshot()
        XCTAssertFalse(snapshot.applicationCursorKeys)
    }

    func testTrackDECKPAMAndDECKPNMFromParser() async {
        let grid = TerminalGrid(columns: 80, rows: 24)
        let parser = VTParser(grid: grid)
        let modeState = InputModeState()
        await parser.setInputModeState(modeState)

        await parser.feed(Array("\u{1B}=".utf8))
        var snapshot = await modeState.snapshot()
        XCTAssertTrue(snapshot.applicationKeypad)

        await parser.feed(Array("\u{1B}>".utf8))
        snapshot = await modeState.snapshot()
        XCTAssertFalse(snapshot.applicationKeypad)
    }

    func testTrackBracketedPasteModeFromParser() async {
        let grid = TerminalGrid(columns: 80, rows: 24)
        let parser = VTParser(grid: grid)
        let modeState = InputModeState()
        await parser.setInputModeState(modeState)

        await parser.feed(Array("\u{1B}[?2004h".utf8))
        var snapshot = await modeState.snapshot()
        XCTAssertTrue(snapshot.bracketedPasteMode)

        await parser.feed(Array("\u{1B}[?2004l".utf8))
        snapshot = await modeState.snapshot()
        XCTAssertFalse(snapshot.bracketedPasteMode)
    }

    func testTrackMouseModesFromParser() async {
        let grid = TerminalGrid(columns: 80, rows: 24)
        let parser = VTParser(grid: grid)
        let modeState = InputModeState()
        await parser.setInputModeState(modeState)

        await parser.feed(Array("\u{1B}[?1003h".utf8))
        await parser.feed(Array("\u{1B}[?1006h".utf8))
        var snapshot = await modeState.snapshot()
        XCTAssertEqual(snapshot.mouseTracking, .anyEvent)
        XCTAssertEqual(snapshot.mouseEncoding, .sgr)

        await parser.feed(Array("\u{1B}[?1003l".utf8))
        await parser.feed(Array("\u{1B}[?1006l".utf8))
        snapshot = await modeState.snapshot()
        XCTAssertEqual(snapshot.mouseTracking, .none)
        XCTAssertEqual(snapshot.mouseEncoding, .x10)
    }

    func testSoftAndFullResetSyncFromParser() async {
        let grid = TerminalGrid(columns: 80, rows: 24)
        let parser = VTParser(grid: grid)
        let modeState = InputModeState()
        await parser.setInputModeState(modeState)

        await parser.feed(Array("\u{1B}[?1h".utf8))      // DECCKM on
        await parser.feed(Array("\u{1B}=".utf8))         // application keypad on
        await parser.feed(Array("\u{1B}[?1002h".utf8))   // button event mouse on
        await parser.feed(Array("\u{1B}[?1006h".utf8))   // SGR mouse encoding
        await parser.feed(Array("\u{1B}[?2004h".utf8))   // bracketed paste on

        await parser.feed(Array("\u{1B}[!p".utf8))       // DECSTR soft reset
        var snapshot = await modeState.snapshot()
        XCTAssertFalse(snapshot.applicationCursorKeys)
        XCTAssertFalse(snapshot.applicationKeypad)
        XCTAssertTrue(snapshot.bracketedPasteMode)
        XCTAssertEqual(snapshot.mouseTracking, .none)
        XCTAssertEqual(snapshot.mouseEncoding, .x10)

        await parser.feed(Array("\u{1B}c".utf8))         // RIS full reset
        snapshot = await modeState.snapshot()
        XCTAssertFalse(snapshot.applicationCursorKeys)
        XCTAssertFalse(snapshot.applicationKeypad)
        XCTAssertFalse(snapshot.bracketedPasteMode)
        XCTAssertEqual(snapshot.mouseTracking, .none)
        XCTAssertEqual(snapshot.mouseEncoding, .x10)
    }
}
#endif
