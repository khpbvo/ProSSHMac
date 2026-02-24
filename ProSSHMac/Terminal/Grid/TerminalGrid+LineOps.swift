// Extracted from TerminalGrid.swift

import Foundation

extension TerminalGrid {

    // MARK: - A.6.7 Insert/Delete Characters

    /// Insert `n` blank characters at cursor position (ICH — CSI @).
    /// Shifts existing characters to the right. Characters pushed past the
    /// right edge are discarded.
    nonisolated func insertCharacters(_ n: Int) {
        insertBlanks(count: max(n, 1), atRow: cursor.row, col: cursor.col)
    }

    /// Delete `n` characters at cursor position (DCH — CSI P).
    /// Shifts remaining characters left. Blank characters fill from the right.
    nonisolated func deleteCharacters(_ n: Int) {
        let count = max(n, 1)
        let logicalRow = cursor.row
        let erasedCell = TerminalCell.erased(bgColor: currentBgColor, bgPacked: currentBgPacked)

        withActiveBuffer { buf, base in
            let row = physicalRow(logicalRow, base: base)
            // Release side-table entries for cells being deleted
            for col in cursor.col..<min(cursor.col + count, columns) {
                releaseCellGrapheme(buf[row][col].codepoint)
            }
            // Shift left
            for col in cursor.col..<columns {
                let srcCol = col + count
                if srcCol < columns {
                    buf[row][col] = buf[row][srcCol]
                } else {
                    buf[row][col] = erasedCell
                }
            }
        }
        markDirty(row: logicalRow)
    }

    /// Helper: insert blank characters at a specific position in a row.
    nonisolated func insertBlanks(count: Int, atRow row: Int, col: Int) {
        let erasedCell = TerminalCell.erased(bgColor: currentBgColor, bgPacked: currentBgPacked)

        withActiveBuffer { buf, base in
            let physical = physicalRow(row, base: base)
            // Release side-table entries for cells pushed off right edge
            let discardStart = max(columns - count, col)
            for c in discardStart..<columns {
                releaseCellGrapheme(buf[physical][c].codepoint)
            }
            // Shift right
            for c in stride(from: columns - 1, through: col + count, by: -1) {
                buf[physical][c] = buf[physical][c - count]
            }

            // Fill blanks
            for c in col..<min(col + count, columns) {
                buf[physical][c] = erasedCell
            }
        }
        markDirty(row: row)
    }

    // MARK: - A.6.8 Insert/Delete Lines

    /// Insert `n` blank lines at cursor row (IL — CSI L).
    /// Lines within the scroll region shift down; bottom lines are discarded.
    nonisolated func insertLines(_ n: Int) {
        let count = max(n, 1)

        // Only operates within scroll region, starting from cursor row
        let top = max(cursor.row, scrollTop)

        withActiveBuffer { buf, base in
            for _ in 0..<count {
                // Shift lines down
                for row in stride(from: scrollBottom, through: top + 1, by: -1) {
                    let dst = physicalRow(row, base: base)
                    let src = physicalRow(row - 1, base: base)
                    buf[dst] = buf[src]
                    markDirty(row: row)
                }
                let topPhysical = physicalRow(top, base: base)
                buf[topPhysical] = makeBlankRow()
                markDirty(row: top)
            }
        }
        cursor.col = 0
        cursor.pendingWrap = false
    }

    /// Delete `n` lines at cursor row (DL — CSI M).
    /// Lines within the scroll region shift up; blank lines fill from the bottom.
    nonisolated func deleteLines(_ n: Int) {
        let count = max(n, 1)

        let top = max(cursor.row, scrollTop)

        withActiveBuffer { buf, base in
            for _ in 0..<count {
                // Shift lines up
                for row in top..<scrollBottom {
                    let dst = physicalRow(row, base: base)
                    let src = physicalRow(row + 1, base: base)
                    buf[dst] = buf[src]
                    markDirty(row: row)
                }
                let bottomPhysical = physicalRow(scrollBottom, base: base)
                buf[bottomPhysical] = makeBlankRow()
                markDirty(row: scrollBottom)
            }
        }
        cursor.col = 0
        cursor.pendingWrap = false
    }

}
