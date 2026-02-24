// Extracted from TerminalGrid.swift

import Foundation

extension TerminalGrid {

    // MARK: - Full Reset (RIS — ESC c)

    /// Perform a full terminal reset.
    nonisolated func fullReset() {
        // Reset buffers
        let blankRow = makeBlankRow()
        primaryCells = [[TerminalCell]](repeating: blankRow, count: rows)
        alternateCells = [[TerminalCell]](repeating: blankRow, count: rows)
        primaryRowBase = 0
        alternateRowBase = 0
        primaryRowMap = Array(0..<rows)
        alternateRowMap = Array(0..<rows)
        usingAlternateBuffer = false

        // Reset cursor
        cursor = CursorState()

        // Reset scroll region
        scrollTop = 0
        scrollBottom = rows - 1

        // Reset modes
        originMode = false
        autoWrapMode = true
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        bracketedPasteMode = false
        synchronizedOutput = false
        lastSnapshot = nil
        reverseVideo = false
        mouseTracking = .none
        mouseEncoding = .x10
        focusReporting = false
        lineFeedMode = false

        // Reset charsets
        activeCharset = 0
        g0Charset = .ascii
        g1Charset = .ascii

        // Reset tab stops
        resetTabStops()

        // Reset attributes
        currentAttributes = []
        currentFgColor = .default
        currentBgColor = .default
        currentUnderlineColor = .default
        currentUnderlineStyle = .none
        currentHyperlink = nil
        invalidatePackedColors()

        // Reset scrollback and side table
        scrollback.clear()
        graphemeSideTable.clear()

        lastPrintedChar = nil

        markAllDirty()
    }

    /// Soft terminal reset (DECSTR — CSI ! p).
    nonisolated func softReset() {
        cursor.visible = true
        cursor.style = .block
        cursor.pendingWrap = false

        originMode = false
        autoWrapMode = true
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        mouseTracking = .none
        mouseEncoding = .x10
        reverseVideo = false

        scrollTop = 0
        scrollBottom = rows - 1

        activeCharset = 0
        g0Charset = .ascii
        g1Charset = .ascii

        currentAttributes = []
        currentFgColor = .default
        currentBgColor = .default
        currentUnderlineColor = .default
        currentUnderlineStyle = .none
        invalidatePackedColors()

        resetTabStops()

        cursor.savedPrimary = nil
        cursor.savedAlternate = nil
    }

    /// Fill screen with 'E' for alignment test (DECALN — ESC # 8).
    nonisolated func screenAlignmentPattern() {
        let eCell = TerminalCell(
            codepoint: 0x45, fgPacked: 0, bgPacked: 0, ulPacked: 0,
            attributes: [], underlineStyle: .none, width: 1)
        withActiveBuffer { buf, base in
            for row in 0..<rows {
                let physical = physicalRow(row, base: base)
                for col in 0..<columns {
                    releaseCellGrapheme(buf[physical][col].codepoint)
                    buf[physical][col] = eCell
                }
            }
        }
        cursor.moveTo(row: 0, col: 0, gridRows: rows, gridCols: columns)
        markAllDirty()
    }

    // MARK: - Resize

    /// Resize the terminal grid with proper content reflow.
    /// Primary buffer uses GridReflow for correct unwrap/rewrap behavior.
    /// Alternate buffer uses simple resize (TUI apps redraw on SIGWINCH anyway).
    nonisolated func resize(newColumns: Int, newRows: Int) {
        guard newColumns > 0 && newRows > 0 else { return }
        guard newColumns != columns || newRows != rows else { return }

        let oldColumns = columns

        // When the alternate buffer is active, the primary cursor is saved
        // in cursor.savedPrimary. Use it for reflowing the primary buffer
        // so the primary cursor position is preserved correctly.
        let primaryCursorRow = usingAlternateBuffer
            ? (cursor.savedPrimary?.row ?? 0)
            : cursor.row
        let primaryCursorCol = usingAlternateBuffer
            ? (cursor.savedPrimary?.col ?? 0)
            : cursor.col

        // Resolve all side-table entries before linearizing so reflow
        // doesn't carry stale side-table indices.
        resolveAllSideTableEntries()

        let primaryForReflow = linearizedRows(primaryCells, base: primaryRowBase, map: primaryRowMap)

        // Reflow primary buffer (the one with scrollback that needs proper reflow)
        let reflowResult = GridReflow.reflow(
            screenRows: primaryForReflow,
            scrollback: scrollback,
            cursorRow: primaryCursorRow,
            cursorCol: primaryCursorCol,
            oldColumns: oldColumns,
            newColumns: newColumns,
            newRows: newRows
        )

        primaryCells = reflowResult.screenRows
        primaryRowBase = 0

        // Rebuild scrollback from reflow result
        scrollback = ScrollbackBuffer(maxLines: maxScrollbackLines)
        for line in reflowResult.scrollbackLines {
            scrollback.push(line)
        }

        // Simple resize for alternate buffer (TUI apps redraw on SIGWINCH)
        let alternateForResize = linearizedRows(alternateCells, base: alternateRowBase, map: alternateRowMap)
        alternateCells = simpleResizeBuffer(
            alternateForResize, newRows: newRows, newColumns: newColumns
        )
        alternateRowBase = 0

        // Update cursor from reflow result
        if !usingAlternateBuffer {
            cursor.row = reflowResult.cursorRow
            cursor.col = reflowResult.cursorCol
        } else {
            // Update the saved primary cursor from the reflow result
            if var saved = cursor.savedPrimary {
                saved.row = reflowResult.cursorRow
                saved.col = reflowResult.cursorCol
                cursor.savedPrimary = saved
            }
            cursor.row = min(cursor.row, newRows - 1)
            cursor.col = min(cursor.col, newColumns - 1)
        }
        cursor.pendingWrap = false

        columns = newColumns
        rows = newRows
        primaryRowMap = Array(0..<newRows)
        alternateRowMap = Array(0..<newRows)

        // Adjust scroll region
        scrollTop = 0
        scrollBottom = newRows - 1

        // Reset tab stops for new width
        tabStopMask = TerminalDefaults.defaultTabStopMask(columns: newColumns)

        markAllDirty()
    }

    /// Simple buffer resize without reflow (for alternate screen buffer).
    nonisolated func simpleResizeBuffer(
        _ buffer: [[TerminalCell]],
        newRows: Int, newColumns: Int
    ) -> [[TerminalCell]] {
        var newBuf = [[TerminalCell]]()
        newBuf.reserveCapacity(newRows)

        for row in 0..<newRows {
            if row < buffer.count {
                var existingRow = buffer[row]
                if newColumns > existingRow.count {
                    existingRow.append(contentsOf:
                        [TerminalCell](repeating: .blank, count: newColumns - existingRow.count)
                    )
                } else if newColumns < existingRow.count {
                    existingRow = Array(existingRow.prefix(newColumns))
                }
                newBuf.append(existingRow)
            } else {
                newBuf.append([TerminalCell](repeating: .blank, count: newColumns))
            }
        }

        return newBuf
    }

}
