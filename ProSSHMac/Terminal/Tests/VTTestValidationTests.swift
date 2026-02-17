// VTTestValidationTests.swift
// ProSSHV2
//
// F.11 — Run vttest and verify all test pages.
//
// vttest is the standard VT100/VT220 validation suite. We cannot run the
// actual vttest binary inside unit tests, but we CAN feed the same escape
// sequences that vttest uses and verify the resulting grid state.
//
// Each test class corresponds to a vttest screen/category.

#if canImport(XCTest)
import XCTest

// MARK: - 1. VTTestCursorMovementTest

/// vttest screen 1: Cursor movement.
/// Validates CUU/CUD/CUF/CUB/CUP/HVP/DECSC/DECRC/CNL/CPL.
final class VTTestCursorMovementTest: IntegrationTestBase {

    // MARK: - CUU (Cursor Up)

    /// ESC[A moves cursor up by 1 row. Stops at row 0.
    func testCursorUp() async {
        // Place cursor at row 10
        await feed("\u{1B}[11;1H")
        let startPos = await grid.cursorPosition()
        XCTAssertEqual(startPos.row, 10)

        // Move up 1
        await feed("\u{1B}[A")
        var pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 9, "CUU should decrement row by 1")
        XCTAssertEqual(pos.col, 0, "CUU should not change column")

        // Move up 5 more
        await feed("\u{1B}[5A")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 4, "CUU 5 should move from row 9 to row 4")

        // Move up beyond top — should clamp at row 0
        await feed("\u{1B}[100A")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 0, "CUU should stop at row 0")
    }

    // MARK: - CUD (Cursor Down)

    /// ESC[B moves cursor down by 1 row. Stops at last row.
    func testCursorDown() async {
        await feed("\u{1B}[1;1H") // Home
        var pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 0)

        // Move down 1
        await feed("\u{1B}[B")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 1, "CUD should increment row by 1")

        // Move down 10
        await feed("\u{1B}[10B")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 11, "CUD 10 should move from row 1 to row 11")

        // Move down beyond last row — should clamp at row 23
        await feed("\u{1B}[100B")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 23, "CUD should stop at last row (23)")
    }

    // MARK: - CUF (Cursor Forward)

    /// ESC[C moves cursor right. Stops at last column.
    func testCursorForward() async {
        await feed("\u{1B}[1;1H") // Home
        await feed("\u{1B}[C")
        var pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 1, "CUF should increment column by 1")

        await feed("\u{1B}[10C")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 11, "CUF 10 should move from col 1 to col 11")

        // Beyond right edge — clamp at col 79
        await feed("\u{1B}[200C")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 79, "CUF should stop at last column (79)")
    }

    // MARK: - CUB (Cursor Back)

    /// ESC[D moves cursor left. Stops at column 0.
    func testCursorBack() async {
        await feed("\u{1B}[1;20H") // Row 1, col 20 (0-based: col 19)
        await feed("\u{1B}[D")
        var pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 18, "CUB should decrement column by 1")

        await feed("\u{1B}[5D")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 13, "CUB 5 should move from col 18 to col 13")

        // Beyond left edge — clamp at col 0
        await feed("\u{1B}[200D")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 0, "CUB should stop at column 0")
    }

    // MARK: - CUP (Cursor Position)

    /// ESC[H with no args goes to (0,0). ESC[5;10H goes to row 4, col 9.
    func testCursorHome() async {
        // Move somewhere first
        await feed("\u{1B}[10;20H")
        var pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 9)
        XCTAssertEqual(pos.col, 19)

        // ESC[H (no params) — home
        await feed("\u{1B}[H")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 0, "CUP with no args should move to row 0")
        XCTAssertEqual(pos.col, 0, "CUP with no args should move to col 0")

        // ESC[5;10H — row 5, col 10 (1-based)
        await feed("\u{1B}[5;10H")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 4, "CUP row 5 should be 0-based row 4")
        XCTAssertEqual(pos.col, 9, "CUP col 10 should be 0-based col 9")
    }

    // MARK: - CUP with count parameter

    /// ESC[5A moves up 5 rows. ESC[3C moves right 3.
    func testCursorWithCount() async {
        await feed("\u{1B}[12;1H") // Row 12
        await feed("\u{1B}[5A")     // Up 5
        var pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 6, "CUU 5 from row 11 should go to row 6")

        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[3C")     // Right 3
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 3, "CUF 3 from col 0 should go to col 3")
    }

    // MARK: - DECSC / DECRC (Save / Restore Cursor)

    /// ESC 7 saves cursor, ESC 8 restores it.
    func testCursorSaveRestore() async {
        // Position cursor
        await feed("\u{1B}[8;15H") // Row 8, col 15 (0-based: 7, 14)

        // Save
        await feed("\u{1B}7")

        // Move somewhere else
        await feed("\u{1B}[1;1H")
        var pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 0)
        XCTAssertEqual(pos.col, 0)

        // Restore
        await feed("\u{1B}8")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 7, "DECRC should restore saved row")
        XCTAssertEqual(pos.col, 14, "DECRC should restore saved column")
    }

    // MARK: - HVP (Horizontal and Vertical Position)

    /// ESC[10;20f — same as CUP.
    func testHVP() async {
        await feed("\u{1B}[10;20f")
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 9, "HVP row 10 should be 0-based row 9")
        XCTAssertEqual(pos.col, 19, "HVP col 20 should be 0-based col 19")

        // HVP with no params = home
        await feed("\u{1B}[f")
        let homePos = await grid.cursorPosition()
        XCTAssertEqual(homePos.row, 0, "HVP with no args should go to row 0")
        XCTAssertEqual(homePos.col, 0, "HVP with no args should go to col 0")
    }

    // MARK: - CNL / CPL (Cursor Next Line / Cursor Previous Line)

    /// ESC[E cursor next line, ESC[F cursor previous line.
    func testCNL_CPL() async {
        // Position at row 10, col 30
        await feed("\u{1B}[11;31H")
        var pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 10)
        XCTAssertEqual(pos.col, 30)

        // CNL — next line, col resets to 0
        await feed("\u{1B}[3E")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 13, "CNL 3 should move from row 10 to row 13")
        XCTAssertEqual(pos.col, 0, "CNL should reset column to 0")

        // CPL — previous line, col resets to 0
        await feed("\u{1B}[14;20H") // Row 14, col 20
        await feed("\u{1B}[2F")
        pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 11, "CPL 2 should move from row 13 to row 11")
        XCTAssertEqual(pos.col, 0, "CPL should reset column to 0")
    }
}

