// Extracted from TerminalGrid.swift

import Foundation

extension TerminalGrid {

    // MARK: - A.6.5 Erase in Line (EL — CSI K)

    /// Erase in line.
    /// - 0: From cursor to end of line (inclusive)
    /// - 1: From beginning of line to cursor (inclusive)
    /// - 2: Entire line
    nonisolated func eraseInLine(mode: Int) {
        let logicalRow = cursor.row
        let erasedCell = TerminalCell.erased(bgColor: currentBgColor, bgPacked: currentBgPacked)

        withActiveBuffer { buf, base in
            let row = physicalRow(logicalRow, base: base)
            switch mode {
            case 0: // Cursor to end
                for col in cursor.col..<columns {
                    releaseCellGrapheme(buf[row][col].codepoint)
                    buf[row][col] = erasedCell
                }
            case 1: // Beginning to cursor
                for col in 0...cursor.col {
                    releaseCellGrapheme(buf[row][col].codepoint)
                    buf[row][col] = erasedCell
                }
            case 2: // Entire line
                for col in 0..<columns {
                    releaseCellGrapheme(buf[row][col].codepoint)
                    buf[row][col] = erasedCell
                }
            default:
                break
            }
        }
        markDirty(row: logicalRow)
    }

    // MARK: - A.6.6 Erase in Display (ED — CSI J)

    /// Erase in display.
    /// - 0: From cursor to end of screen
    /// - 1: From beginning of screen to cursor
    /// - 2: Entire screen
    /// - 3: Entire screen + scrollback
    nonisolated func eraseInDisplay(mode: Int) {
        let erasedCell = TerminalCell.erased(bgColor: currentBgColor, bgPacked: currentBgPacked)

        withActiveBuffer { buf, base in
            switch mode {
            case 0: // Cursor to end
                // Rest of current line
                let cursorPhysical = physicalRow(cursor.row, base: base)
                for col in cursor.col..<columns {
                    releaseCellGrapheme(buf[cursorPhysical][col].codepoint)
                    buf[cursorPhysical][col] = erasedCell
                }
                markDirty(row: cursor.row)
                // All lines below
                for row in (cursor.row + 1)..<rows {
                    let physical = physicalRow(row, base: base)
                    for col in 0..<columns {
                        releaseCellGrapheme(buf[physical][col].codepoint)
                        buf[physical][col] = erasedCell
                    }
                    markDirty(row: row)
                }

            case 1: // Beginning to cursor
                // All lines above
                for row in 0..<cursor.row {
                    let physical = physicalRow(row, base: base)
                    for col in 0..<columns {
                        releaseCellGrapheme(buf[physical][col].codepoint)
                        buf[physical][col] = erasedCell
                    }
                    markDirty(row: row)
                }
                // Start of current line to cursor
                let cursorPhysical = physicalRow(cursor.row, base: base)
                for col in 0...cursor.col {
                    releaseCellGrapheme(buf[cursorPhysical][col].codepoint)
                    buf[cursorPhysical][col] = erasedCell
                }
                markDirty(row: cursor.row)

            case 2: // Entire screen
                for row in 0..<rows {
                    let physical = physicalRow(row, base: base)
                    for col in 0..<columns {
                        releaseCellGrapheme(buf[physical][col].codepoint)
                        buf[physical][col] = erasedCell
                    }
                    markDirty(row: row)
                }

            case 3: // Entire screen + scrollback
                for row in 0..<rows {
                    let physical = physicalRow(row, base: base)
                    for col in 0..<columns {
                        releaseCellGrapheme(buf[physical][col].codepoint)
                        buf[physical][col] = erasedCell
                    }
                    markDirty(row: row)
                }
                scrollback.clear()

            default:
                break
            }
        }
    }

    /// Erase characters at cursor position (ECH — CSI X).
    nonisolated func eraseCharacters(_ n: Int) {
        let count = max(n, 1)
        let logicalRow = cursor.row
        let erasedCell = TerminalCell.erased(bgColor: currentBgColor, bgPacked: currentBgPacked)

        withActiveBuffer { buf, base in
            let row = physicalRow(logicalRow, base: base)
            for col in cursor.col..<min(cursor.col + count, columns) {
                releaseCellGrapheme(buf[row][col].codepoint)
                buf[row][col] = erasedCell
            }
        }
        markDirty(row: logicalRow)
    }

}
