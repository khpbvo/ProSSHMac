// GridReflow.swift
// ProSSHV2
//
// Content reflow on terminal resize.
// When the terminal width changes, wrapped lines must be unwrapped (if wider)
// or rewrapped (if narrower) to preserve content correctly.
// This is the hardest grid operation — most terminal emulators have bugs here.

import Foundation

// MARK: - GridReflow

/// Stateless reflow engine. All methods are static and operate on cell data.
nonisolated enum GridReflow {

    // MARK: - Logical Line

    /// A logical line is one or more physical rows that form a single
    /// continuous line of text. Physical rows joined by the `.wrapped`
    /// attribute belong to the same logical line.
    struct LogicalLine {
        /// The cells making up this logical line (may be longer than any single row).
        var cells: [TerminalCell]

        /// Whether this logical line was itself a continuation of a previous
        /// line that got pushed into scrollback (only relevant for scrollback lines).
        var startsWrapped: Bool = false
    }

    // MARK: - Public API

    /// Reflow a screen buffer and scrollback when the terminal width changes.
    ///
    /// - Parameters:
    ///   - screenRows: The current visible screen rows.
    ///   - scrollback: The scrollback buffer.
    ///   - cursorRow: Current cursor row (0-based).
    ///   - cursorCol: Current cursor column (0-based).
    ///   - oldColumns: Previous terminal width.
    ///   - newColumns: New terminal width.
    ///   - newRows: New terminal height (number of visible rows).
    /// - Returns: A `ReflowResult` containing the new screen buffer,
    ///   updated scrollback lines, and adjusted cursor position.
    static func reflow(
        screenRows: [[TerminalCell]],
        scrollback: ScrollbackBuffer,
        cursorRow: Int,
        cursorCol: Int,
        oldColumns: Int,
        newColumns: Int,
        newRows: Int
    ) -> ReflowResult {
        // If width hasn't changed, just adjust row count
        if oldColumns == newColumns {
            return adjustRowCount(
                screenRows: screenRows,
                scrollback: scrollback,
                cursorRow: cursorRow,
                cursorCol: cursorCol,
                newColumns: newColumns,
                newRows: newRows
            )
        }

        // Step 1: Combine scrollback + screen into logical lines
        let logicalLines = extractLogicalLines(
            scrollback: scrollback,
            screenRows: screenRows,
            columns: oldColumns
        )

        // Track which logical line and offset the cursor is on
        let cursorPosition = findCursorInLogicalLines(
            logicalLines: logicalLines,
            scrollbackCount: scrollback.count,
            screenRows: screenRows,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            oldColumns: oldColumns
        )

        // Step 2: Rewrap all logical lines to the new width
        var newPhysicalRows = [[TerminalCell]]()
        var cursorNewRow = 0
        var cursorNewCol = 0

        for (lineIdx, logicalLine) in logicalLines.enumerated() {
            let wrapped = wrapLogicalLine(logicalLine.cells, toWidth: newColumns)

            for (physIdx, physRow) in wrapped.enumerated() {
                // Track cursor
                if lineIdx == cursorPosition.logicalLineIndex {
                    let offsetInLine = cursorPosition.offsetInLine
                    let rowStart = physIdx * newColumns
                    let rowEnd = rowStart + physRow.count
                    let isLastRow = physIdx == wrapped.count - 1
                    if offsetInLine >= rowStart
                        && (offsetInLine < rowEnd || (isLastRow && offsetInLine == rowEnd)) {
                        cursorNewRow = newPhysicalRows.count
                        cursorNewCol = min(offsetInLine - rowStart, newColumns - 1)
                    }
                }

                newPhysicalRows.append(physRow)
            }
        }

        // Step 3: Split back into scrollback and screen
        let totalRows = newPhysicalRows.count
        let screenStart = max(0, totalRows - newRows)

        // Adjust cursor row relative to the screen start
        cursorNewRow = cursorNewRow - screenStart

        // Build new scrollback lines
        var newScrollbackLines = [ScrollbackLine]()
        for i in 0..<screenStart {
            let isWrapped = i > 0 && isRowWrapped(newPhysicalRows[i - 1])
            newScrollbackLines.append(ScrollbackLine(
                cells: newPhysicalRows[i],
                isWrapped: isWrapped
            ))
        }

        // Build new screen buffer
        var newScreen = [[TerminalCell]]()
        newScreen.reserveCapacity(newRows)
        for i in screenStart..<totalRows {
            newScreen.append(newPhysicalRows[i])
        }

        // Pad with blank rows if we don't have enough
        let blankRow = [TerminalCell](repeating: .blank, count: newColumns)
        while newScreen.count < newRows {
            newScreen.append(blankRow)
        }

        // Clamp cursor
        cursorNewRow = max(0, min(cursorNewRow, newRows - 1))
        cursorNewCol = max(0, min(cursorNewCol, newColumns - 1))

        return ReflowResult(
            screenRows: newScreen,
            scrollbackLines: newScrollbackLines,
            cursorRow: cursorNewRow,
            cursorCol: cursorNewCol
        )
    }

    // MARK: - Result Type

    /// The result of a reflow operation.
    struct ReflowResult {
        /// The new visible screen rows.
        let screenRows: [[TerminalCell]]

        /// New scrollback lines to replace the existing scrollback.
        let scrollbackLines: [ScrollbackLine]

        /// Adjusted cursor row (0-based, relative to screen).
        let cursorRow: Int

        /// Adjusted cursor column (0-based).
        let cursorCol: Int
    }

    // MARK: - Internal: Extract Logical Lines

    /// Combine scrollback + screen rows into logical lines by joining
    /// consecutive physical rows linked by the `.wrapped` attribute.
    private static func extractLogicalLines(
        scrollback: ScrollbackBuffer,
        screenRows: [[TerminalCell]],
        columns: Int
    ) -> [LogicalLine] {
        var allRows = [(cells: [TerminalCell], isWrapped: Bool)]()

        // Add scrollback rows
        for i in 0..<scrollback.count {
            let line = scrollback[i]
            allRows.append((cells: line.cells, isWrapped: line.isWrapped))
        }

        // Add screen rows, checking the previous row for the wrapped attribute
        for (i, row) in screenRows.enumerated() {
            let isWrapped: Bool
            if i == 0 {
                // First screen row: check if the last scrollback row was wrapped
                if let lastScrollback = allRows.last {
                    isWrapped = lastScrollback.cells.last.map {
                        $0.attributes.contains(.wrapped)
                    } ?? false
                } else {
                    isWrapped = false
                }
            } else {
                isWrapped = screenRows[i - 1].last.map {
                    $0.attributes.contains(.wrapped)
                } ?? false
            }
            allRows.append((cells: row, isWrapped: isWrapped))
        }

        // Now group into logical lines
        var logicalLines = [LogicalLine]()
        var currentCells = [TerminalCell]()
        var startsWrapped = false

        for (idx, physRow) in allRows.enumerated() {
            let rowCells = padOrTrim(physRow.cells, toWidth: columns)

            if idx > 0 && physRow.isWrapped {
                // This row is a continuation of the previous line
                currentCells.append(contentsOf: rowCells)
            } else {
                // Start a new logical line
                if idx > 0 || !currentCells.isEmpty {
                    // Flush previous logical line
                    if !currentCells.isEmpty {
                        logicalLines.append(LogicalLine(
                            cells: trimTrailingBlanks(currentCells),
                            startsWrapped: startsWrapped
                        ))
                    }
                }
                currentCells = Array(rowCells)
                startsWrapped = physRow.isWrapped
            }

            // If this row's last cell has the wrapped flag, the NEXT row continues
            // (handled by checking isWrapped on the next iteration)
        }

        // Flush the last logical line
        if !currentCells.isEmpty {
            logicalLines.append(LogicalLine(
                cells: trimTrailingBlanks(currentCells),
                startsWrapped: startsWrapped
            ))
        }

        // Ensure at least one empty logical line
        if logicalLines.isEmpty {
            logicalLines.append(LogicalLine(cells: []))
        }

        return logicalLines
    }

    // MARK: - Internal: Wrap Logical Line

    /// Break a logical line into physical rows of the given width.
    /// Returns at least one row (may be blank).
    private static func wrapLogicalLine(
        _ cells: [TerminalCell],
        toWidth width: Int
    ) -> [[TerminalCell]] {
        guard width > 0 else { return [[]] }

        if cells.isEmpty {
            return [[TerminalCell](repeating: .blank, count: width)]
        }

        var rows = [[TerminalCell]]()
        var offset = 0

        while offset < cells.count {
            let end = min(offset + width, cells.count)
            var row = Array(cells[offset..<end])

            // Pad to full width
            if row.count < width {
                row.append(contentsOf:
                    [TerminalCell](repeating: .blank, count: width - row.count)
                )
            }

            // Mark as wrapped if there's more content after this row
            if end < cells.count {
                row[width - 1].attributes.insert(.wrapped)
            }

            // Mark all cells dirty
            for i in 0..<row.count {
                row[i].isDirty = true
            }

            rows.append(row)
            offset = end
        }

        if rows.isEmpty {
            rows.append([TerminalCell](repeating: .blank, count: width))
        }

        return rows
    }

    // MARK: - Internal: Cursor Tracking

    /// Position of the cursor within the logical line array.
    private struct CursorLogicalPosition {
        let logicalLineIndex: Int
        let offsetInLine: Int
    }

    /// Find which logical line the cursor is on, and its offset within that line.
    private static func findCursorInLogicalLines(
        logicalLines: [LogicalLine],
        scrollbackCount: Int,
        screenRows: [[TerminalCell]],
        cursorRow: Int,
        cursorCol: Int,
        oldColumns: Int
    ) -> CursorLogicalPosition {
        // The cursor is on screen row `cursorRow`. We need to figure out
        // which logical line that corresponds to.
        // Physical row index in the combined array = scrollbackCount + cursorRow
        let physicalRowIndex = scrollbackCount + cursorRow

        // Walk through logical lines to find which one contains this physical row
        var physRowCounter = 0
        for (lineIdx, logLine) in logicalLines.enumerated() {
            let linePhysRows = max(1, (logLine.cells.count + oldColumns - 1) / max(oldColumns, 1))

            if physRowCounter + linePhysRows > physicalRowIndex {
                // The cursor is in this logical line
                let rowWithinLine = physicalRowIndex - physRowCounter
                let offsetInLine = rowWithinLine * oldColumns + cursorCol
                return CursorLogicalPosition(
                    logicalLineIndex: lineIdx,
                    offsetInLine: min(offsetInLine, logLine.cells.count)
                )
            }

            physRowCounter += linePhysRows
        }

        // Fallback: cursor at the end
        let lastIdx = max(0, logicalLines.count - 1)
        return CursorLogicalPosition(
            logicalLineIndex: lastIdx,
            offsetInLine: cursorCol
        )
    }

    // MARK: - Internal: Row Count Adjustment (Width Unchanged)

    /// When only the row count changes (width stays the same),
    /// move lines between scrollback and screen as needed.
    private static func adjustRowCount(
        screenRows: [[TerminalCell]],
        scrollback: ScrollbackBuffer,
        cursorRow: Int,
        cursorCol: Int,
        newColumns: Int,
        newRows: Int
    ) -> ReflowResult {
        let oldRows = screenRows.count

        if newRows >= oldRows {
            // Screen got taller — pull lines back from scrollback
            var newScreen = [[TerminalCell]]()
            let rowsToRestore = min(newRows - oldRows, scrollback.count)

            // Pull from scrollback
            var restoredFromScrollback = [ScrollbackLine]()
            var tempScrollback = scrollback
            for _ in 0..<rowsToRestore {
                if let line = tempScrollback.popLast() {
                    restoredFromScrollback.insert(line, at: 0)
                }
            }

            // Build screen: restored lines + existing screen + padding
            for line in restoredFromScrollback {
                newScreen.append(padOrTrim(line.cells, toWidth: newColumns))
            }
            for row in screenRows {
                newScreen.append(row)
            }
            let blankRow = [TerminalCell](repeating: .blank, count: newColumns)
            while newScreen.count < newRows {
                newScreen.append(blankRow)
            }

            // Remaining scrollback
            var remainingScrollback = [ScrollbackLine]()
            for i in 0..<tempScrollback.count {
                remainingScrollback.append(tempScrollback[i])
            }

            return ReflowResult(
                screenRows: newScreen,
                scrollbackLines: remainingScrollback,
                cursorRow: min(cursorRow + rowsToRestore, newRows - 1),
                cursorCol: cursorCol
            )
        } else {
            // Screen got shorter — push excess top lines to scrollback
            let rowsToRemove = oldRows - newRows

            var newScrollbackLines = [ScrollbackLine]()
            for i in 0..<scrollback.count {
                newScrollbackLines.append(scrollback[i])
            }

            for i in 0..<rowsToRemove {
                let isWrapped = screenRows[i].last.map {
                    $0.attributes.contains(.wrapped)
                } ?? false
                newScrollbackLines.append(ScrollbackLine(
                    cells: screenRows[i],
                    isWrapped: isWrapped
                ))
            }

            var newScreen = [[TerminalCell]]()
            for i in rowsToRemove..<oldRows {
                newScreen.append(screenRows[i])
            }

            return ReflowResult(
                screenRows: newScreen,
                scrollbackLines: newScrollbackLines,
                cursorRow: max(0, cursorRow - rowsToRemove),
                cursorCol: cursorCol
            )
        }
    }

    // MARK: - Helpers

    /// Pad or trim a row of cells to exactly the given width.
    private static func padOrTrim(_ cells: [TerminalCell], toWidth width: Int) -> [TerminalCell] {
        if cells.count == width {
            return cells
        } else if cells.count > width {
            return Array(cells.prefix(width))
        } else {
            var padded = cells
            padded.append(contentsOf:
                [TerminalCell](repeating: .blank, count: width - cells.count)
            )
            return padded
        }
    }

    /// Trim trailing blank cells from a cell array.
    private static func trimTrailingBlanks(_ cells: [TerminalCell]) -> [TerminalCell] {
        var trimmed = cells
        while let last = trimmed.last, last.isBlank {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Check if a physical row ends with the wrapped flag.
    private static func isRowWrapped(_ row: [TerminalCell]) -> Bool {
        row.last.map { $0.attributes.contains(.wrapped) } ?? false
    }
}