// MARK: - 2. VTTestScreenClearingTest

/// vttest screen 2: Screen clearing and line clearing.
/// Validates ED (Erase in Display), EL (Erase in Line), IL (Insert Lines), DL (Delete Lines).
final class VTTestScreenClearingTest: IntegrationTestBase {

    // MARK: - Helpers

    /// Fill the entire screen with 'X' characters.
    private func fillScreen() async {
        for row in 1...24 {
            await feed("\u{1B}[\(row);1H")
            await feed(String(repeating: "X", count: 80))
        }
    }

    // MARK: - ED (Erase in Display)

    /// ESC[2J clears the entire screen.
    func testEraseDisplayAll() async {
        await fillScreen()

        // Verify screen was filled
        let before = await charAt(row: 0, col: 0)
        XCTAssertEqual(before, "X", "Screen should be filled with X")

        // Erase entire display
        await feed("\u{1B}[2J")

        // Verify all cells are blank
        for row in 0..<24 {
            for col in stride(from: 0, to: 80, by: 20) {
                let ch = await charAt(row: row, col: col)
                let isEmpty = ch.isEmpty || ch == " "
                XCTAssertTrue(isEmpty, "Cell at (\(row),\(col)) should be blank after ED 2, got '\(ch)'")
            }
        }
    }

    /// ESC[0J erases from cursor to end of screen.
    func testEraseDisplayBelow() async {
        await fillScreen()

        // Move to row 10 (1-based: 11), col 1
        await feed("\u{1B}[11;1H")

        // Erase from cursor to end
        await feed("\u{1B}[0J")

        // Rows 0-9 should be preserved
        for row in 0..<10 {
            let ch = await charAt(row: row, col: 0)
            XCTAssertEqual(ch, "X", "Row \(row) should be preserved after ED 0")
        }

        // Rows 10-23 should be cleared
        for row in 10..<24 {
            let ch = await charAt(row: row, col: 0)
            let isEmpty = ch.isEmpty || ch == " "
            XCTAssertTrue(isEmpty, "Row \(row) should be cleared after ED 0, got '\(ch)'")
        }
    }

