// Extracted from TerminalGrid.swift

import Foundation

extension TerminalGrid {

    // MARK: - A.6.10 Alternate Screen Buffer (Mode 1049)

    /// Switch to the alternate screen buffer.
    /// Saves cursor, clears the alternate buffer.
    nonisolated func enableAlternateBuffer() {
        guard !usingAlternateBuffer else { return }

        // Save cursor for primary screen
        cursor.savedPrimary = cursor.save(
            attributes: currentAttributes,
            fgColor: currentFgColor,
            bgColor: currentBgColor,
            underlineColor: currentUnderlineColor,
            underlineStyle: currentUnderlineStyle,
            originMode: originMode,
            autoWrapMode: autoWrapMode,
            activeCharset: activeCharset,
            g0Charset: g0Charset,
            g1Charset: g1Charset
        )

        usingAlternateBuffer = true

        // Clear the alternate buffer
        let blankRow = makeBlankRow()
        alternateCells = [[TerminalCell]](repeating: blankRow, count: rows)
        alternateRowBase = 0
        alternateRowMap = Array(0..<rows)

        // Reset cursor position
        cursor.moveTo(row: 0, col: 0, gridRows: rows, gridCols: columns)

        markAllDirty()
    }

    /// Switch back to the primary screen buffer.
    /// Restores cursor from saved state.
    nonisolated func disableAlternateBuffer() {
        guard usingAlternateBuffer else { return }

        usingAlternateBuffer = false

        // The TUI app that enabled synchronized output is leaving the
        // alternate buffer — disable sync mode so snapshot() returns
        // live primary-buffer content instead of a stale cached frame.
        synchronizedOutput = false
        lastSnapshot = nil

        // Restore cursor from saved primary state
        if let saved = cursor.savedPrimary {
            cursor.restore(from: saved, gridRows: rows, gridCols: columns)
            originMode = saved.originMode
            autoWrapMode = saved.autoWrapMode
            activeCharset = saved.activeCharset
            g0Charset = saved.g0Charset
            g1Charset = saved.g1Charset
        }

        // Always reset SGR attributes to defaults when leaving alternate buffer.
        // TUI programs may exit without resetting colors (especially on Ctrl+C),
        // leaving dark fg colors that render invisible on dark backgrounds.
        // The shell will re-apply its own prompt colors immediately after.
        currentAttributes = []
        currentFgColor = .default
        currentBgColor = .default
        currentUnderlineColor = .default
        currentUnderlineStyle = .none
        invalidatePackedColors()

        markAllDirty()
    }

    // MARK: - A.6.11 Cursor Save/Restore (DECSC/DECRC)

    /// Save cursor and attributes (DECSC — ESC 7).
    nonisolated func saveCursor() {
        let saved = cursor.save(
            attributes: currentAttributes,
            fgColor: currentFgColor,
            bgColor: currentBgColor,
            underlineColor: currentUnderlineColor,
            underlineStyle: currentUnderlineStyle,
            originMode: originMode,
            autoWrapMode: autoWrapMode,
            activeCharset: activeCharset,
            g0Charset: g0Charset,
            g1Charset: g1Charset
        )
        if usingAlternateBuffer {
            cursor.savedAlternate = saved
        } else {
            cursor.savedPrimary = saved
        }
    }

    /// Restore cursor and attributes (DECRC — ESC 8).
    nonisolated func restoreCursor() {
        let saved = usingAlternateBuffer ? cursor.savedAlternate : cursor.savedPrimary
        guard let s = saved else { return }

        cursor.restore(from: s, gridRows: rows, gridCols: columns)
        currentAttributes = s.attributes
        currentFgColor = s.fgColor
        currentBgColor = s.bgColor
        currentUnderlineColor = s.underlineColor
        currentUnderlineStyle = s.underlineStyle
        originMode = s.originMode
        autoWrapMode = s.autoWrapMode
        activeCharset = s.activeCharset
        g0Charset = s.g0Charset
        g1Charset = s.g1Charset
        invalidatePackedColors()
    }

}
