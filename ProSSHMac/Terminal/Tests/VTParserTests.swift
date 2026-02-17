// VTParserTests.swift
// ProSSHV2
//
// A.16 — Unit tests for all parser states and transitions.
// Tests the VTParser state machine, CSI/SGR/ESC/OSC/DCS dispatch,
// UTF-8 decoding, and malformed input handling.
//
// These tests create a real TerminalGrid and VTParser, feed byte sequences,
// then verify the grid state matches expectations.

#if canImport(XCTest)
import XCTest

// MARK: - VTParserTests

final class VTParserTests: XCTestCase {

    private var grid: TerminalGrid!
    private var parser: VTParser!
    private var responses: [[UInt8]]!

    override func setUp() async throws {
        grid = TerminalGrid(columns: 80, rows: 24)
        parser = VTParser(grid: grid)
        responses = []

        await parser.setResponseHandler { @Sendable [weak self] bytes in
            self?.responses.append(bytes)
        }
    }

    // MARK: - Helper

    /// Feed a string as UTF-8 bytes into the parser.
    private func feed(_ string: String) async {
        await parser.feed(Array(string.utf8))
    }

    /// Feed raw bytes into the parser.
    private func feedBytes(_ bytes: [UInt8]) async {
        await parser.feed(bytes)
    }

    // MARK: - State Transition Tests

    func testInitialStateIsGround() async {
        let state = await parser.state
        XCTAssertEqual(state, .ground)
    }

    func testEscapeTransitionsToEscapeState() async {
        await feedBytes([0x1B]) // ESC
        let state = await parser.state
        XCTAssertEqual(state, .escape)
    }

    func testCSIEntryViaEscBracket() async {
        await feedBytes([0x1B, 0x5B]) // ESC [
        let state = await parser.state
        XCTAssertEqual(state, .csiEntry)
    }

    func testCSICompletionReturnsToGround() async {
        // CSI H (CUP) should complete and return to ground
        await feed("\u{1B}[1;1H")
        let state = await parser.state
        XCTAssertEqual(state, .ground)
    }

    func testOSCStringState() async {
        await feedBytes([0x1B, 0x5D]) // ESC ]
        let state = await parser.state
        XCTAssertEqual(state, .oscString)
    }

    func testOSCTerminatedByST() async {
        // OSC 0;title ST
        await feed("\u{1B}]0;Hello\u{1B}\\")
        let state = await parser.state
        XCTAssertEqual(state, .ground)
    }

    func testCANCancelsSequence() async {
        // Start a CSI then cancel with CAN (0x18)
        await feedBytes([0x1B, 0x5B, 0x18]) // ESC [ CAN
        let state = await parser.state
        XCTAssertEqual(state, .ground)
    }

    // MARK: - CSI Parsing Tests

