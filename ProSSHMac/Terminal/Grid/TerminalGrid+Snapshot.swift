// Extracted from TerminalGrid.swift

import Foundation
#if DEBUG
import os.signpost
#endif

extension TerminalGrid {

    // MARK: - A.6.14 Grid Snapshot Generation

    /// Produce an immutable snapshot of the current grid state for the renderer.
    /// Clears dirty tracking after snapshot is taken.
    ///
    /// When synchronized output (mode 2026) is active, returns the previously
    /// cached snapshot so the renderer keeps displaying the last complete frame
    /// while the remote app is mid-update.
    nonisolated func snapshot() -> GridSnapshot {
        // During synchronized output, return the cached snapshot to avoid
        // rendering partial frames. If no cached snapshot exists yet, fall
        // through and produce one normally.
        if synchronizedOutput, let cached = lastSnapshot {
            return cached
        }
        #if DEBUG
        let signpostID = OSSignpostID(log: Self.perfSignpostLog)
        os_signpost(
            .begin,
            log: Self.perfSignpostLog,
            name: "GridSnapshot",
            signpostID: signpostID
        )
        defer {
            os_signpost(
                .end,
                log: Self.perfSignpostLog,
                name: "GridSnapshot",
                signpostID: signpostID
            )
        }
        #endif

        let activeCells = usingAlternateBuffer ? alternateCells : primaryCells
        let rowBase = activeRowBase
        let hasDirtyRange = hasDirtyCells && dirtyRowMin <= dirtyRowMax
        let dirtyMin = dirtyRowMin
        let dirtyMax = dirtyRowMax
        let totalCells = rows * columns

        // Swap the active pre-allocated buffer out to get unique ownership.
        // With double buffering, the last snapshot sharing this buffer's
        // storage has been dropped by the renderer, so ref count is 1 and
        // indexed writes go directly into existing memory — zero allocation.
        var buffer = ContiguousArray<CellInstance>()
        if useSnapshotBufferA {
            swap(&buffer, &snapshotBufferA)
        } else {
            swap(&buffer, &snapshotBufferB)
        }

        // Resize only when grid dimensions change (not every frame).
        if buffer.count != totalCells {
            buffer = ContiguousArray(repeating: CellInstance(
                row: 0, col: 0, glyphIndex: 0, fgColor: 0, bgColor: 0,
                underlineColor: 0, attributes: 0, flags: 0, underlineStyle: 0
            ), count: totalCells)
        }

        // Fill by index — no append overhead (no bounds check + count increment per cell).
        var idx = 0
        for row in 0..<rows {
            let physicalRowIndex = physicalRow(row, base: rowBase)
            let rowIsDirty = hasDirtyRange && row >= dirtyMin && row <= dirtyMax
            for col in 0..<columns {
                let cell = activeCells[physicalRowIndex][col]
                let isCursor = (row == cursor.row && col == cursor.col && cursor.visible)

                var flags: UInt8 = 0
                if rowIsDirty { flags |= CellInstance.flagDirty }
                if isCursor { flags |= CellInstance.flagCursor }

                let codepoint = cell.primaryCodepoint

                // boldIsBright is pre-applied at write-time; use packed values directly.
                let fgPacked = cell.fgPackedRGBA
                let ulColorPacked = cell.underlinePackedRGBA

                buffer[idx] = CellInstance(
                    row: UInt16(row),
                    col: UInt16(col),
                    glyphIndex: codepoint,
                    fgColor: fgPacked,
                    bgColor: cell.bgPackedRGBA,
                    underlineColor: ulColorPacked,
                    attributes: cell.attributes.rawValue,
                    flags: flags,
                    underlineStyle: cell.underlineStyle.rawValue
                )
                idx += 1
            }
        }

        // Compute dirty range
        var dirtyRange: Range<Int>?
        if hasDirtyRange {
            let startIdx = dirtyMin * columns
            let endIdx = (dirtyMax + 1) * columns
            dirtyRange = startIdx..<endIdx
        }

        // Keep the filled buffer in the reuse slot. The returned snapshot and
        // slot intentionally share storage; later writes trigger COW when the
        // old snapshot is still retained by the renderer, preserving correctness
        // while recovering steady-state buffer reuse.
        let snap = GridSnapshot(
            cells: buffer,
            dirtyRange: dirtyRange,
            cursorRow: cursor.row,
            cursorCol: cursor.col,
            cursorVisible: cursor.visible,
            cursorStyle: cursor.style,
            columns: columns,
            rows: rows,
            usingAlternateBuffer: usingAlternateBuffer
        )
        if useSnapshotBufferA {
            snapshotBufferA = buffer
        } else {
            snapshotBufferB = buffer
        }

        useSnapshotBufferA.toggle()

        clearDirtyState()

        lastSnapshot = snap
        return snap
    }

