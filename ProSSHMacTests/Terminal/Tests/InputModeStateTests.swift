// InputModeStateTests.swift
// ProSSHV2
//
// D.2 — Input mode state tracking and VTParser synchronization tests.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class InputModeStateTests: XCTestCase {

    func testKeyboardModesAreOptInAndPopRestoresShellEncoding() async {
        let engine = TerminalEngine(columns: 80, rows: 24)
        let state = InputModeState()
        await engine.setInputModeState(state)
        let key = KeyEvent(key: .enter, modifiers: .shift)
        var snapshot = await engine.inputModeSnapshot()
        XCTAssertEqual(KeyEncoder(options: snapshot.keyEncoderOptions).encode(key), [0x16, 0x0A])

        // Split the enable across parser chunks, as real PTY output can be split.
        await engine.feed(Array("\u{1B}[>".utf8))
        let enabled = await engine.feedAndCollectOutcome(Data("1u".utf8))
        XCTAssertTrue(enabled.inputModeSnapshot.keyboardDisambiguation)
        XCTAssertEqual(KeyEncoder(options: enabled.inputModeSnapshot.keyEncoderOptions).encode(key),
                       Array("\u{1B}[13;2u".utf8))
        let tracked = await state.snapshot()
        XCTAssertEqual(tracked, enabled.inputModeSnapshot)

        await engine.feed(Array("\u{1B}[>0u".utf8))
        snapshot = await engine.inputModeSnapshot()
        XCTAssertFalse(snapshot.keyboardDisambiguation)
        await engine.feed(Array("\u{1B}[<u".utf8))
        snapshot = await engine.inputModeSnapshot()
        XCTAssertTrue(snapshot.keyboardDisambiguation)
        await engine.feed(Array("\u{1B}[<u".utf8))
        snapshot = await engine.inputModeSnapshot()
        XCTAssertEqual(KeyEncoder(options: snapshot.keyEncoderOptions).encode(key), [0x16, 0x0A])
    }

    func testKeyboardModeStacksAreBoundedAndIndependentForEachScreen() async {
        let engine = TerminalEngine(columns: 80, rows: 24)
        await engine.feed(Array("\u{1B}[>1u\u{1B}[?1049h".utf8))
        var snapshot = await engine.inputModeSnapshot()
        XCTAssertFalse(snapshot.keyboardDisambiguation)
        await engine.feed(Array("\u{1B}[>1u\u{1B}[?1049l".utf8))
        snapshot = await engine.inputModeSnapshot()
        XCTAssertTrue(snapshot.keyboardDisambiguation)
        await engine.feed(Array("\u{1B}[<u\u{1B}[?1049h".utf8))
        snapshot = await engine.inputModeSnapshot()
        XCTAssertTrue(snapshot.keyboardDisambiguation)
        await engine.feed(Array(String(repeating: "\u{1B}[>1u", count: 100).utf8))
        let grid = await engine.grid
        XCTAssertLessThanOrEqual(grid.alternateKeyboardModeStack.count, 16)
        await engine.feed(Array("\u{1B}[<999u\u{1B}[?1049l".utf8))
        snapshot = await engine.inputModeSnapshot()
        XCTAssertFalse(snapshot.keyboardDisambiguation)
    }

    func testKeyboardModeSetQueryAndResetReportOnlySupportedEnhancements() async {
        let engine = TerminalEngine(columns: 80, rows: 24)
        let state = InputModeState()
        let responses = KeyboardModeResponseCollector()
        await engine.setInputModeState(state)
        await engine.setResponseHandler { bytes in await responses.append(bytes) }
        await engine.feed(Array("\u{1B}[?u\u{1B}[=31u\u{1B}[?u\u{1B}[=1;3u\u{1B}[?u\u{1B}[=1;2u\u{1B}[?u".utf8))
        let reports = await responses.values
        XCTAssertEqual(reports.map { String(decoding: $0, as: UTF8.self) },
                       ["\u{1B}[?0u", "\u{1B}[?1u", "\u{1B}[?0u", "\u{1B}[?1u"])
        await engine.feed(Array("\u{1B}[!p".utf8))
        var snapshot = await state.snapshot()
        XCTAssertFalse(snapshot.keyboardDisambiguation)
        await engine.feed(Array("\u{1B}[>1u\u{1B}c".utf8))
        snapshot = await state.snapshot()
        XCTAssertFalse(snapshot.keyboardDisambiguation)
    }

    func testXtermShiftEnterModeEnablesDisablesAndResetsWithoutChangingSGR() async {
        let engine = TerminalEngine(columns: 80, rows: 24)
        let state = InputModeState()
        await engine.setInputModeState(state)
        let key = KeyEvent(key: .enter, modifiers: .shift)
        for off in ["\u{1B}[>4;0m", "\u{1B}[>4m", "\u{1B}[>m", "\u{1B}[>4n", "\u{1B}[!p", "\u{1B}c"] {
            await engine.feed(Array("\u{1B}[1m".utf8))
            await engine.feed(Array("\u{1B}[>4;2m".utf8))
            let grid = await engine.grid
            XCTAssertTrue(grid.currentAttributes.contains(.bold))
            XCTAssertFalse(grid.currentAttributes.contains(.dim))
            var snapshot = await state.snapshot()
            XCTAssertEqual(snapshot.modifyOtherKeys, 2)
            XCTAssertEqual(KeyEncoder(options: snapshot.keyEncoderOptions).encode(key), Array("\u{1B}[27;2;13~".utf8))
            await engine.feed(Array(off.utf8))
            snapshot = await state.snapshot()
            XCTAssertEqual(snapshot.modifyOtherKeys, 0)
            XCTAssertEqual(KeyEncoder(options: snapshot.keyEncoderOptions).encode(key), [0x16, 0x0A])
        }
    }

    @MainActor
    func testDefaultModeStateIsDisabled() async {
        let state = InputModeState()
        let snapshot = await state.snapshot()
        let applicationCursorKeys = snapshot.applicationCursorKeys
        let applicationKeypad = snapshot.applicationKeypad
        let bracketedPasteMode = snapshot.bracketedPasteMode
        let mouseTracking = snapshot.mouseTracking
        let mouseEncoding = snapshot.mouseEncoding
        XCTAssertFalse(applicationCursorKeys)
        XCTAssertFalse(applicationKeypad)
        XCTAssertFalse(bracketedPasteMode)
        XCTAssertEqual(mouseTracking, .none)
        XCTAssertEqual(mouseEncoding, .x10)
    }

    @MainActor
    func testTrackDECCKMFromParser() async {
        let engine = TerminalEngine(columns: 80, rows: 24)
        let modeState = InputModeState()
        await engine.setInputModeState(modeState)

        await engine.feed(Array("\u{1B}[?1h".utf8))
        var snapshot = await modeState.snapshot()
        let cursorKeysEnabled = snapshot.applicationCursorKeys
        XCTAssertTrue(cursorKeysEnabled)

        await engine.feed(Array("\u{1B}[?1l".utf8))
        snapshot = await modeState.snapshot()
        let cursorKeysDisabled = snapshot.applicationCursorKeys
        XCTAssertFalse(cursorKeysDisabled)
    }

    @MainActor
    func testTrackDECKPAMAndDECKPNMFromParser() async {
        let engine = TerminalEngine(columns: 80, rows: 24)
        let modeState = InputModeState()
        await engine.setInputModeState(modeState)

        await engine.feed(Array("\u{1B}=".utf8))
        var snapshot = await modeState.snapshot()
        let keypadEnabled = snapshot.applicationKeypad
        XCTAssertTrue(keypadEnabled)

        await engine.feed(Array("\u{1B}>".utf8))
        snapshot = await modeState.snapshot()
        let keypadDisabled = snapshot.applicationKeypad
        XCTAssertFalse(keypadDisabled)
    }

    @MainActor
    func testTrackBracketedPasteModeFromParser() async {
        let engine = TerminalEngine(columns: 80, rows: 24)
        let modeState = InputModeState()
        await engine.setInputModeState(modeState)

        await engine.feed(Array("\u{1B}[?2004h".utf8))
        var snapshot = await modeState.snapshot()
        let bracketedPasteEnabled = snapshot.bracketedPasteMode
        XCTAssertTrue(bracketedPasteEnabled)

        await engine.feed(Array("\u{1B}[?2004l".utf8))
        snapshot = await modeState.snapshot()
        let bracketedPasteDisabled = snapshot.bracketedPasteMode
        XCTAssertFalse(bracketedPasteDisabled)
    }

    @MainActor
    func testTrackMouseModesFromParser() async {
        let engine = TerminalEngine(columns: 80, rows: 24)
        let modeState = InputModeState()
        await engine.setInputModeState(modeState)

        await engine.feed(Array("\u{1B}[?1003h".utf8))
        await engine.feed(Array("\u{1B}[?1006h".utf8))
        var snapshot = await modeState.snapshot()
        let enabledTracking = snapshot.mouseTracking
        let enabledEncoding = snapshot.mouseEncoding
        XCTAssertEqual(enabledTracking, .anyEvent)
        XCTAssertEqual(enabledEncoding, .sgr)

        await engine.feed(Array("\u{1B}[?1003l".utf8))
        await engine.feed(Array("\u{1B}[?1006l".utf8))
        snapshot = await modeState.snapshot()
        let disabledTracking = snapshot.mouseTracking
        let disabledEncoding = snapshot.mouseEncoding
        XCTAssertEqual(disabledTracking, .none)
        XCTAssertEqual(disabledEncoding, .x10)
    }

    @MainActor
    func testSoftAndFullResetSyncFromParser() async {
        let engine = TerminalEngine(columns: 80, rows: 24)
        let modeState = InputModeState()
        await engine.setInputModeState(modeState)

        await engine.feed(Array("\u{1B}[?1h".utf8))      // DECCKM on
        await engine.feed(Array("\u{1B}=".utf8))         // application keypad on
        await engine.feed(Array("\u{1B}[?1002h".utf8))   // button event mouse on
        await engine.feed(Array("\u{1B}[?1006h".utf8))   // SGR mouse encoding
        await engine.feed(Array("\u{1B}[?2004h".utf8))   // bracketed paste on

        await engine.feed(Array("\u{1B}[!p".utf8))       // DECSTR soft reset
        var snapshot = await modeState.snapshot()
        let softResetCursorKeys = snapshot.applicationCursorKeys
        let softResetKeypad = snapshot.applicationKeypad
        let softResetBracketedPaste = snapshot.bracketedPasteMode
        let softResetTracking = snapshot.mouseTracking
        let softResetEncoding = snapshot.mouseEncoding
        XCTAssertFalse(softResetCursorKeys)
        XCTAssertFalse(softResetKeypad)
        XCTAssertTrue(softResetBracketedPaste)
        XCTAssertEqual(softResetTracking, .none)
        XCTAssertEqual(softResetEncoding, .x10)

        await engine.feed(Array("\u{1B}c".utf8))         // RIS full reset
        snapshot = await modeState.snapshot()
        let fullResetCursorKeys = snapshot.applicationCursorKeys
        let fullResetKeypad = snapshot.applicationKeypad
        let fullResetBracketedPaste = snapshot.bracketedPasteMode
        let fullResetTracking = snapshot.mouseTracking
        let fullResetEncoding = snapshot.mouseEncoding
        XCTAssertFalse(fullResetCursorKeys)
        XCTAssertFalse(fullResetKeypad)
        XCTAssertFalse(fullResetBracketedPaste)
        XCTAssertEqual(fullResetTracking, .none)
        XCTAssertEqual(fullResetEncoding, .x10)
    }
}

private actor KeyboardModeResponseCollector {
    var values: [[UInt8]] = []
    func append(_ bytes: [UInt8]) { values.append(bytes) }
}
#endif