    /// ESC[1J erases from beginning of screen to cursor.
    func testEraseDisplayAbove() async {
        await fillScreen()

        // Move to row 10 (1-based: 11), col 40
        await feed("\u{1B}[11;41H")

        // Erase from beginning to cursor
        await feed("\u{1B}[1J")

        // Rows 0-9 should be cleared
        for row in 0..<10 {
            let ch = await charAt(row: row, col: 0)
            let isEmpty = ch.isEmpty || ch == " "
            XCTAssertTrue(isEmpty, "Row \(row) should be cleared after ED 1, got '\(ch)'")
        }

        // Rows 11-23 should be preserved
        for row in 11..<24 {
            let ch = await charAt(row: row, col: 0)
            XCTAssertEqual(ch, "X", "Row \(row) should be preserved after ED 1")
        }
    }

    // MARK: - EL (Erase in Line)

    /// ESC[0K erases from cursor to end of line.
    func testEraseLineToEnd() async {
        await feed("\u{1B}[1;1H")
        await feed(String(repeating: "A", count: 80))

        // Move to col 10 (1-based: 11)
        await feed("\u{1B}[1;11H")

        // Erase to end of line
        await feed("\u{1B}[0K")

        // Cols 0-9 should be preserved
        for col in 0..<10 {
            let ch = await charAt(row: 0, col: col)
            XCTAssertEqual(ch, "A", "Col \(col) should be preserved after EL 0")
        }

        // Cols 10-79 should be cleared
        for col in 10..<80 {
            let ch = await charAt(row: 0, col: col)
            let isEmpty = ch.isEmpty || ch == " "
            XCTAssertTrue(isEmpty, "Col \(col) should be cleared after EL 0, got '\(ch)'")
        }
    }

    /// ESC[1K erases from beginning of line to cursor.
    func testEraseLineToStart() async {
        await feed("\u{1B}[1;1H")
        await feed(String(repeating: "B", count: 80))

        // Move to col 10 (1-based: 11)
        await feed("\u{1B}[1;11H")

        // Erase from start to cursor
        await feed("\u{1B}[1K")

        // Cols 0-10 should be cleared (inclusive of cursor at col 10)
        for col in 0...10 {
            let ch = await charAt(row: 0, col: col)
            let isEmpty = ch.isEmpty || ch == " "
            XCTAssertTrue(isEmpty, "Col \(col) should be cleared after EL 1, got '\(ch)'")
        }

        // Cols 11-79 should be preserved
        for col in 11..<80 {
            let ch = await charAt(row: 0, col: col)
            XCTAssertEqual(ch, "B", "Col \(col) should be preserved after EL 1")
        }
    }

    /// ESC[2K erases the entire current line.
    func testEraseLineAll() async {
        await feed("\u{1B}[1;1H")
        await feed(String(repeating: "C", count: 80))

        // Move to middle of line
        await feed("\u{1B}[1;40H")

        // Erase entire line
        await feed("\u{1B}[2K")

        // All columns should be cleared
        for col in stride(from: 0, to: 80, by: 10) {
            let ch = await charAt(row: 0, col: col)
            let isEmpty = ch.isEmpty || ch == " "
            XCTAssertTrue(isEmpty, "Col \(col) should be cleared after EL 2, got '\(ch)'")
        }
    }

    // MARK: - IL (Insert Lines)