    /// Produce a snapshot with scrollback lines blended in.
    /// `scrollOffset` is the number of lines scrolled back (0 = live view).
    /// When scrollOffset > 0, the top N rows show scrollback content and
    /// the remaining rows show the top portion of the visible grid.
    nonisolated func snapshot(scrollOffset: Int) -> GridSnapshot {
        guard scrollOffset > 0, scrollback.count > 0 else {
            return snapshot()
        }
        #if DEBUG
        let signpostID = OSSignpostID(log: Self.perfSignpostLog)
        os_signpost(
            .begin,
            log: Self.perfSignpostLog,
            name: "GridSnapshotScrollback",
            signpostID: signpostID,
            "offset=%d",
            scrollOffset
        )
        defer {
            os_signpost(
                .end,
                log: Self.perfSignpostLog,
                name: "GridSnapshotScrollback",
                signpostID: signpostID
            )
        }
        #endif

        let activeCells = usingAlternateBuffer ? alternateCells : primaryCells
        let rowBase = activeRowBase

        // Clamp offset to available scrollback
        let clampedOffset = min(scrollOffset, scrollback.count)
        let totalCells = rows * columns

        // Scrollback snapshots are less frequent (only during scroll-back viewing),
        // so we use a simple ContiguousArray without the double-buffer optimization.
        var cellInstances = ContiguousArray<CellInstance>()
        cellInstances.reserveCapacity(totalCells)

        for displayRow in 0..<rows {
            // Which logical row does this display row map to?
            // displayRow 0 is the topmost visible row.
            // scrollbackIndex = scrollback.count - clampedOffset + displayRow
            let scrollbackIndex = scrollback.count - clampedOffset + displayRow

            if scrollbackIndex < scrollback.count {
                // This row comes from scrollback
                let scrollLine = scrollback[scrollbackIndex]
                for col in 0..<columns {
                    let codepoint: UInt32
                    let fgPacked: UInt32
                    let bgPacked: UInt32
                    let attrs: UInt16

                    let ulColorPacked: UInt32
                    let ulStyle: UInt8

                    if col < scrollLine.cells.count {
                        let cell = scrollLine.cells[col]
                        codepoint = cell.primaryCodepoint
                        // boldIsBright was pre-applied at write-time
                        fgPacked = cell.fgPackedRGBA
                        bgPacked = cell.bgPackedRGBA
                        attrs = cell.attributes.rawValue
                        ulColorPacked = cell.underlinePackedRGBA
                        ulStyle = cell.underlineStyle.rawValue
                    } else {
                        codepoint = 0
                        fgPacked = 0
                        bgPacked = 0
                        attrs = 0
                        ulColorPacked = 0
                        ulStyle = 0
                    }

                    cellInstances.append(CellInstance(
                        row: UInt16(displayRow),
                        col: UInt16(col),
                        glyphIndex: codepoint,
                        fgColor: fgPacked,
                        bgColor: bgPacked,
                        underlineColor: ulColorPacked,
                        attributes: attrs,
                        flags: CellInstance.flagDirty,
                        underlineStyle: ulStyle
                    ))
                }
            } else {
                // This row comes from the live grid
                let gridRow = scrollbackIndex - scrollback.count
                let physicalRowIndex = physicalRow(gridRow, base: rowBase)
                for col in 0..<columns {
                    let cell = activeCells[physicalRowIndex][col]
                    let isCursor = (gridRow == cursor.row && col == cursor.col && cursor.visible && clampedOffset == 0)

                    var flags: UInt8 = CellInstance.flagDirty
                    if isCursor { flags |= CellInstance.flagCursor }

                    let codepoint = cell.primaryCodepoint

                    // boldIsBright was pre-applied at write-time
                    let fgPacked = cell.fgPackedRGBA

                    cellInstances.append(CellInstance(
                        row: UInt16(displayRow),
                        col: UInt16(col),
                        glyphIndex: codepoint,
                        fgColor: fgPacked,
                        bgColor: cell.bgPackedRGBA,
                        underlineColor: cell.underlinePackedRGBA,
                        attributes: cell.attributes.rawValue,
                        flags: flags,
                        underlineStyle: cell.underlineStyle.rawValue
                    ))
                }
            }
        }

        return GridSnapshot(
            cells: cellInstances,
            dirtyRange: 0..<cellInstances.count,
            cursorRow: cursor.row,
            cursorCol: cursor.col,
            cursorVisible: cursor.visible && clampedOffset == 0,
            cursorStyle: cursor.style,
            columns: columns,
            rows: rows,
            usingAlternateBuffer: usingAlternateBuffer
        )
    }

    /// The number of scrollback lines available.
    nonisolated var scrollbackCount: Int {
        scrollback.count
    }

    // MARK: - A.6.15 Text Extraction

    /// Extract visible rows as an array of strings (trailing whitespace trimmed).
    /// Used by the text-based fallback view, password detection, and search.
    nonisolated func visibleText() -> [String] {
        let activeCells = usingAlternateBuffer ? alternateCells : primaryCells
        let rowBase = activeRowBase

        var lines = [String]()
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            let physicalRowIndex = physicalRow(row, base: rowBase)
            var line = ""
            for col in 0..<columns {
                let cell = activeCells[physicalRowIndex][col]
                if cell.width == 0 { continue } // skip wide-char continuation
                let grapheme = resolveGrapheme(for: cell)
                if grapheme.isEmpty {
                    line.append(" ")
                } else {
                    line.append(grapheme)
                }
            }
            // Trim trailing spaces with a single pass.
            if let lastNonSpace = line.lastIndex(where: { $0 != " " }) {
                lines.append(String(line[...lastNonSpace]))
            } else {
                lines.append("")
            }
        }
        return lines
    }

}
