// Extracted from TerminalGrid.swift

import Foundation

extension TerminalGrid {

    // MARK: - A.6.1 Cell Read/Write

    /// Read the cell at the given position.
    nonisolated func cellAt(row: Int, col: Int) -> TerminalCell? {
        guard row >= 0 && row < rows && col >= 0 && col < columns else { return nil }
        let base = activeRowBase
        return cells[physicalRow(row, base: base)][col]
    }

    /// Write a cell at the given position and mark it dirty.
    nonisolated func setCellAt(row: Int, col: Int, cell: TerminalCell) {
        guard row >= 0 && row < rows && col >= 0 && col < columns else { return }
        withActiveBuffer { buffer, base in
            let physical = physicalRow(row, base: base)
            releaseCellGrapheme(buffer[physical][col].codepoint)
            buffer[physical][col] = cell
        }
        markDirty(row: row)
    }

    // MARK: - A.6.2 Cursor Movement

    /// Move cursor to absolute position (CUP / HVP — CSI H / CSI f).
    /// Parameters are 1-based from the remote side; convert to 0-based here.
    nonisolated func moveCursorTo(row: Int, col: Int) {
        cursor.moveTo(
            row: row,
            col: col,
            gridRows: rows,
            gridCols: columns,
            originMode: originMode,
            scrollTop: scrollTop,
            scrollBottom: scrollBottom
        )
    }

    /// Move cursor up by `n` rows (CUU — CSI A). Does not scroll.
    nonisolated func moveCursorUp(_ n: Int) {
        cursor.moveUp(n, scrollTop: scrollTop, originMode: originMode)
    }

    /// Move cursor down by `n` rows (CUD — CSI B). Does not scroll.
    nonisolated func moveCursorDown(_ n: Int) {
        cursor.moveDown(n, scrollBottom: scrollBottom, gridRows: rows, originMode: originMode)
    }

    /// Move cursor forward (right) by `n` columns (CUF — CSI C).
    nonisolated func moveCursorForward(_ n: Int) {
        cursor.moveForward(n, gridCols: columns)
    }

    /// Move cursor backward (left) by `n` columns (CUB — CSI D).
    nonisolated func moveCursorBackward(_ n: Int) {
        cursor.moveBackward(n)
    }

    /// Move cursor to beginning of line `n` rows down (CNL — CSI E).
    nonisolated func moveCursorNextLine(_ n: Int) {
        cursor.moveToNextLine(n, scrollBottom: scrollBottom, gridRows: rows, originMode: originMode)
    }

    /// Move cursor to beginning of line `n` rows up (CPL — CSI F).
    nonisolated func moveCursorPreviousLine(_ n: Int) {
        cursor.moveToPreviousLine(n, scrollTop: scrollTop, originMode: originMode)
    }

    /// Set cursor column absolutely (CHA — CSI G).
    nonisolated func setCursorColumn(_ col: Int) {
        cursor.setColumn(col, gridCols: columns)
    }

    /// Set cursor row absolutely (VPA — CSI d).
    nonisolated func setCursorRow(_ row: Int) {
        cursor.setRow(
            row,
            gridRows: rows,
            originMode: originMode,
            scrollTop: scrollTop,
            scrollBottom: scrollBottom
        )
    }

}