    /// ESC[3L inserts 3 blank lines at cursor row. Content shifts down.
    func testInsertLines() async {
        // Write identifiable content on rows 0-5
        for i in 0..<6 {
            await feed("\u{1B}[\(i + 1);1H")
            await feed("Row\(i)")
        }

        // Move to row 2 (1-based: 3)
        await feed("\u{1B}[3;1H")

        // Insert 3 lines
        await feed("\u{1B}[3L")

        // Row 0 should still be "Row0"
        let row0 = await rowText(row: 0, startCol: 0, endCol: 4)
        XCTAssertEqual(row0, "Row0", "Row 0 should be unchanged after IL")

        // Row 1 should still be "Row1"
        let row1 = await rowText(row: 1, startCol: 0, endCol: 4)
        XCTAssertEqual(row1, "Row1", "Row 1 should be unchanged after IL")

        // Rows 2-4 should be blank (inserted lines)
        for row in 2..<5 {
            let ch = await charAt(row: row, col: 0)
            let isEmpty = ch.isEmpty || ch == " "
            XCTAssertTrue(isEmpty, "Row \(row) should be blank after IL 3, got '\(ch)'")
        }

        // Row 5 should now be "Row2" (shifted from row 2)
        let row5 = await rowText(row: 5, startCol: 0, endCol: 4)
        XCTAssertEqual(row5, "Row2", "Row 5 should contain shifted 'Row2' after IL 3")
    }

    // MARK: - DL (Delete Lines)

    /// ESC[2M deletes 2 lines at cursor. Content shifts up.
    func testDeleteLines() async {
        // Write identifiable content on rows 0-5
        for i in 0..<6 {
            await feed("\u{1B}[\(i + 1);1H")
            await feed("Row\(i)")
        }

        // Move to row 1 (1-based: 2)
        await feed("\u{1B}[2;1H")

        // Delete 2 lines
        await feed("\u{1B}[2M")

        // Row 0 should still be "Row0"
        let row0 = await rowText(row: 0, startCol: 0, endCol: 4)
        XCTAssertEqual(row0, "Row0", "Row 0 should be unchanged after DL")

        // Row 1 should now contain "Row3" (rows 1 and 2 deleted, row 3 shifted up)
        let row1 = await rowText(row: 1, startCol: 0, endCol: 4)
        XCTAssertEqual(row1, "Row3", "Row 1 should be 'Row3' after DL 2")

        // Row 2 should now contain "Row4"
        let row2 = await rowText(row: 2, startCol: 0, endCol: 4)
        XCTAssertEqual(row2, "Row4", "Row 2 should be 'Row4' after DL 2")

        // Row 3 should now contain "Row5"
        let row3 = await rowText(row: 3, startCol: 0, endCol: 4)
        XCTAssertEqual(row3, "Row5", "Row 3 should be 'Row5' after DL 2")
    }
}

// MARK: - 3. VTTestCharacterAttributesTest

/// vttest screen 3: Character attributes.
/// Validates SGR (Select Graphic Rendition) — bold, dim, italic, underline,
/// blink, reverse, hidden, strikethrough, double underline, reset,
/// and selective attribute reset.
final class VTTestCharacterAttributesTest: IntegrationTestBase {

    /// ESC[1m sets bold attribute.
    func testBold() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[1m")
        await feed("Bold")
        await feed("\u{1B}[0m")

        let attrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrs.contains(.bold), "Text should have bold attribute")

