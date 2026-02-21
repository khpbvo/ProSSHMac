// TerminalGridTests.swift
// ProSSHV2
//
// A.17 — Unit tests for all grid operations.
// Tests cursor movement, scrolling, erase operations, insert/delete,
// alternate buffer, cursor save/restore, tab stops, resize/reflow,
// auto-wrap, and mode flags.

#if canImport(XCTest)
import XCTest

// MARK: - TerminalGridTests

final class TerminalGridTests: XCTestCase {

    private var grid: TerminalGrid!

    override func setUp() async throws {
        grid = TerminalGrid(columns: 80, rows: 24)
    }

    // MARK: - Initialization

    func testDefaultDimensions() async {
        let cols = await grid.columns
        let rows = await grid.rows
        XCTAssertEqual(cols, 80)
        XCTAssertEqual(rows, 24)
    }

    func testAllCellsBlankInitially() async {
        for row in 0..<24 {
            for col in 0..<80 {
                let cell = await grid.cellAt(row: row, col: col)
                XCTAssertTrue(cell?.isBlank ?? false, "Cell at (\(row),\(col)) should be blank")
            }
        }
    }

    func testDefaultTabStops() async {
        let tabs = await grid.tabStops
        XCTAssertTrue(tabs.contains(8))
        XCTAssertTrue(tabs.contains(16))
        XCTAssertTrue(tabs.contains(24))
        XCTAssertFalse(tabs.contains(0))
    }

    // MARK: - Cursor Movement

