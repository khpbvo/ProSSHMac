// CursorState.swift
// ProSSHV2
//
// Cursor position management, style, save/restore state for DECSC/DECRC.

import Foundation

// MARK: - SavedCursorState

/// State saved by DECSC (ESC 7) and restored by DECRC (ESC 8).
/// Captures everything needed to fully restore cursor context.
nonisolated struct SavedCursorState: Sendable {
    let row: Int
    let col: Int
    let attributes: CellAttributes
    let fgColor: TerminalColor
    let bgColor: TerminalColor
    let underlineColor: TerminalColor
    let underlineStyle: UnderlineStyle
    let originMode: Bool
    let autoWrapMode: Bool
    let activeCharset: Int
    let g0Charset: Charset
    let g1Charset: Charset
}

// MARK: - CursorState

/// Manages the cursor position, style, visibility, and blink state.
/// Provides clamping logic to keep the cursor within grid/scroll region bounds.
nonisolated struct CursorState: Sendable {

    /// Current cursor row (0-based, relative to top of screen).
    var row: Int = 0

    /// Current cursor column (0-based).
    var col: Int = 0

    /// Whether the cursor is visible (DECTCEM — mode 25).
    var visible: Bool = true

    /// Cursor display style (block, underline, bar).
    var style: CursorStyle = .block

    /// Whether cursor blink is enabled (mode 12).
    var blinkEnabled: Bool = true

    /// Tracks whether the cursor is in the "pending wrap" state.
    /// When a character is printed at the last column, the cursor doesn't
    /// immediately wrap — it enters this state. The next printable character
    /// triggers the actual wrap + line feed.
    var pendingWrap: Bool = false

    /// Saved cursor state for primary screen (DECSC/DECRC).
    var savedPrimary: SavedCursorState?

    /// Saved cursor state for alternate screen buffer.
    var savedAlternate: SavedCursorState?

    // MARK: - Position Management

    /// Move cursor to an absolute position, clamped to grid bounds.
    /// Clears the pending wrap state.
    mutating func moveTo(row: Int, col: Int, gridRows: Int, gridCols: Int) {
        self.row = clampRow(row, gridRows: gridRows)
        self.col = clampCol(col, gridCols: gridCols)
        self.pendingWrap = false
    }

    /// Move cursor to an absolute position, clamped to scroll region when origin mode is active.
    /// Clears the pending wrap state.
    mutating func moveTo(
        row: Int,
        col: Int,
        gridRows: Int,
        gridCols: Int,
        originMode: Bool,
        scrollTop: Int,
        scrollBottom: Int
    ) {
        if originMode {
            // In origin mode, row is relative to scroll region top
            let absoluteRow = scrollTop + row
            self.row = max(scrollTop, min(absoluteRow, scrollBottom))
        } else {
            self.row = clampRow(row, gridRows: gridRows)
        }
        self.col = clampCol(col, gridCols: gridCols)
        self.pendingWrap = false
    }

    /// Move cursor up by `n` rows, clamped. Does not scroll.
    /// When origin mode is active, clamps to scroll region top;
    /// otherwise clamps to screen top (row 0).
    mutating func moveUp(_ n: Int, scrollTop: Int, originMode: Bool) {
        let limit = originMode ? scrollTop : 0
        row = max(limit, row - max(n, 1))
        pendingWrap = false
    }

    /// Move cursor down by `n` rows, clamped. Does not scroll.
    /// When origin mode is active, clamps to scroll region bottom;
    /// otherwise clamps to screen bottom (gridRows - 1).
    mutating func moveDown(_ n: Int, scrollBottom: Int, gridRows: Int, originMode: Bool) {
        let limit = originMode ? scrollBottom : (gridRows - 1)
        row = min(limit, row + max(n, 1))
        pendingWrap = false
    }

    /// Move cursor forward (right) by `n` columns, clamped.
    mutating func moveForward(_ n: Int, gridCols: Int) {
        col = min(gridCols - 1, col + max(n, 1))
        pendingWrap = false
    }

    /// Move cursor backward (left) by `n` columns, clamped.
    mutating func moveBackward(_ n: Int) {
        col = max(0, col - max(n, 1))
        pendingWrap = false
    }

    /// Move cursor to the beginning of the line `n` rows down.
    mutating func moveToNextLine(_ n: Int, scrollBottom: Int, gridRows: Int, originMode: Bool) {
        let limit = originMode ? scrollBottom : (gridRows - 1)
        row = min(limit, row + max(n, 1))
        col = 0
        pendingWrap = false
    }

    /// Move cursor to the beginning of the line `n` rows up.
    mutating func moveToPreviousLine(_ n: Int, scrollTop: Int, originMode: Bool) {
        let limit = originMode ? scrollTop : 0
        row = max(limit, row - max(n, 1))
        col = 0
        pendingWrap = false
    }

    /// Set cursor column to an absolute value (CHA — CSI G).
    mutating func setColumn(_ c: Int, gridCols: Int) {
        col = clampCol(c, gridCols: gridCols)
        pendingWrap = false
    }

    /// Set cursor row to an absolute value (VPA — CSI d).
    mutating func setRow(
        _ r: Int,
        gridRows: Int,
        originMode: Bool,
        scrollTop: Int,
        scrollBottom: Int
    ) {
        if originMode {
            // Absolute position within the scroll region
            let absRow = scrollTop + r
            row = max(scrollTop, min(absRow, scrollBottom))
        } else {
            // Absolute position within the grid
            row = clampRow(r, gridRows: gridRows)
        }
        pendingWrap = false
    }

    /// Advance cursor by one column after printing a character.
    /// If at the last column, enters pending wrap state instead of wrapping.
    mutating func advanceAfterPrint(gridCols: Int, autoWrap: Bool) {
        if col >= gridCols - 1 {
            if autoWrap {
                pendingWrap = true
            }
            // If no auto-wrap, cursor stays at last column
        } else {
            col += 1
        }
    }

    /// Handle a tab stop advance. Moves cursor to the next tab stop
    /// without exceeding the last column.
    mutating func advanceToTab(tabStops: Set<Int>, gridCols: Int) {
        let maxCol = gridCols - 1
        var nextCol = col + 1
        while nextCol < maxCol && !tabStops.contains(nextCol) {
            nextCol += 1
        }
        col = min(nextCol, maxCol)
        pendingWrap = false
    }

    /// Handle a reverse tab stop. Moves cursor to the previous tab stop.
    mutating func reverseToTab(tabStops: Set<Int>) {
        var prevCol = col - 1
        while prevCol > 0 && !tabStops.contains(prevCol) {
            prevCol -= 1
        }
        col = max(prevCol, 0)
        pendingWrap = false
    }

    // MARK: - Save / Restore (DECSC / DECRC)

    /// Save cursor state for DECSC (ESC 7 or CSI s).
    func save(
        attributes: CellAttributes,
        fgColor: TerminalColor,
        bgColor: TerminalColor,
        underlineColor: TerminalColor = .default,
        underlineStyle: UnderlineStyle = .none,
        originMode: Bool,
        autoWrapMode: Bool,
        activeCharset: Int,
        g0Charset: Charset,
        g1Charset: Charset
    ) -> SavedCursorState {
        SavedCursorState(
            row: row,
            col: col,
            attributes: attributes,
            fgColor: fgColor,
            bgColor: bgColor,
            underlineColor: underlineColor,
            underlineStyle: underlineStyle,
            originMode: originMode,
            autoWrapMode: autoWrapMode,
            activeCharset: activeCharset,
            g0Charset: g0Charset,
            g1Charset: g1Charset
        )
    }

    /// Restore cursor position from a saved state. Returns the saved state
    /// so the caller can also restore attributes, colors, and modes.
    mutating func restore(from saved: SavedCursorState, gridRows: Int, gridCols: Int) {
        row = clampRow(saved.row, gridRows: gridRows)
        col = clampCol(saved.col, gridCols: gridCols)
        pendingWrap = false
    }

    // MARK: - Clamping

    private func clampRow(_ r: Int, gridRows: Int) -> Int {
        max(0, min(r, gridRows - 1))
    }

    private func clampCol(_ c: Int, gridCols: Int) -> Int {
        max(0, min(c, gridCols - 1))
    }
}