        let text = await rowText(row: 0, startCol: 0, endCol: 4)
        XCTAssertEqual(text, "Bold")
    }

    /// ESC[2m sets dim attribute.
    func testDim() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[2m")
        await feed("Dim")
        await feed("\u{1B}[0m")

        let attrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrs.contains(.dim), "Text should have dim attribute")
    }

    /// ESC[3m sets italic attribute.
    func testItalic() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[3m")
        await feed("Italic")
        await feed("\u{1B}[0m")

        let attrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrs.contains(.italic), "Text should have italic attribute")
    }

    /// ESC[4m sets underline attribute.
    func testUnderline() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[4m")
        await feed("Under")
        await feed("\u{1B}[0m")

        let attrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrs.contains(.underline), "Text should have underline attribute")
    }

    /// ESC[5m sets blink attribute.
    func testBlink() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[5m")
        await feed("Blink")
        await feed("\u{1B}[0m")

        let attrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrs.contains(.blink), "Text should have blink attribute")
    }

    /// ESC[7m sets reverse attribute.
    func testReverse() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[7m")
        await feed("Reverse")
        await feed("\u{1B}[0m")

        let attrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrs.contains(.reverse), "Text should have reverse attribute")
    }

    /// ESC[8m sets hidden attribute.
    func testHidden() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[8m")
        await feed("Hidden")
        await feed("\u{1B}[0m")

        let attrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrs.contains(.hidden), "Text should have hidden attribute")
    }

    /// ESC[9m sets strikethrough attribute.
    func testStrikethrough() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[9m")
        await feed("Strike")
        await feed("\u{1B}[0m")

        let attrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrs.contains(.strikethrough), "Text should have strikethrough attribute")
    }

    /// ESC[21m sets double underline attribute.
    func testDoubleUnderline() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}[21m")
        await feed("DblUnder")
        await feed("\u{1B}[0m")

        let attrs = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrs.contains(.doubleUnder), "Text should have double underline attribute")
    }

    /// ESC[0m resets all attributes.
    func testSGRReset() async {
        await feed("\u{1B}[1;1H")

        // Set bold + italic + underline + reverse
        await feed("\u{1B}[1;3;4;7m")
        await feed("A")

        // Verify combined attributes on 'A'
        let attrsA = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrsA.contains(.bold), "A should be bold")
        XCTAssertTrue(attrsA.contains(.italic), "A should be italic")
        XCTAssertTrue(attrsA.contains(.underline), "A should be underlined")
        XCTAssertTrue(attrsA.contains(.reverse), "A should be reverse")

        // Reset all
        await feed("\u{1B}[0m")
        await feed("B")

        // 'B' should have no attributes
        let attrsB = await attrsAt(row: 0, col: 1)
        XCTAssertEqual(attrsB, [], "B should have no attributes after SGR reset")
    }

    /// ESC[22m clears bold/dim but keeps other attributes.
    func testSelectiveAttributeReset() async {
        await feed("\u{1B}[1;1H")

        // Set bold + underline
        await feed("\u{1B}[1;4m")
        await feed("A")

        let attrsA = await attrsAt(row: 0, col: 0)
        XCTAssertTrue(attrsA.contains(.bold), "A should be bold")
        XCTAssertTrue(attrsA.contains(.underline), "A should be underlined")

        // SGR 22 — turn off bold (normal intensity)
        await feed("\u{1B}[22m")
        await feed("B")

        let attrsB = await attrsAt(row: 0, col: 1)
        XCTAssertFalse(attrsB.contains(.bold), "Bold should be cleared by SGR 22")
        XCTAssertTrue(attrsB.contains(.underline), "Underline should remain after SGR 22")
    }
}

// MARK: - 4. VTTestCharacterSetsTest

/// vttest character sets: DEC Special Graphics and G0/G1 switching.
/// Validates ESC(0, ESC(B, ESC)0, SO/SI, and line drawing character mappings.
final class VTTestCharacterSetsTest: IntegrationTestBase {

    /// ESC(0 activates DEC Special Graphics in G0. Characters map to graphic symbols.
    func testDECSpecialGraphicsViaESC() async {
        await feed("\u{1B}[1;1H")
        // Designate G0 as DEC Special Graphics
        await feed("\u{1B}(0")

        // Print characters that should map to graphic symbols
        await feed("a")  // a -> checkerboard
        await feed("j")  // j -> bottom-right corner
        await feed("l")  // l -> top-left corner
        await feed("q")  // q -> horizontal line

        await feed("\u{1B}(B") // Back to ASCII

        let a = await charAt(row: 0, col: 0)
        XCTAssertEqual(a, "\u{2592}", "DEC 'a' should map to checkerboard (U+2592)")

        let j = await charAt(row: 0, col: 1)
        XCTAssertEqual(j, "\u{2518}", "DEC 'j' should map to bottom-right corner")

        let l = await charAt(row: 0, col: 2)
        XCTAssertEqual(l, "\u{250C}", "DEC 'l' should map to top-left corner")

        let q = await charAt(row: 0, col: 3)
        XCTAssertEqual(q, "\u{2500}", "DEC 'q' should map to horizontal line")
    }

    /// ESC(B returns to US ASCII. Normal characters print as-is.
    func testReturnToASCII() async {
        await feed("\u{1B}[1;1H")

        // Switch to DEC Special Graphics
        await feed("\u{1B}(0")
        await feed("q") // Should be horizontal line

        // Switch back to ASCII
        await feed("\u{1B}(B")
        await feed("q") // Should be literal 'q'

        let line = await charAt(row: 0, col: 0)
        XCTAssertEqual(line, "\u{2500}", "First 'q' should be DEC line drawing")

        let ascii = await charAt(row: 0, col: 1)
        XCTAssertEqual(ascii, "q", "Second 'q' should be literal ASCII after ESC(B")
    }