    func testMoveCursorTo() async {
        await grid.moveCursorTo(row: 5, col: 10)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 5)
        XCTAssertEqual(pos.col, 10)
    }

    func testMoveCursorTo_Clamped() async {
        await grid.moveCursorTo(row: 100, col: 200)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 23) // Clamped to rows-1
        XCTAssertEqual(pos.col, 79) // Clamped to cols-1
    }

    func testMoveCursorUp() async {
        await grid.moveCursorTo(row: 10, col: 0)
        await grid.moveCursorUp(3)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 7)
    }

    func testMoveCursorUp_StopsAtTop() async {
        await grid.moveCursorTo(row: 2, col: 0)
        await grid.moveCursorUp(10)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 0) // Can't go above 0
    }

    func testMoveCursorDown() async {
        await grid.moveCursorTo(row: 5, col: 0)
        await grid.moveCursorDown(3)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 8)
    }

    func testMoveCursorDown_StopsAtBottom() async {
        await grid.moveCursorTo(row: 20, col: 0)
        await grid.moveCursorDown(100)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 23) // Default scrollBottom
    }

    func testMoveCursorForward() async {
        await grid.moveCursorTo(row: 0, col: 5)
        await grid.moveCursorForward(10)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 15)
    }

    func testMoveCursorBackward() async {
        await grid.moveCursorTo(row: 0, col: 10)
        await grid.moveCursorBackward(5)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 5)
    }

    func testMoveCursorBackward_StopsAtZero() async {
        await grid.moveCursorTo(row: 0, col: 3)
        await grid.moveCursorBackward(10)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 0)
    }

    func testCursorNextLine() async {
        await grid.moveCursorTo(row: 5, col: 20)
        await grid.moveCursorNextLine(2)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 7)
        XCTAssertEqual(pos.col, 0) // Column reset to 0
    }

    func testCursorPreviousLine() async {
        await grid.moveCursorTo(row: 10, col: 20)
        await grid.moveCursorPreviousLine(3)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 7)
        XCTAssertEqual(pos.col, 0)
    }

    func testSetCursorColumn() async {
        await grid.setCursorColumn(15)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 15)
    }

    func testSetCursorRow() async {
        await grid.setCursorRow(10)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 10)
    }

    // MARK: - Print Character

    func testPrintCharacter() async {
        await grid.printCharacter("A")
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "A")
        // Cursor should advance
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 1)
    }

    func testPrintMultipleCharacters() async {
        for ch in "Hello" {
            await grid.printCharacter(ch)
        }
        let h = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(h?.graphemeCluster, "H")
        let o = await grid.cellAt(row: 0, col: 4)
        XCTAssertEqual(o?.graphemeCluster, "o")
    }

    func testPrintWithAttributes() async {
        await grid.setCurrentAttributes(.bold)
        await grid.setCurrentFgColor(.indexed(1))
        await grid.printCharacter("X")
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell?.attributes.contains(.bold) ?? false)
        // boldIsBright is pre-applied at write-time: indexed(1) + bold → indexed(9)
        if TerminalDefaults.boldIsBright {
            XCTAssertEqual(cell?.fgColor, .indexed(9))
        } else {
            XCTAssertEqual(cell?.fgColor, .indexed(1))
        }
    }

    func testPrintStatusCheckmark_IsSingleWidth() async {
        await grid.printCharacter("A")
        await grid.printCharacter("✔")
        await grid.printCharacter("B")

        let b = await grid.cellAt(row: 0, col: 2)
        XCTAssertEqual(b?.graphemeCluster, "B")
    }

    func testPrintSparkleStar_IsSingleWidth() async {
        await grid.printCharacter("A")
        await grid.printCharacter("✳")
        await grid.printCharacter("B")

        let b = await grid.cellAt(row: 0, col: 2)
        XCTAssertEqual(b?.graphemeCluster, "B")
    }

    func testPrintCheckMarkButton_IsWide() async {
        await grid.printCharacter("A")
        await grid.printCharacter("✅")
        await grid.printCharacter("B")

        let continuation = await grid.cellAt(row: 0, col: 2)
        XCTAssertEqual(continuation?.width, 0)

        let b = await grid.cellAt(row: 0, col: 3)
        XCTAssertEqual(b?.graphemeCluster, "B")
    }

    // MARK: - Auto-Wrap

    func testAutoWrap() async {
        // Fill an entire row
        for _ in 0..<80 {
            await grid.printCharacter("A")
        }
        // Cursor should be in pending wrap state (col 79, pendingWrap=true)
        // Printing one more should wrap
        await grid.printCharacter("B")
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 1)
        XCTAssertEqual(pos.col, 1)
        let b = await grid.cellAt(row: 1, col: 0)
        XCTAssertEqual(b?.graphemeCluster, "B")
    }

    func testAutoWrapDisabled() async {
        await grid.setAutoWrapMode(false)
        // Fill a row
        for _ in 0..<80 {
            await grid.printCharacter("A")
        }
        // Should stay at last column
        await grid.printCharacter("B")
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 0)
        XCTAssertEqual(pos.col, 79)
    }

    // MARK: - Scroll Up/Down

    func testScrollUp() async {
        // Put something on row 0
        await grid.printCharacter("X")
        await grid.scrollUp(lines: 1)
        // Row 0 content should be gone (moved to scrollback)
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell?.isBlank ?? false)
    }

    func testScrollDown() async {
        await grid.moveCursorTo(row: 0, col: 0)
        await grid.printCharacter("X")
        await grid.scrollDown(lines: 1)
        // Row 0 should be blank (shifted down)
        let cell0 = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell0?.isBlank ?? false)
        // Row 1 should have our 'X'
        let cell1 = await grid.cellAt(row: 1, col: 0)
        XCTAssertEqual(cell1?.graphemeCluster, "X")
    }

    func testIndex_AtBottom_Scrolls() async {
        await grid.moveCursorTo(row: 23, col: 0)
        await grid.printCharacter("Z")
        await grid.index() // At bottom, should scroll
        // Row 23 should now be blank
        let cell = await grid.cellAt(row: 23, col: 0)
        XCTAssertTrue(cell?.isBlank ?? false)
        // 'Z' should have scrolled up to row 22
        let cellZ = await grid.cellAt(row: 22, col: 0)
        XCTAssertEqual(cellZ?.graphemeCluster, "Z")
    }

    func testReverseIndex_AtTop_Scrolls() async {
        await grid.moveCursorTo(row: 0, col: 0)
        await grid.printCharacter("Y")
        await grid.moveCursorTo(row: 0, col: 0)
        await grid.reverseIndex() // At top, should scroll down
        // Row 0 should be blank (content shifted down)
        let cell0 = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell0?.isBlank ?? false)
        // 'Y' should be on row 1
        let cell1 = await grid.cellAt(row: 1, col: 0)
        XCTAssertEqual(cell1?.graphemeCluster, "Y")
    }

    // MARK: - Scroll Region

    func testSetScrollRegion() async {
        await grid.setScrollRegion(top: 5, bottom: 15)
        let top = await grid.scrollTop
        let bottom = await grid.scrollBottom
        XCTAssertEqual(top, 5)
        XCTAssertEqual(bottom, 15)
    }

    func testScrollRegion_ScrollUp() async {
        await grid.setScrollRegion(top: 2, bottom: 5)
        await grid.moveCursorTo(row: 2, col: 0)
        await grid.printCharacter("A")
        await grid.moveCursorTo(row: 3, col: 0)
        await grid.printCharacter("B")

        await grid.scrollUp(lines: 1)

        // Row 2 should now have "B" (shifted up from row 3)
        let cell2 = await grid.cellAt(row: 2, col: 0)
        XCTAssertEqual(cell2?.graphemeCluster, "B")
        // Row 5 (bottom) should be blank
        let cell5 = await grid.cellAt(row: 5, col: 0)
        XCTAssertTrue(cell5?.isBlank ?? false)
    }

    func testResetScrollRegion() async {
        await grid.setScrollRegion(top: 5, bottom: 15)
        await grid.resetScrollRegion()
        let top = await grid.scrollTop
        let bottom = await grid.scrollBottom
        XCTAssertEqual(top, 0)
        XCTAssertEqual(bottom, 23)
    }

    // MARK: - Erase in Line (EL)

    func testEraseInLine_CursorToEnd() async {
        for ch in "Hello World" {
            await grid.printCharacter(ch)
        }
        await grid.moveCursorTo(row: 0, col: 5)
        await grid.eraseInLine(mode: 0) // From cursor to end
        // "Hello" should remain, " World" erased
        let h = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(h?.graphemeCluster, "H")
        let blank = await grid.cellAt(row: 0, col: 5)
        XCTAssertTrue(blank?.isBlank ?? false)
    }

    func testEraseInLine_BeginningToCursor() async {
        for ch in "Hello World" {
            await grid.printCharacter(ch)
        }
        await grid.moveCursorTo(row: 0, col: 5)
        await grid.eraseInLine(mode: 1) // Beginning to cursor
        let blank = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(blank?.isBlank ?? false)
        let w = await grid.cellAt(row: 0, col: 6)
        XCTAssertEqual(w?.graphemeCluster, "W")
    }

    func testEraseInLine_EntireLine() async {
        for ch in "Hello World" {
            await grid.printCharacter(ch)
        }
        await grid.eraseInLine(mode: 2)
        for col in 0..<11 {
            let cell = await grid.cellAt(row: 0, col: col)
            XCTAssertTrue(cell?.isBlank ?? false)
        }
    }

    // MARK: - Erase in Display (ED)

    func testEraseInDisplay_EntireScreen() async {
        await grid.printCharacter("X")
        await grid.eraseInDisplay(mode: 2)
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell?.isBlank ?? false)
    }

    func testEraseInDisplay_EntireScreenPlusScrollback() async {
        // Scroll some content into scrollback
        for _ in 0..<5 {
            await grid.scrollUp(lines: 1)
        }
        await grid.eraseInDisplay(mode: 3) // Erase screen + scrollback
        let sb = await grid.scrollbackBuffer
        XCTAssertEqual(sb.count, 0)
    }

    // MARK: - Erase Characters (ECH)

    func testEraseCharacters() async {
        for ch in "ABCDE" {
            await grid.printCharacter(ch)
        }
        await grid.moveCursorTo(row: 0, col: 1)
        await grid.eraseCharacters(3) // Erase B, C, D
        let b = await grid.cellAt(row: 0, col: 1)
        XCTAssertTrue(b?.isBlank ?? false)
        let e = await grid.cellAt(row: 0, col: 4)
        XCTAssertEqual(e?.graphemeCluster, "E")
    }

    // MARK: - Insert/Delete Characters

    func testInsertCharacters() async {
        for ch in "ABCDE" {
            await grid.printCharacter(ch)
        }
        await grid.moveCursorTo(row: 0, col: 1)
        await grid.insertCharacters(2)
        // A _ _ B C D E → A + 2 blanks + B pushed right
        let a = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(a?.graphemeCluster, "A")
        let blank1 = await grid.cellAt(row: 0, col: 1)
        XCTAssertTrue(blank1?.isBlank ?? false)
        let b = await grid.cellAt(row: 0, col: 3)
        XCTAssertEqual(b?.graphemeCluster, "B")
    }

    func testDeleteCharacters() async {
        for ch in "ABCDE" {
            await grid.printCharacter(ch)
        }
        await grid.moveCursorTo(row: 0, col: 1)
        await grid.deleteCharacters(2)
        // A D E _ _ → B,C deleted
        let a = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(a?.graphemeCluster, "A")
        let d = await grid.cellAt(row: 0, col: 1)
        XCTAssertEqual(d?.graphemeCluster, "D")
        let e = await grid.cellAt(row: 0, col: 2)
        XCTAssertEqual(e?.graphemeCluster, "E")
    }

    // MARK: - Insert/Delete Lines

    func testInsertLines() async {
        await grid.moveCursorTo(row: 0, col: 0)
        await grid.printCharacter("X")
        await grid.moveCursorTo(row: 0, col: 0)
        await grid.insertLines(1) // Insert blank line at row 0
        let blank = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(blank?.isBlank ?? false)
        let x = await grid.cellAt(row: 1, col: 0)
        XCTAssertEqual(x?.graphemeCluster, "X")
    }

    func testDeleteLines() async {
        await grid.moveCursorTo(row: 0, col: 0)
        await grid.printCharacter("A")
        await grid.moveCursorTo(row: 1, col: 0)
        await grid.printCharacter("B")
        await grid.moveCursorTo(row: 0, col: 0)
        await grid.deleteLines(1) // Delete row 0
        // Row 0 should now have "B"
        let b = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(b?.graphemeCluster, "B")
    }

    // MARK: - Alternate Buffer

    func testAlternateBuffer() async {
        await grid.printCharacter("P") // Primary
        await grid.enableAlternateBuffer()
        let alt = await grid.usingAlternateBuffer
        XCTAssertTrue(alt)
        // Alternate should be blank
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell?.isBlank ?? false)
    }

    func testAlternateBuffer_RestoresPrimary() async {
        await grid.printCharacter("P")
        await grid.enableAlternateBuffer()
        await grid.printCharacter("A") // Write in alternate
        await grid.disableAlternateBuffer()
        // Back to primary — "P" should be there
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "P")
    }

    // MARK: - Cursor Save/Restore

    func testCursorSaveRestore() async {
        await grid.moveCursorTo(row: 5, col: 10)
        await grid.setCurrentAttributes(.bold)
        await grid.saveCursor()

        await grid.moveCursorTo(row: 0, col: 0)
        await grid.setCurrentAttributes([])
        await grid.restoreCursor()

        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 5)
        XCTAssertEqual(pos.col, 10)
        let attrs = await grid.currentAttributes
        XCTAssertTrue(attrs.contains(.bold))
    }

    // MARK: - Tab Stops

    func testTabForward() async {
        await grid.moveCursorTo(row: 0, col: 0)
        await grid.tabForward()
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 8)
    }

    func testTabForwardMultiple() async {
        await grid.moveCursorTo(row: 0, col: 0)
        await grid.tabForward(count: 3)
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 24)
    }

    func testTabBackward() async {
        await grid.moveCursorTo(row: 0, col: 20)
        await grid.tabBackward()
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 16)
    }

    func testSetTabStop() async {
        await grid.moveCursorTo(row: 0, col: 5)
        await grid.setTabStop()
        let tabs = await grid.tabStops
        XCTAssertTrue(tabs.contains(5))
    }

    func testClearTabStop_Current() async {
        await grid.moveCursorTo(row: 0, col: 8)
        await grid.clearTabStop(mode: 0)
        let tabs = await grid.tabStops
        XCTAssertFalse(tabs.contains(8))
    }

    func testClearTabStop_All() async {
        await grid.clearTabStop(mode: 3)
        let tabs = await grid.tabStops
        XCTAssertTrue(tabs.isEmpty)
    }

    // MARK: - Line Feed / Carriage Return / Backspace

    func testLineFeed() async {
        await grid.moveCursorTo(row: 0, col: 5)
        await grid.lineFeed()
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 1)
        XCTAssertEqual(pos.col, 5) // LNM off: col preserved
    }

    func testLineFeedMode() async {
        await grid.setLineFeedMode(true)
        await grid.moveCursorTo(row: 0, col: 5)
        await grid.lineFeed()
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 1)
        XCTAssertEqual(pos.col, 0) // LNM on: CR+LF
    }

    func testCarriageReturn() async {
        await grid.moveCursorTo(row: 0, col: 10)
        await grid.carriageReturn()
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 0)
    }

    func testBackspace() async {
        await grid.moveCursorTo(row: 0, col: 5)
        await grid.backspace()
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 4)
    }

    func testBackspace_AtZero() async {
        await grid.moveCursorTo(row: 0, col: 0)
        await grid.backspace()
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 0) // Can't go below 0
    }

    // MARK: - Full Reset

    func testFullReset() async {
        await grid.printCharacter("X")
        await grid.moveCursorTo(row: 5, col: 5)
        await grid.setCurrentAttributes(.bold)
        await grid.fullReset()

        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.row, 0)
        XCTAssertEqual(pos.col, 0)
        let attrs = await grid.currentAttributes
        XCTAssertEqual(attrs, [])
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertTrue(cell?.isBlank ?? false)
    }

    // MARK: - Soft Reset

    func testSoftReset() async {
        await grid.setCurrentAttributes(.bold)
        await grid.setInsertMode(true)
        await grid.setCursorVisible(false)
        await grid.softReset()

        let attrs = await grid.currentAttributes
        XCTAssertEqual(attrs, [])
        let irm = await grid.insertMode
        XCTAssertFalse(irm)
        let visible = await grid.cursor.visible
        XCTAssertTrue(visible)
    }

    // MARK: - Resize

    func testResizeWidthIncrease() async {
        await grid.printCharacter("X")
        await grid.resize(newColumns: 120, newRows: 24)
        let cols = await grid.columns
        XCTAssertEqual(cols, 120)
        let cell = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell?.graphemeCluster, "X")
    }

    func testResizeHeightDecrease() async {
        await grid.resize(newColumns: 80, newRows: 10)
        let rows = await grid.rows
        XCTAssertEqual(rows, 10)
    }

    func testResizeNoOp() async {
        await grid.resize(newColumns: 80, newRows: 24) // Same dims
        let cols = await grid.columns
        let rows = await grid.rows
        XCTAssertEqual(cols, 80)
        XCTAssertEqual(rows, 24)
    }

    // MARK: - Snapshot

    func testSnapshot() async {
        await grid.printCharacter("S")
        let snap = await grid.snapshot()
        XCTAssertEqual(snap.columns, 80)
        XCTAssertEqual(snap.rows, 24)
        XCTAssertEqual(snap.cells.count, 80 * 24)
    }

    func testTerminalCellCacheCoherence() async {
        var cell = TerminalCell(
            graphemeCluster: "A",
            fgColor: .indexed(2),
            bgColor: .rgb(1, 2, 3),
            underlineColor: .indexed(4),
            attributes: [.underline],
            underlineStyle: .single,
            width: 1,
            isDirty: false
        )

        XCTAssertEqual(cell.primaryCodepoint, UInt32("A".unicodeScalars.first!.value))
        XCTAssertEqual(cell.fgPackedRGBA, TerminalColor.indexed(2).packedRGBA())
        XCTAssertEqual(cell.bgPackedRGBA, TerminalColor.rgb(1, 2, 3).packedRGBA())
        XCTAssertEqual(cell.underlinePackedRGBA, TerminalColor.indexed(4).packedRGBA())

        cell.graphemeCluster = "é"
        cell.fgColor = .rgb(8, 9, 10)
        cell.bgColor = .indexed(6)
        cell.underlineColor = .rgb(11, 12, 13)

        XCTAssertEqual(cell.primaryCodepoint, UInt32("é".unicodeScalars.first!.value))
        XCTAssertEqual(cell.fgPackedRGBA, TerminalColor.rgb(8, 9, 10).packedRGBA())
        XCTAssertEqual(cell.bgPackedRGBA, TerminalColor.indexed(6).packedRGBA())
        XCTAssertEqual(cell.underlinePackedRGBA, TerminalColor.rgb(11, 12, 13).packedRGBA())

        cell.clear()
        XCTAssertEqual(cell.primaryCodepoint, 0)
        XCTAssertEqual(cell.fgPackedRGBA, 0)
        XCTAssertEqual(cell.bgPackedRGBA, 0)
        XCTAssertEqual(cell.underlinePackedRGBA, 0)

        cell.erase(bgColor: .indexed(5))
        XCTAssertEqual(cell.primaryCodepoint, 0)
        XCTAssertEqual(cell.fgPackedRGBA, 0)
        XCTAssertEqual(cell.bgPackedRGBA, TerminalColor.indexed(5).packedRGBA())
        XCTAssertEqual(cell.underlinePackedRGBA, 0)
    }

    func testSnapshotUsesCachedCellFields() async {
        let styledCell = TerminalCell(
            graphemeCluster: "A",
            fgColor: .indexed(1),
            bgColor: .indexed(2),
            underlineColor: .indexed(3),
            attributes: [.bold, .underline],
            underlineStyle: .single,
            width: 1,
            isDirty: true
        )
        await grid.setCellAt(row: 0, col: 0, cell: styledCell)

        let snapshot = await grid.snapshot()
        let snapshotCell = snapshot.cells[0]

        XCTAssertEqual(snapshotCell.glyphIndex, styledCell.primaryCodepoint)
        XCTAssertEqual(snapshotCell.bgColor, styledCell.bgPackedRGBA)
        XCTAssertEqual(snapshotCell.underlineColor, styledCell.underlinePackedRGBA)

        // boldIsBright is now applied at write-time (printCharacter/printASCIIBytesBulk),
        // not at snapshot-time. setCellAt doesn't apply it, so the packed value is used as-is.
        XCTAssertEqual(snapshotCell.fgColor, styledCell.fgPackedRGBA)
    }

    func testPartialScrollRegionRowIndirectionKeepsRowsConsistent() async {
        let markers: [Character] = ["A", "B", "C", "D", "E", "F"]
        for (row, marker) in markers.enumerated() {
            await grid.moveCursorTo(row: row, col: 0)
            await grid.printCharacter(marker)
        }

        await grid.setScrollRegion(top: 1, bottom: 4)
        await grid.scrollUp(lines: 2)

        XCTAssertEqual((await grid.cellAt(row: 0, col: 0))?.graphemeCluster, "A")
        XCTAssertEqual((await grid.cellAt(row: 1, col: 0))?.graphemeCluster, "D")
        XCTAssertEqual((await grid.cellAt(row: 2, col: 0))?.graphemeCluster, "E")
        XCTAssertTrue((await grid.cellAt(row: 3, col: 0))?.isBlank ?? false)
        XCTAssertTrue((await grid.cellAt(row: 4, col: 0))?.isBlank ?? false)
        XCTAssertEqual((await grid.cellAt(row: 5, col: 0))?.graphemeCluster, "F")
        XCTAssertEqual(await grid.scrollbackCount, 2)

        await grid.scrollDown(lines: 1)

        XCTAssertEqual((await grid.cellAt(row: 0, col: 0))?.graphemeCluster, "A")
        XCTAssertTrue((await grid.cellAt(row: 1, col: 0))?.isBlank ?? false)
        XCTAssertEqual((await grid.cellAt(row: 2, col: 0))?.graphemeCluster, "D")
        XCTAssertEqual((await grid.cellAt(row: 3, col: 0))?.graphemeCluster, "E")
        XCTAssertTrue((await grid.cellAt(row: 4, col: 0))?.isBlank ?? false)
        XCTAssertEqual((await grid.cellAt(row: 5, col: 0))?.graphemeCluster, "F")

        let snapshot = await grid.snapshot()
        XCTAssertEqual(snapshotText(snapshot, row: 0, startCol: 0, count: 1), "A")
        XCTAssertEqual(snapshotText(snapshot, row: 1, startCol: 0, count: 1), " ")
        XCTAssertEqual(snapshotText(snapshot, row: 2, startCol: 0, count: 1), "D")
        XCTAssertEqual(snapshotText(snapshot, row: 3, startCol: 0, count: 1), "E")
        XCTAssertEqual(snapshotText(snapshot, row: 5, startCol: 0, count: 1), "F")
    }

    // MARK: - Repeat Last Character

    func testRepeatLastCharacter() async {
        await grid.printCharacter("R")
        await grid.repeatLastCharacter(3)
        // Should have 4 R's
        for col in 0..<4 {
            let cell = await grid.cellAt(row: 0, col: col)
            XCTAssertEqual(cell?.graphemeCluster, "R")
        }
    }

    // MARK: - Mode Setters

    func testInsertMode() async {
        await grid.setInsertMode(true)
        let irm = await grid.insertMode
        XCTAssertTrue(irm)
    }

    func testReverseVideo() async {
        await grid.setReverseVideo(true)
        let rv = await grid.reverseVideo
        XCTAssertTrue(rv)
    }

    func testOriginMode() async {
        await grid.setOriginMode(true)
        let om = await grid.originMode
        XCTAssertTrue(om)
    }

    func testMouseTracking() async {
        await grid.setMouseTracking(.x10)
        let mt = await grid.mouseTracking
        XCTAssertEqual(mt, .x10)
    }

    func testMouseEncoding() async {
        await grid.setMouseEncoding(.sgr)
        let me = await grid.mouseEncoding
        XCTAssertEqual(me, .sgr)
    }

    func testFocusReporting() async {
        await grid.setFocusReporting(true)
        let fr = await grid.focusReporting
        XCTAssertTrue(fr)
    }

    // MARK: - Window Title / OSC Properties

    func testWindowTitle() async {
        await grid.setWindowTitle("Test Title")
        let title = await grid.windowTitle
        XCTAssertEqual(title, "Test Title")
    }

    func testIconName() async {
        await grid.setIconName("TestIcon")
        let icon = await grid.iconName
        XCTAssertEqual(icon, "TestIcon")
    }

    // MARK: - Palette Colors

    func testSetPaletteColor() async {
        await grid.setPaletteColor(index: 0, r: 128, g: 64, b: 255)
        let (r, g, b) = await grid.paletteColor(index: 0)
        XCTAssertEqual(r, 128)
        XCTAssertEqual(g, 64)
        XCTAssertEqual(b, 255)
    }

    func testResetPaletteColor() async {
        await grid.setPaletteColor(index: 0, r: 128, g: 64, b: 255)
        await grid.resetPaletteColor(index: 0)
        let (r, g, b) = await grid.paletteColor(index: 0)
        // Should be back to default
        let defaults = ColorPalette.rgb(forIndex: 0)
        XCTAssertEqual(r, defaults.r)
        XCTAssertEqual(g, defaults.g)
        XCTAssertEqual(b, defaults.b)
    }

    // MARK: - Cursor Color

    func testCursorColor() async {
        await grid.setCursorColor(r: 255, g: 128, b: 0)
        let cc = await grid.cursorColor
        XCTAssertNotNil(cc)
        XCTAssertEqual(cc?.0, 255)
        XCTAssertEqual(cc?.1, 128)
        XCTAssertEqual(cc?.2, 0)
    }

    func testResetCursorColor() async {
        await grid.setCursorColor(r: 255, g: 0, b: 0)
        await grid.resetCursorColor()
        let cc = await grid.cursorColor
        XCTAssertNil(cc)
    }

    // MARK: - Screen Alignment Pattern

    func testScreenAlignmentPattern() async {
        await grid.screenAlignmentPattern()
        // Every cell should be 'E'
        let cell00 = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell00?.graphemeCluster, "E")
        let cellLast = await grid.cellAt(row: 23, col: 79)
        XCTAssertEqual(cellLast?.graphemeCluster, "E")
    }

    // MARK: - Wide Characters

    func testWideCharacter() async {
        await grid.printCharacter("中")
        let cell0 = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell0?.graphemeCluster, "中")
        XCTAssertEqual(cell0?.width, 2)
        // Continuation cell
        let cell1 = await grid.cellAt(row: 0, col: 1)
        XCTAssertEqual(cell1?.width, 0)
        // Cursor should be at col 2
        let pos = await grid.cursorPosition()
        XCTAssertEqual(pos.col, 2)
    }

    // MARK: - Charset State

    func testCharsetState() async {
        await grid.setCharset(g: 0, charset: .decSpecialGraphics)
        await grid.setActiveCharset(1)
        let cs = await grid.charsetState()
        XCTAssertEqual(cs.activeCharset, 1)
        XCTAssertEqual(cs.g0, .decSpecialGraphics)
        XCTAssertEqual(cs.g1, .ascii) // Default
    }

    // MARK: - SGR State

    func testSGRState() async {
        await grid.setCurrentAttributes([.bold, .italic])
        await grid.setCurrentFgColor(.indexed(5))
        await grid.setCurrentBgColor(.rgb(10, 20, 30))
        let sgr = await grid.sgrState()
        XCTAssertTrue(sgr.attributes.contains(.bold))
        XCTAssertTrue(sgr.attributes.contains(.italic))
        XCTAssertEqual(sgr.fg, .indexed(5))
        XCTAssertEqual(sgr.bg, .rgb(10, 20, 30))
    }

    // MARK: - Insert Mode

    func testInsertModePrint() async {
        for ch in "ABCDE" {
            await grid.printCharacter(ch)
        }
        await grid.moveCursorTo(row: 0, col: 1)
        await grid.setInsertMode(true)
        await grid.printCharacter("X")
        // Should be: A X B C D E (B–E shifted right)
        let a = await grid.cellAt(row: 0, col: 0)
        XCTAssertEqual(a?.graphemeCluster, "A")
        let x = await grid.cellAt(row: 0, col: 1)
        XCTAssertEqual(x?.graphemeCluster, "X")
        let b = await grid.cellAt(row: 0, col: 2)
        XCTAssertEqual(b?.graphemeCluster, "B")
    }

    // MARK: - Synchronized Output (Mode 2026)

    func testSynchronizedOutput_CapturesUnsyncedFrameOnEnable() async {
        // Seed a committed frame.
        for ch in "OLD" {
            await grid.printCharacter(ch)
        }
        _ = await grid.snapshot()

        // Simulate: ... 2026l (sync off), draw, 2026h (sync on) in one parser chunk.
        await grid.setSynchronizedOutput(true)
        await grid.setSynchronizedOutput(false)

        await grid.moveCursorTo(row: 0, col: 0)
        await grid.eraseInLine(mode: 2)
        for ch in "NEW" {
            await grid.printCharacter(ch)
        }

        await grid.setSynchronizedOutput(true)

        // While sync is active, snapshot() must return the newly captured frame.
        let frozen = await grid.snapshot()
        XCTAssertEqual(snapshotText(frozen, row: 0, startCol: 0, count: 3), "NEW")
    }

    func testSynchronizedOutput_ConsumeSyncExitSnapshotReturnsLatestUnsyncedFrame() async {
        for ch in "OLD" {
            await grid.printCharacter(ch)
        }
        _ = await grid.snapshot()

        await grid.setSynchronizedOutput(true)
        await grid.setSynchronizedOutput(false)

        await grid.moveCursorTo(row: 0, col: 0)
        await grid.eraseInLine(mode: 2)
        for ch in "NEW" {
            await grid.printCharacter(ch)
        }
        await grid.setSynchronizedOutput(true)

        let syncExit = await grid.consumeSyncExitSnapshot()
        XCTAssertNotNil(syncExit)
        if let syncExit {
            XCTAssertEqual(snapshotText(syncExit, row: 0, startCol: 0, count: 3), "NEW")
        }
    }

    private func snapshotText(
        _ snapshot: GridSnapshot,
        row: Int,
        startCol: Int,
        count: Int
    ) -> String {
        var out = ""
        for col in startCol..<(startCol + count) {
            let idx = row * snapshot.columns + col
            guard idx >= 0, idx < snapshot.cells.count else { continue }
            let cp = snapshot.cells[idx].glyphIndex
            if cp == 0 {
                out.append(" ")
            } else if let scalar = UnicodeScalar(cp) {
                out.append(Character(scalar))
            }
        }
        return out
    }
}
#endif
