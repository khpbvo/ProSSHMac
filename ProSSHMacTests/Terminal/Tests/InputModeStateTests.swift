// InputModeStateTests.swift
// ProSSHV2
//
// D.2 — Input mode state tracking and VTParser synchronization tests.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class InputModeStateTests: XCTestCase {

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
#endif