    /// ESC)0 designates DEC graphics in G1. SO (0x0E) invokes G1, SI (0x0F) returns to G0.
    func testG1Selection() async {
        await feed("\u{1B}[1;1H")

        // Designate G1 as DEC Special Graphics
        await feed("\u{1B})0")

        // Print 'A' in G0 (still ASCII)
        await feed("A")

        // Shift Out — invoke G1
        await feedBytes([0x0E])
        await feed("q") // Should be horizontal line (G1 = DEC Special Graphics)

        // Shift In — back to G0
        await feedBytes([0x0F])
        await feed("B") // Should be literal 'B' (G0 = ASCII)

        let charA = await charAt(row: 0, col: 0)
        XCTAssertEqual(charA, "A", "G0 should print ASCII 'A'")

        let charLine = await charAt(row: 0, col: 1)
        XCTAssertEqual(charLine, "\u{2500}", "G1 (DEC) should map 'q' to horizontal line")

        let charB = await charAt(row: 0, col: 2)
        XCTAssertEqual(charB, "B", "After SI, G0 should print ASCII 'B'")
    }

    /// Verify all key DEC Special Graphics line drawing character mappings.
    func testLineDrawingChars() async {
        await feed("\u{1B}[1;1H")
        await feed("\u{1B}(0")

        // Map of DEC Special Graphics characters to their Unicode equivalents
        // Only the standard VT220 range 0x60–0x7E is mapped; characters outside
        // that range (like +, ,, -, ., 0) pass through as ASCII per spec.
        let mappings: [(Character, String)] = [
            ("a", "\u{2592}"),  // a -> medium shade / checkerboard
            ("j", "\u{2518}"),  // j -> box drawings light up and left (bottom-right)
            ("k", "\u{2510}"),  // k -> box drawings light down and left (top-right)
            ("l", "\u{250C}"),  // l -> box drawings light down and right (top-left)
            ("m", "\u{2514}"),  // m -> box drawings light up and right (bottom-left)
            ("n", "\u{253C}"),  // n -> box drawings light vertical and horizontal (cross)
            ("q", "\u{2500}"),  // q -> box drawings light horizontal
            ("t", "\u{251C}"),  // t -> box drawings light vertical and right (left-T)
            ("u", "\u{2524}"),  // u -> box drawings light vertical and left (right-T)
            ("v", "\u{2534}"),  // v -> box drawings light up and horizontal (bottom-T)
            ("w", "\u{252C}"),  // w -> box drawings light down and horizontal (top-T)
            ("x", "\u{2502}"),  // x -> box drawings light vertical
        ]

        for (i, (input, expected)) in mappings.enumerated() {
            await feed(String(input))

            let actual = await charAt(row: 0, col: i)
            XCTAssertEqual(actual, expected,
                "DEC Special Graphics '\(input)' should map to U+\(String(expected.unicodeScalars.first!.value, radix: 16, uppercase: true)) at col \(i)")
        }

        await feed("\u{1B}(B") // Return to ASCII
    }
}

// MARK: - 5. VTTestScrollingTest

/// vttest scrolling and scroll regions.
/// Validates normal scrolling, DECSTBM (set scroll region), SU/SD, and origin mode.
final class VTTestScrollingTest: IntegrationTestBase {

    /// Normal scrolling: Fill 24 lines, print line 25. Line 25 appears at bottom.
    func testNormalScrolling() async {
        // Fill all 24 lines
        for i in 1...24 {
            await feed("Line \(i)\r\n")
        }
        // Line 25 should cause a scroll
        await feed("Line 25")

        // After scrolling, row 0 should contain "Line 2" (Line 1 scrolled off)
        let row0 = await rowText(row: 0, startCol: 0, endCol: 6)
        XCTAssertEqual(row0, "Line 2", "Row 0 should show Line 2 after scroll")

        // Last visible row (23) should contain "Line 25"
        let row23 = await rowText(row: 23, startCol: 0, endCol: 7)
        XCTAssertEqual(row23, "Line 25", "Row 23 should show Line 25")
    }