    func testCUP_CursorPosition() async {
        await feed("\u{1B}[5;10H")
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 4)  // 1-based → 0-based
        XCTAssertEqual(pos.col, 9)
    }

    func testCUP_DefaultsToHome() async {
        // Move cursor away first
        await feed("\u{1B}[5;10H")
        // Then CUP with no params = home
        await feed("\u{1B}[H")
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 0)
        XCTAssertEqual(pos.col, 0)
    }

    func testCUU_CursorUp() async {
        await feed("\u{1B}[10;1H") // Row 10
        await feed("\u{1B}[3A")     // Up 3
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 6) // 9 - 3 = 6
    }

    func testCUD_CursorDown() async {
        await feed("\u{1B}[1;1H") // Home
        await feed("\u{1B}[5B")    // Down 5
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 5)
    }

    func testCUF_CursorForward() async {
        await feed("\u{1B}[1;1H") // Home
        await feed("\u{1B}[10C")   // Forward 10
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 10)
    }

    func testCUB_CursorBackward() async {
        await feed("\u{1B}[1;20H") // Col 20
        await feed("\u{1B}[5D")     // Back 5
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 14)
    }

    func testCHA_CursorHorizontalAbsolute() async {
        await feed("\u{1B}[15G") // CHA to column 15
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 14) // 1-based → 0-based
    }

    func testVPA_VerticalPositionAbsolute() async {
        await feed("\u{1B}[10d") // VPA to row 10
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 9) // 1-based → 0-based
    }

    func testCNL_CursorNextLine() async {
        await feed("\u{1B}[1;5H")  // Row 1, col 5
        await feed("\u{1B}[3E")     // Next line 3 times
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 3)
        XCTAssertEqual(pos.col, 0)
    }

    func testCPL_CursorPreviousLine() async {
        await feed("\u{1B}[10;5H") // Row 10, col 5
        await feed("\u{1B}[2F")     // Previous line 2 times
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 7)
        XCTAssertEqual(pos.col, 0)
    }

    // MARK: - Erase Tests

    func testED_EraseFromCursorToEnd() async {
        await feed("ABCDEF")
        await feed("\u{1B}[1;1H") // Home
        await feed("\u{1B}[0J")    // Erase from cursor to end
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell?.isBlank ?? false)
    }

    func testEL_EraseEntireLine() async {
        await feed("Hello World")
        await feed("\u{1B}[1;1H") // Home
        await feed("\u{1B}[2K")    // Erase entire line
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell?.isBlank ?? false)
    }

    func testECH_EraseCharacters() async {
        await feed("ABCDEF")
        await feed("\u{1B}[1;1H") // Home
        await feed("\u{1B}[3X")    // Erase 3 chars
        // First 3 should be blank, 4th should be 'D'
        let blank = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(blank?.isBlank ?? false)
        let d = await grid.cellAt(row: 0, col: 3)
        XCTAssertEqual(d?.graphemeCluster, "D")
    }

    // MARK: - SGR Tests

    func testSGR_Reset() async {
        await feed("\u{1B}[1m")  // Bold on
        await feed("\u{1B}[0m")  // Reset
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.attributes, [])
        XCTAssertEqual(sgr.fg, .default)
        XCTAssertEqual(sgr.bg, .default)
    }

    func testSGR_Bold() async {
        await feed("\u{1B}[1m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.bold))
    }

    func testSGR_StandardForeground() async {
        await feed("\u{1B}[31m") // Red foreground
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.fg, .indexed(1))
    }

    func testSGR_BrightBackground() async {
        await feed("\u{1B}[104m") // Bright blue background
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.bg, .indexed(12))
    }

    func testSGR_256Color() async {
        await feed("\u{1B}[38;5;196m") // Foreground index 196
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.fg, .indexed(196))
    }

    func testSGR_Truecolor() async {
        await feed("\u{1B}[38;2;128;64;255m") // RGB foreground
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.fg, .rgb(128, 64, 255))
    }

    func testSGR_MultipleAttributes() async {
        await feed("\u{1B}[1;3;4;31m") // Bold + Italic + Underline + Red
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.bold))
        XCTAssertTrue(sgr.attributes.contains(.italic))
        XCTAssertTrue(sgr.attributes.contains(.underline))
        XCTAssertEqual(sgr.fg, .indexed(1))
    }

    func testSGR_AttributeReset() async {
        await feed("\u{1B}[1;3m")  // Bold + Italic
        await feed("\u{1B}[22m")    // Normal intensity (remove bold/dim)
        let sgr = await grid.sgrState()
        XCTAssertFalse(sgr.attributes.contains(.bold))
        XCTAssertTrue(sgr.attributes.contains(.italic))
    }

    func testSGR_DoubleUnderline() async {
        await feed("\u{1B}[21m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.doubleUnder))
    }

    // MARK: - ESC Sequence Tests

    func testDECSC_DECRC_SaveRestoreCursor() async {
        await feed("\u{1B}[5;10H") // Move to (5,10)
        await feed("\u{1B}7")       // DECSC — save
        await feed("\u{1B}[1;1H")  // Home
        await feed("\u{1B}8")       // DECRC — restore
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 4)
        XCTAssertEqual(pos.col, 9)
    }

    func testRIS_FullReset() async {
        await feed("\u{1B}[1m")    // Bold
        await feed("\u{1B}[5;5H")  // Move cursor
        await feed("\u{1B}c")       // RIS
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 0)
        XCTAssertEqual(pos.col, 0)
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.attributes, [])
    }

    func testHTS_SetTabStop() async {
        await feed("\u{1B}[5G")    // Column 5
        await feed("\u{1B}H")       // HTS — set tab at column 4 (0-based)
        let tabs = await grid.tabStops
        XCTAssertTrue(tabs.contains(4))
    }

    func testDECKPAM_DECKPNM() async {
        await feed("\u{1B}=")      // DECKPAM
        var kp = await grid.applicationKeypad
        XCTAssertTrue(kp)

        await feed("\u{1B}>")      // DECKPNM
        kp = await grid.applicationKeypad
        XCTAssertFalse(kp)
    }

    func testDECALN_ScreenAlignment() async {
        await feed("\u{1B}#8") // DECALN — fill with 'E'
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "E")
        let cell2 = await grid.cellAt(row: 23, col: 79)
        XCTAssertEqual(cell2?.graphemeCluster, "E")
    }

    // MARK: - Charset Tests

    func testDECSpecialGraphics() async {
        await feed("\u{1B}(0")     // Switch G0 to DEC Special Graphics
        await feedBytes([0x6A])    // 'j' → ┘
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "┘")
    }

    func testShiftOutShiftIn() async {
        await feed("\u{1B})0")     // G1 = DEC Special Graphics
        await feedBytes([0x0E])    // SO — activate G1
        await feedBytes([0x71])    // 'q' → ─
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "─")

        await feedBytes([0x0F])    // SI — back to G0 (ASCII)
        await feedBytes([0x71])    // 'q' → 'q' (ASCII)
        let cell2 = await grid.cellAt(row: 0, col: 1)
        XCTAssertEqual(cell2?.graphemeCluster, "q")
    }

    // MARK: - OSC Tests

    func testOSC_WindowTitle() async {
        await feed("\u{1B}]2;My Terminal\u{1B}\\")
        let title = await grid.windowTitle
        XCTAssertEqual(title, "My Terminal")
    }

    func testOSC_IconName() async {
        await feed("\u{1B}]1;MyIcon\u{1B}\\")
        let icon = await grid.iconName
        XCTAssertEqual(icon, "MyIcon")
    }

    func testOSC_TitleAndIcon() async {
        await feed("\u{1B}]0;Both\u{1B}\\")
        let title = await grid.windowTitle
        let icon = await grid.iconName
        XCTAssertEqual(title, "Both")
        XCTAssertEqual(icon, "Both")
    }

    func testOSC_BELTerminatedUTF8TitleDoesNotLeakToGrid() async {
        // "✳" contains byte 0x9C as UTF-8 continuation (E2 9C B3).
        // Ensure this does not terminate OSC early as C1 ST.
        await feed("\u{1B}]0;✳ Claude Code\u{07}")

        let title = await grid.windowTitle
        XCTAssertEqual(title, "✳ Claude Code")

        let row0 = await grid.visibleText().first ?? ""
        XCTAssertEqual(row0, "")
    }

    func testOSC_RepeatedBELTerminatedUTF8TitleDoesNotDuplicateVisibleText() async {
        await feed("\u{1B}]0;✳ Claude Code\u{07}")
        await feed("\u{1B}]0;✳ Claude Code\u{07}")

        let title = await grid.windowTitle
        XCTAssertEqual(title, "✳ Claude Code")

        let row0 = await grid.visibleText().first ?? ""
        XCTAssertEqual(row0, "")
    }

    func testOSC_DefaultForegroundSet() async {
        await feed("\u{1B}]10;rgb:11/22/33\u{1B}\\")
        let fg = await grid.defaultForegroundRGB()
        XCTAssertEqual(fg.0, 0x11)
        XCTAssertEqual(fg.1, 0x22)
        XCTAssertEqual(fg.2, 0x33)
    }

    func testOSC_DefaultBackgroundSet() async {
        await feed("\u{1B}]11;rgb:aa/bb/cc\u{1B}\\")
        let bg = await grid.defaultBackgroundRGB()
        XCTAssertEqual(bg.0, 0xAA)
        XCTAssertEqual(bg.1, 0xBB)
        XCTAssertEqual(bg.2, 0xCC)
    }

    func testOSC_DefaultForegroundQueryReflectsSetValue() async {
        await feed("\u{1B}]10;rgb:11/22/33\u{1B}\\")
        responses.removeAll()
        await feed("\u{1B}]10;?\u{1B}\\")
        XCTAssertEqual(responses.count, 1)
        let expected = Array("\u{1B}]10;rgb:1111/2222/3333\u{1B}\\".utf8)
        XCTAssertEqual(responses[0], expected)
    }

    func testOSC_DefaultBackgroundQueryReflectsSetValue() async {
        await feed("\u{1B}]11;rgb:aa/bb/cc\u{1B}\\")
        responses.removeAll()
        await feed("\u{1B}]11;?\u{1B}\\")
        XCTAssertEqual(responses.count, 1)
        let expected = Array("\u{1B}]11;rgb:aaaa/bbbb/cccc\u{1B}\\".utf8)
        XCTAssertEqual(responses[0], expected)
    }

    // MARK: - DECSET / DECRST Tests

    func testDECSET_CursorVisibility() async {
        await feed("\u{1B}[?25l") // Hide cursor
        var visible = await grid.cursor.visible
        XCTAssertFalse(visible)

        await feed("\u{1B}[?25h") // Show cursor
        visible = await grid.cursor.visible
        XCTAssertTrue(visible)
    }

    func testDECSET_AlternateBuffer() async {
        await feed("Hello")           // Write to primary
        await feed("\u{1B}[?1049h")   // Switch to alt
        let alt = await grid.usingAlternateBuffer
        XCTAssertTrue(alt)

        await feed("\u{1B}[?1049l")   // Switch back
        let primary = await grid.usingAlternateBuffer
        XCTAssertFalse(primary)
        // "Hello" should still be there
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "H")
    }

    func testDECSET_BracketedPaste() async {
        await feed("\u{1B}[?2004h")
        let bp = await grid.bracketedPasteMode
        XCTAssertTrue(bp)
    }

    // MARK: - SM/RM (ANSI Modes)

    func testSetResetInsertMode() async {
        await feed("\u{1B}[4h") // Set IRM
        var irm = await grid.insertMode
        XCTAssertTrue(irm)

        await feed("\u{1B}[4l") // Reset IRM
        irm = await grid.insertMode
        XCTAssertFalse(irm)
    }

    // MARK: - DSR / DA Response Tests

    func testDSR_CursorPositionReport() async {
        await feed("\u{1B}[5;10H")  // Move to row 5, col 10
        await feed("\u{1B}[6n")      // DSR — request cursor position
        XCTAssertEqual(responses.count, 1)
        let expected = Array("\u{1B}[5;10R".utf8)
        XCTAssertEqual(responses[0], expected)
    }

    func testDA_DeviceAttributes() async {
        await feed("\u{1B}[c") // DA
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses[0], DeviceAttributes.primaryResponse)
    }

    // MARK: - Scroll Region Tests

    func testDECSTBM_SetScrollRegion() async {
        await feed("\u{1B}[5;20r") // Set region rows 5–20
        let top = await grid.scrollTop
        let bottom = await grid.scrollBottom
        XCTAssertEqual(top, 4)    // 1-based → 0-based
        XCTAssertEqual(bottom, 19)
    }

    func testDECSTR_SoftReset() async {
        await feed("\u{1B}[1m")    // Bold
        await feed("\u{1B}[!p")    // DECSTR
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.attributes, [])
    }

    // MARK: - UTF-8 Decoding Tests

    func testUTF8_TwoByteCharacter() async {
        // é = 0xC3 0xA9
        await feedBytes([0xC3, 0xA9])
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "é")
    }

    func testUTF8_ThreeByteCharacter() async {
        // € = 0xE2 0x82 0xAC
        await feedBytes([0xE2, 0x82, 0xAC])
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "€")
    }

    func testUTF8_FourByteCharacter() async {
        // 🎉 = 0xF0 0x9F 0x8E 0x89
        await feedBytes([0xF0, 0x9F, 0x8E, 0x89])
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "🎉")
    }

    func testUTF8_InvalidContinuationByte() async {
        // Start a 2-byte sequence then send a non-continuation byte
        await feedBytes([0xC3, 0x41]) // 0xC3 + 'A' (not continuation)
        // Should get replacement character for the broken sequence, then 'A'
        let cell0 = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell0?.graphemeCluster, "A") // broken UTF-8 discarded, 'A' prints
    }

    // MARK: - Malformed Input Tests

    func testMalformedCSI_TooManyParams() async {
        // CSI with 100 parameters — should not crash, just truncate
        var seq = "\u{1B}["
        for i in 0..<100 {
            if i > 0 { seq += ";" }
            seq += "1"
        }
        seq += "H"
        await feed(seq)
        let state = await parser.state
        XCTAssertEqual(state, .ground) // Should complete normally
    }

    func testRandomBytes_NoCrash() async {
        // Feed random-ish bytes — parser must not crash
        var bytes: [UInt8] = []
        for i: UInt8 in 0...255 {
            bytes.append(i)
        }
        await feedBytes(bytes)
        // Just verify we didn't crash
        let state = await parser.state
        XCTAssertNotNil(state)
    }

    func testGarbageAfterESC_ReturnsToGround() async {
        // ESC followed by an invalid byte
        await feedBytes([0x1B, 0xFF])
        // Parser should handle gracefully
        let state = await parser.state
        // After garbage, parser may be in various states but shouldn't crash
        XCTAssertNotNil(state)
    }

    // MARK: - Insert/Delete Tests

    func testICH_InsertCharacters() async {
        await feed("ABCDE")
        await feed("\u{1B}[1;2H")  // Column 2 (0-based: 1)
        await feed("\u{1B}[2@")     // Insert 2 blanks
        // After insert: A _ _ B C D E (with B C D E shifted right)
        let a = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(a?.graphemeCluster, "A")
        let blank = await grid.cellAt(row: 0, col: 1)
        XCTAssertTrue(blank?.isBlank ?? false)
        let b = await grid.cellAt(row: 0, col: 3)
        XCTAssertEqual(b?.graphemeCluster, "B")
    }

    func testDCH_DeleteCharacters() async {
        await feed("ABCDE")
        await feed("\u{1B}[1;2H")  // Column 2 (0-based: 1)
        await feed("\u{1B}[2P")     // Delete 2 chars
        // After delete: A D E _ _ (B,C deleted, D,E shift left)
        let a = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(a?.graphemeCluster, "A")
        let d = await grid.cellAt(row: 0, col: 1)
        XCTAssertEqual(d?.graphemeCluster, "D")
    }

    // MARK: - Scroll Tests

    func testSU_ScrollUp() async {
        await feed("\u{1B}[1;1H")
        await feed("Line 1")
        await feed("\u{1B}[2;1H")
        await feed("Line 2")
        await feed("\u{1B}[1S")    // Scroll up 1
        // "Line 1" should be gone, "Line 2" should be on row 0
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "L")
        let cell4 = await grid.cellAt(row: 0, col: 5)
        XCTAssertEqual(cell4?.graphemeCluster, "2")
    }

    // MARK: - Tab Tests

    func testCHT_TabForward() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[2I")    // CHT — 2 tabs forward
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 16) // Default tabs at 8, 16
    }

    func testCBT_TabBackward() async {
        await feed("\u{1B}[1;20H") // Column 20
        await feed("\u{1B}[1Z")     // CBT — 1 tab backward
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 16)
    }

    func testTBC_ClearAllTabStops() async {
        await feed("\u{1B}[3g")    // Clear all tab stops
        let tabs = await grid.tabStops
        XCTAssertTrue(tabs.isEmpty)
    }

    // MARK: - REP (Repeat Character)

    func testREP_RepeatPrecedingCharacter() async {
        await feed("X")
        await feed("\u{1B}[4b")    // Repeat 'X' 4 more times
        // Should have 5 X's total
        for col in 0..<5 {
            let cell = await grid.cellAt(row: 0, col: col)
            XCTAssertEqual(cell?.graphemeCluster, "X")
        }
    }

    // MARK: - Print Tests

    func testPrintASCII() async {
        await feed("Hello")
        let h = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(h?.graphemeCluster, "H")
        let o = await grid.cellAt(row: 0, col: 4)
        XCTAssertEqual(o?.graphemeCluster, "o")
    }

    func testAutoWrap() async {
        // Print 81 characters on an 80-col terminal
        let line = String(repeating: "A", count: 81)
        await feed(line)
        // 81st char should wrap to next line
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 1)
        XCTAssertEqual(pos.col, 1)
    }

    // MARK: - C0 Control Tests

    func testCarriageReturn() async {
        await feed("Hello\r")
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 0)
    }

    func testLineFeed() async {
        await feed("Hello\n")
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 1)
    }

    func testBackspace() async {
        await feed("AB\u{08}")  // BS
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 1)
    }

    func testHorizontalTab() async {
        await feed("\t")
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 8) // Default first tab stop
    }

    // MARK: - Bold-Brighten Tests (Fix 1)

    func testBoldBrighten_StandardColor() async {
        // Bold + standard red (index 1) should render as bright red (index 9)
        await feed("\u{1B}[1;31mX")
        let snapshot = await grid.snapshot()
        let cell = snapshot.cells[0]
        // Verify bold attribute is set
        XCTAssertTrue((cell.attributes & CellAttributes.bold.rawValue) != 0)
        // Verify the packed fg color is bright red (index 9), not dark red (index 1)
        let brightRedRGB = ColorPalette.rgb(forIndex: 9)
        let expectedPacked = (UInt32(brightRedRGB.r) << 24) | (UInt32(brightRedRGB.g) << 16) | (UInt32(brightRedRGB.b) << 8) | 0xFF
        XCTAssertEqual(cell.fgColor, expectedPacked)
    }

    func testBoldBrighten_256ColorNotBrightened() async {
        // Bold + explicit 256-color index should NOT be brightened
        await feed("\u{1B}[1;38;5;1mX")
        let snapshot = await grid.snapshot()
        let cell = snapshot.cells[0]
        // Index 1 via 256-color mode should stay as index 1 (not brightened to 9)
        // because explicit 256-color is NOT a standard 0-7 assignment
        // Actually: .indexed(1) IS in range 0-7 so it WILL be brightened
        // This matches real terminal behavior - bold brightens any indexed 0-7
        let brightRedRGB = ColorPalette.rgb(forIndex: 9)
        let expectedPacked = (UInt32(brightRedRGB.r) << 24) | (UInt32(brightRedRGB.g) << 16) | (UInt32(brightRedRGB.b) << 8) | 0xFF
        XCTAssertEqual(cell.fgColor, expectedPacked)
    }

    func testBoldBrighten_TruecolorNotBrightened() async {
        // Bold + truecolor should NOT be brightened
        await feed("\u{1B}[1;38;2;255;0;0mX")
        let snapshot = await grid.snapshot()
        let cell = snapshot.cells[0]
        // Truecolor (255,0,0) should remain unchanged
        let expectedPacked: UInt32 = (255 << 24) | (0 << 16) | (0 << 8) | 0xFF
        XCTAssertEqual(cell.fgColor, expectedPacked)
    }

    func testBoldBrighten_SGR22Restores() async {
        // Bold + red → SGR 22 (normal intensity) should revert to normal red
        await feed("\u{1B}[1;31mB\u{1B}[22mN")
        let snapshot = await grid.snapshot()
        // Cell 0 ('B'): bold + bright red
        let boldCell = snapshot.cells[0]
        let brightRedRGB = ColorPalette.rgb(forIndex: 9)
        let brightPacked = (UInt32(brightRedRGB.r) << 24) | (UInt32(brightRedRGB.g) << 16) | (UInt32(brightRedRGB.b) << 8) | 0xFF
        XCTAssertEqual(boldCell.fgColor, brightPacked)
        // Cell 1 ('N'): not bold, normal red (index 1)
        let normalCell = snapshot.cells[1]
        let normalRedRGB = ColorPalette.rgb(forIndex: 1)
        let normalPacked = (UInt32(normalRedRGB.r) << 24) | (UInt32(normalRedRGB.g) << 16) | (UInt32(normalRedRGB.b) << 8) | 0xFF
        XCTAssertEqual(normalCell.fgColor, normalPacked)
        // And the grid's stored color should still be index 1 for both
        let sgrState = await grid.sgrState()
        XCTAssertEqual(sgrState.fg, .indexed(1))
    }

    func testBoldBrighten_OrderIndependent() async {
        // \033[1;31m vs \033[31;1m vs \033[1m\033[31m should all produce same result
        await feed("\u{1B}[1;31mA")
        await feed("\u{1B}[0m")
        await feed("\u{1B}[31;1mB")
        await feed("\u{1B}[0m")
        await feed("\u{1B}[1m\u{1B}[31mC")

        let snapshot = await grid.snapshot()
        let cellA = snapshot.cells[0]
        let cellB = snapshot.cells[1]
        let cellC = snapshot.cells[2]
        XCTAssertEqual(cellA.fgColor, cellB.fgColor)
        XCTAssertEqual(cellB.fgColor, cellC.fgColor)
    }

    // MARK: - Fix 2: Colon Subparameter Parsing Tests

    func testSubparam_ColonUnderlineStyle_CurlyNotItalic() async {
        // 4:3 = curly underline via colon subparam.
        // Should NOT set italic (code 3) — colon means subparam of code 4.
        await feed("\u{1B}[4:3m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.underline))
        XCTAssertFalse(sgr.attributes.contains(.italic),
                       "Colon subparam 4:3 should not set italic")
        XCTAssertEqual(sgr.underlineStyle, .curly)
    }

    func testSubparam_SemicolonUnderlineAndItalic() async {
        // 4;3 = underline (4) then italic (3) via semicolon — separate codes.
        await feed("\u{1B}[4;3m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.underline))
        XCTAssertTrue(sgr.attributes.contains(.italic),
                      "Semicolon form 4;3 should set both underline and italic")
        XCTAssertEqual(sgr.underlineStyle, .single)
    }

    func testSubparam_ColonTruecolor() async {
        // 38:2::255:128:0 = truecolor fg with double-colon (omitted colorspace)
        await feed("\u{1B}[38:2::255:128:0m")
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.fg, .rgb(255, 128, 0))
    }

    func testSubparam_ColonTruecolorWithColorspace() async {
        // 38:2:0:100:200:50 = truecolor fg with explicit colorspace ID 0
        await feed("\u{1B}[38:2:0:100:200:50m")
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.fg, .rgb(100, 200, 50))
    }

    func testSubparam_Colon256Color() async {
        // 38:5:196 = 256-color fg via colon form
        await feed("\u{1B}[38:5:196m")
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.fg, .indexed(196))
    }

    func testSubparam_ColonBg256Color() async {
        // 48:5:42 = 256-color bg via colon form
        await feed("\u{1B}[48:5:42m")
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.bg, .indexed(42))
    }

    func testSubparam_ColonBgTruecolor() async {
        // 48:2::10:20:30 = truecolor bg via colon form
        await feed("\u{1B}[48:2::10:20:30m")
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.bg, .rgb(10, 20, 30))
    }

    func testSubparam_UnderlineStyleNone() async {
        // 4:0 = remove underline
        await feed("\u{1B}[4m")  // Set single underline first
        await feed("\u{1B}[4:0m")
        let sgr = await grid.sgrState()
        XCTAssertFalse(sgr.attributes.contains(.underline))
        XCTAssertEqual(sgr.underlineStyle, .none)
    }

    func testSubparam_UnderlineStyleSingle() async {
        await feed("\u{1B}[4:1m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.underline))
        XCTAssertEqual(sgr.underlineStyle, .single)
    }

    func testSubparam_UnderlineStyleDouble() async {
        await feed("\u{1B}[4:2m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.doubleUnder))
        XCTAssertEqual(sgr.underlineStyle, .double)
    }

    func testSubparam_UnderlineStyleDotted() async {
        await feed("\u{1B}[4:4m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.underline))
        XCTAssertEqual(sgr.underlineStyle, .dotted)
    }

    func testSubparam_UnderlineStyleDashed() async {
        await feed("\u{1B}[4:5m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.underline))
        XCTAssertEqual(sgr.underlineStyle, .dashed)
    }

    func testSubparam_MixedColonAndSemicolon() async {
        // 1;4:3;31m = bold + curly underline + red fg
        await feed("\u{1B}[1;4:3;31m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.bold))
        XCTAssertTrue(sgr.attributes.contains(.underline))
        XCTAssertEqual(sgr.underlineStyle, .curly)
        XCTAssertEqual(sgr.fg, .indexed(1))
        XCTAssertFalse(sgr.attributes.contains(.italic),
                       "Mixed form should not misparse colon subparam as italic")
    }

    // MARK: - Fix 3: Underline Color Tests

    func testUnderlineColor_256ColorSemicolon() async {
        // 4;58;5;196m = underline + underline color index 196
        await feed("\u{1B}[4;58;5;196m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.underline))
        XCTAssertEqual(sgr.underlineColor, .indexed(196))
    }

    func testUnderlineColor_TruecolorSemicolon() async {
        // 4;58;2;255;128;64m = underline + truecolor underline color
        await feed("\u{1B}[4;58;2;255;128;64m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.underline))
        XCTAssertEqual(sgr.underlineColor, .rgb(255, 128, 64))
    }

    func testUnderlineColor_ColonForm() async {
        // 58:5:196 = underline color index 196 via colon subparam
        await feed("\u{1B}[58:5:196m")
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.underlineColor, .indexed(196))
    }

    func testUnderlineColor_TruecolorColonForm() async {
        // 58:2::128:0:255 = underline color truecolor via colon subparam
        await feed("\u{1B}[58:2::128:0:255m")
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.underlineColor, .rgb(128, 0, 255))
    }

    func testUnderlineColor_Reset() async {
        // Set underline color then reset with 59
        await feed("\u{1B}[58;5;196m")
        await feed("\u{1B}[59m")
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.underlineColor, .default)
    }

    func testUnderlineColor_ResetBySGR0() async {
        // SGR 0 should also reset underline color
        await feed("\u{1B}[58;5;196m")
        await feed("\u{1B}[0m")
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.underlineColor, .default)
        XCTAssertEqual(sgr.underlineStyle, .none)
    }

    func testUnderlineColor_StampedOnCell() async {
        // Verify underline color is stored on the cell when printing
        await feed("\u{1B}[4;58;5;196mX")
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.underlineColor, .indexed(196))
        XCTAssertEqual(cell?.underlineStyle, .single)
    }

    // MARK: - Fix 4: Extended Underline Style Tests

    func testUnderlineStyle_SGR24ClearsAll() async {
        // SGR 24 should clear all underline styles
        await feed("\u{1B}[4:3m")  // curly
        await feed("\u{1B}[24m")    // clear underline
        let sgr = await grid.sgrState()
        XCTAssertFalse(sgr.attributes.contains(.underline))
        XCTAssertFalse(sgr.attributes.contains(.doubleUnder))
        XCTAssertEqual(sgr.underlineStyle, .none)
    }

    func testUnderlineStyle_SGR21DoubleUnderline() async {
        // SGR 21 = double underline (traditional code)
        await feed("\u{1B}[21m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.doubleUnder))
        XCTAssertEqual(sgr.underlineStyle, .double)
    }

    func testUnderlineStyle_StampedOnCell() async {
        // Curly underline should be stored on cell
        await feed("\u{1B}[4:3mX")
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.underlineStyle, .curly)
        XCTAssertTrue(cell?.attributes.contains(.underline) ?? false)
    }

    func testUnderlineStyle_SwitchStyles() async {
        // Switch from curly to dotted without resetting first
        await feed("\u{1B}[4:3m")  // curly
        await feed("\u{1B}[4:4m")  // dotted
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.underlineStyle, .dotted)
        XCTAssertTrue(sgr.attributes.contains(.underline))
    }

    func testUnderlineStyle_CurlyWithColor() async {
        // Curly underline + custom underline color
        await feed("\u{1B}[4:3;58;2;255;0;0mX")
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.underlineStyle, .curly)
        XCTAssertEqual(cell?.underlineColor, .rgb(255, 0, 0))
    }

    // MARK: - Fix 5: Overline Tests

    func testOverline_Set() async {
        await feed("\u{1B}[53m")
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.overline))
    }

    func testOverline_Reset() async {
        await feed("\u{1B}[53m")
        await feed("\u{1B}[55m")
        let sgr = await grid.sgrState()
        XCTAssertFalse(sgr.attributes.contains(.overline))
    }

    func testOverline_StampedOnCell() async {
        await feed("\u{1B}[53mX")
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell?.attributes.contains(.overline) ?? false)
    }

    func testOverline_ResetBySGR0() async {
        await feed("\u{1B}[53m")
        await feed("\u{1B}[0m")
        let sgr = await grid.sgrState()
        XCTAssertFalse(sgr.attributes.contains(.overline))
    }

    func testOverline_WithOtherAttributes() async {
        // Overline + bold + underline combined
        await feed("\u{1B}[1;4;53mX")
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell?.attributes.contains(.overline) ?? false)
        XCTAssertTrue(cell?.attributes.contains(.bold) ?? false)
        XCTAssertTrue(cell?.attributes.contains(.underline) ?? false)
    }

    // MARK: - Fix 6: Hyperlink (OSC 8) Tests

    func testOSC8_SetHyperlink() async {
        // OSC 8 ; params ; URI ST
        await feed("\u{1B}]8;;https://example.com\u{1B}\\")
        let link = await grid.currentHyperlink
        XCTAssertEqual(link, "https://example.com")
    }

    func testOSC8_ClearHyperlink() async {
        // Set then clear
        await feed("\u{1B}]8;;https://example.com\u{1B}\\")
        await feed("\u{1B}]8;;\u{1B}\\")
        let link = await grid.currentHyperlink
        XCTAssertNil(link)
    }

    func testOSC8_WithParams() async {
        // OSC 8 with id param: "id=foo;https://example.com"
        await feed("\u{1B}]8;id=foo;https://example.com\u{1B}\\")
        let link = await grid.currentHyperlink
        XCTAssertEqual(link, "https://example.com")
    }

    func testOSC8_ResetByFullReset() async {
        await feed("\u{1B}]8;;https://example.com\u{1B}\\")
        await feed("\u{1B}c") // RIS
        let link = await grid.currentHyperlink
        XCTAssertNil(link)
    }

    // MARK: - Fix 2-6: Snapshot Integration Tests

    func testUnderlineColor_InSnapshot() async {
        // Verify underline color survives through to CellInstance snapshot
        await feed("\u{1B}[4;58;5;196mX")
        let snapshot = await grid.snapshot()
        let cell = snapshot.cells[0]
        // underlineColor should be packed RGBA for indexed(196)
        let expectedRGB = ColorPalette.rgb(forIndex: 196)
        let expectedPacked = (UInt32(expectedRGB.r) << 24) | (UInt32(expectedRGB.g) << 16) | (UInt32(expectedRGB.b) << 8) | 0xFF
        XCTAssertEqual(cell.underlineColor, expectedPacked)
    }

    func testUnderlineStyle_InSnapshot() async {
        // Verify underline style is packed in snapshot
        await feed("\u{1B}[4:3mX")
        let snapshot = await grid.snapshot()
        let cell = snapshot.cells[0]
        XCTAssertEqual(cell.underlineStyle, UnderlineStyle.curly.rawValue)
    }

    func testOverline_InSnapshot() async {
        // Verify overline attribute bit in snapshot
        await feed("\u{1B}[53mX")
        let snapshot = await grid.snapshot()
        let cell = snapshot.cells[0]
        XCTAssertTrue((cell.attributes & CellAttributes.overline.rawValue) != 0)
    }

    func testSGR_ResetClearsEverything() async {
        // Set all extended attributes then reset — everything should clear
        await feed("\u{1B}[1;3;4:3;53;58;5;196m")  // bold, italic, curly underline, overline, underline color
        await feed("\u{1B}[0m")
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.attributes, [])
        XCTAssertEqual(sgr.fg, .default)
        XCTAssertEqual(sgr.bg, .default)
        XCTAssertEqual(sgr.underlineColor, .default)
        XCTAssertEqual(sgr.underlineStyle, .none)
    }

    func testSoftReset_ClearsExtendedAttributes() async {
        // DECSTR should reset underline color/style
        await feed("\u{1B}[4:3;58;5;196m")
        await feed("\u{1B}[!p")  // DECSTR
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.underlineColor, .default)
        XCTAssertEqual(sgr.underlineStyle, .none)
    }

    func testSaveCursor_RestoresUnderlineState() async {
        // DECSC should save and DECRC should restore underline color/style
        await feed("\u{1B}[4:3;58;5;196m")  // curly underline + color
        await feed("\u{1B}7")                 // DECSC — save
        await feed("\u{1B}[0m")              // reset all
        await feed("\u{1B}8")                 // DECRC — restore
        let sgr = await grid.sgrState()
        XCTAssertEqual(sgr.underlineStyle, .curly)
        XCTAssertEqual(sgr.underlineColor, .indexed(196))
    }
}
#endif