    /// DECSTBM: ESC[5;15r confines scrolling to rows 5-15.
    func testScrollRegion() async {
        // Set scroll region to rows 5-15 (1-based)
        await feed("\u{1B}[5;15r")

        let scrollTop = await grid.scrollTop
        let scrollBottom = await grid.scrollBottom
        XCTAssertEqual(scrollTop, 4, "Scroll top should be row 4 (0-indexed)")
        XCTAssertEqual(scrollBottom, 14, "Scroll bottom should be row 14 (0-indexed)")

        // Write content above the scroll region
        await feed("\u{1B}[1;1H")
        await feed("Above Region")

        // Write content below the scroll region
        await feed("\u{1B}[20;1H")
        await feed("Below Region")

        // Position cursor inside the scroll region and fill it
        await feed("\u{1B}[5;1H")
        for i in 1...12 {
            await feed("SR Line \(i)\r\n")
        }

        // Content above should be preserved
        let above = await rowText(row: 0, startCol: 0, endCol: 12)
        XCTAssertEqual(above, "Above Region", "Content above scroll region should be preserved")

        // Content below should be preserved
        let below = await rowText(row: 19, startCol: 0, endCol: 12)
        XCTAssertEqual(below, "Below Region", "Content below scroll region should be preserved")
    }

    /// ESC[2S scrolls up 2 lines within region.
    func testScrollUp_SU() async {
        // Write content on rows 0-4
        for i in 0..<5 {
            await feed("\u{1B}[\(i + 1);1H")
            await feed("Line\(i)")
        }

        // Scroll up 2 lines
        await feed("\u{1B}[2S")

        // Row 0 should now contain "Line2" (shifted from row 2)
        let row0 = await rowText(row: 0, startCol: 0, endCol: 5)
        XCTAssertEqual(row0, "Line2", "Row 0 should contain Line2 after SU 2")

        // Row 1 should contain "Line3"
        let row1 = await rowText(row: 1, startCol: 0, endCol: 5)
        XCTAssertEqual(row1, "Line3", "Row 1 should contain Line3 after SU 2")

        // Last 2 rows of scroll region should be blank
        let lastRow = await charAt(row: 23, col: 0)
        let isEmpty = lastRow.isEmpty || lastRow == " "
        XCTAssertTrue(isEmpty, "Bottom rows should be blank after SU 2")
    }

    /// ESC[2T scrolls down 2 lines within region.
    func testScrollDown_SD() async {
        // Write content on rows 0-4
        for i in 0..<5 {
            await feed("\u{1B}[\(i + 1);1H")
            await feed("Line\(i)")
        }

        // Scroll down 2 lines
        await feed("\u{1B}[2T")

        // Row 0 and 1 should be blank (new lines inserted at top)
        for row in 0..<2 {
            let ch = await charAt(row: row, col: 0)
            let isEmpty = ch.isEmpty || ch == " "
            XCTAssertTrue(isEmpty, "Row \(row) should be blank after SD 2, got '\(ch)'")
        }

        // Row 2 should now contain "Line0" (shifted down by 2)
        let row2 = await rowText(row: 2, startCol: 0, endCol: 5)
        XCTAssertEqual(row2, "Line0", "Row 2 should contain Line0 after SD 2")

        // Row 3 should contain "Line1"
        let row3 = await rowText(row: 3, startCol: 0, endCol: 5)
        XCTAssertEqual(row3, "Line1", "Row 3 should contain Line1 after SD 2")
    }

    /// DECOM: ESC[?6h enables origin mode. CUP is relative to scroll region.
    func testOriginMode() async {
        // Set scroll region to rows 5-15 (1-based)
        await feed("\u{1B}[5;15r")

        // Enable origin mode
        await feed("\u{1B}[?6h")

        let originMode = await grid.originMode
        XCTAssertTrue(originMode, "Origin mode should be enabled")

        // CUP 1;1 should now position to (scrollTop, 0) = (4, 0)
        await feed("\u{1B}[1;1H")
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 4, "With origin mode, CUP(1,1) should go to scroll top (row 4)")
        XCTAssertEqual(pos.col, 0, "With origin mode, CUP(1,1) should go to col 0")

        // Disable origin mode
        await feed("\u{1B}[?6l")
        let originOff = await grid.originMode
        XCTAssertFalse(originOff, "Origin mode should be disabled")

        // CUP 1;1 should now position to (0, 0)
        await feed("\u{1B}[1;1H")
        let posAfter = await grid.cursorPosition()
        XCTAssertEqual(posAfter.row, 0, "Without origin mode, CUP(1,1) should go to row 0")
        XCTAssertEqual(posAfter.col, 0, "Without origin mode, CUP(1,1) should go to col 0")
    }
}

// MARK: - 6. VTTestANSIColorsTest

/// vttest ANSI colors.
/// Validates standard foreground (30-37), background (40-47), bright foreground (90-97),
/// bright background (100-107), and default fg/bg (39/49).
final class VTTestANSIColorsTest: IntegrationTestBase {

    /// ESC[30m through ESC[37m set foreground color indexes 0-7.
    func testForegroundColors0_7() async {
        await feed("\u{1B}[1;1H")

        for i in 0..<8 {
            await feed("\u{1B}[\(30 + i)m")
            await feed("X")
            await feed("\u{1B}[0m")
        }

        for i in 0..<8 {
            let fg = await fgAt(row: 0, col: i)
            XCTAssertEqual(fg, .indexed(UInt8(i)),
                "SGR \(30 + i) should set fg color to index \(i)")
        }
    }

    /// ESC[40m through ESC[47m set background color indexes 0-7.
    func testBackgroundColors0_7() async {
        await feed("\u{1B}[1;1H")

        for i in 0..<8 {
            await feed("\u{1B}[\(40 + i)m")
            await feed(" ")
            await feed("\u{1B}[0m")
        }

        for i in 0..<8 {
            let bg = await bgAt(row: 0, col: i)
            XCTAssertEqual(bg, .indexed(UInt8(i)),
                "SGR \(40 + i) should set bg color to index \(i)")
        }
    }

    /// ESC[90m through ESC[97m set bright foreground color indexes 8-15.
    func testBrightForeground() async {
        await feed("\u{1B}[1;1H")

        for i in 0..<8 {
            await feed("\u{1B}[\(90 + i)m")
            await feed("X")
            await feed("\u{1B}[0m")
        }

        for i in 0..<8 {
            let fg = await fgAt(row: 0, col: i)
            XCTAssertEqual(fg, .indexed(UInt8(8 + i)),
                "SGR \(90 + i) should set fg color to index \(8 + i)")
        }
    }

    /// ESC[100m through ESC[107m set bright background color indexes 8-15.
    func testBrightBackground() async {
        await feed("\u{1B}[1;1H")

        for i in 0..<8 {
            await feed("\u{1B}[\(100 + i)m")
            await feed(" ")
            await feed("\u{1B}[0m")
        }

        for i in 0..<8 {
            let bg = await bgAt(row: 0, col: i)
            XCTAssertEqual(bg, .indexed(UInt8(8 + i)),
                "SGR \(100 + i) should set bg color to index \(8 + i)")
        }
    }

    /// ESC[39m restores default foreground. ESC[49m restores default background.
    func testDefaultFgBg() async {
        await feed("\u{1B}[1;1H")

        // Set non-default colors
        await feed("\u{1B}[31;42m")

        // Verify non-default
        let sgr1 = await grid.sgrState()
        XCTAssertEqual(sgr1.fg, .indexed(1), "Fg should be red (index 1)")
        XCTAssertEqual(sgr1.bg, .indexed(2), "Bg should be green (index 2)")

        // Reset fg to default
        await feed("\u{1B}[39m")
        let sgr2 = await grid.sgrState()
        XCTAssertEqual(sgr2.fg, .default, "SGR 39 should restore default foreground")
        XCTAssertEqual(sgr2.bg, .indexed(2), "Bg should remain green after SGR 39")

        // Reset bg to default
        await feed("\u{1B}[49m")
        let sgr3 = await grid.sgrState()
        XCTAssertEqual(sgr3.bg, .default, "SGR 49 should restore default background")

        // Write a character and verify it uses defaults
        await feed("Z")
        let fg = await fgAt(row: 0, col: 0)
        let bg = await bgAt(row: 0, col: 0)
        XCTAssertEqual(fg, .default, "Character should have default foreground")
        XCTAssertEqual(bg, .default, "Character should have default background")
    }
}

#endif
