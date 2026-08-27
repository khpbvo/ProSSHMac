// Extracted from TerminalGrid.swift

import Foundation

extension TerminalGrid {

    // MARK: - A.6.4 Scroll Up/Down

    /// Scroll content up within the scroll region by `n` lines.
    /// Top lines go to scrollback (primary buffer only). Bottom lines become blank.
    nonisolated func scrollUp(lines n: Int) {
        let count = max(n, 1)
        let regionHeight = scrollBottom - scrollTop + 1
        guard regionHeight > 0 else { return }
        let lines = min(count, regionHeight)

        withActiveBufferState { buf, base, rowMap in
            // Save top lines to scrollback (primary buffer only), preserving order.
            if !usingAlternateBuffer {
                for i in 0..<lines {
                    let topPhysical = physicalRow(scrollTop + i, base: base, map: rowMap)
                    var topRow = buf[topPhysical]
                    let graphemeOverrides = resolveSideTableEntries(in: &topRow)
                    let isWrapped = topRow.last.map { $0.attributes.contains(.wrapped) } ?? false
                    scrollback.push(cells: topRow, isWrapped: isWrapped, graphemeOverrides: graphemeOverrides)
                }
            }

            if scrollTop == 0 && scrollBottom == rows - 1 {
                // Full-screen scroll: rotate logical row base by N in O(1).
                base += lines
                if base >= rows { base %= rows }
            } else {
                rotatePartialRowMap(
                    &rowMap,
                    base: base,
                    regionStart: scrollTop,
                    regionCount: regionHeight,
                    leftBy: lines
                )
            }

            // Clear newly exposed bottom lines.
            for row in (scrollBottom - lines + 1)...scrollBottom {
                let physical = physicalRow(row, base: base, map: rowMap)
                buf[physical] = makeBlankRow()
            }
        }

        if lines > 0 {
            markDirty(rows: scrollTop...scrollBottom)
        }
    }

    /// Scroll content down within the scroll region by `n` lines.
    /// Bottom lines are discarded. Top lines become blank.
    nonisolated func scrollDown(lines n: Int) {
        let count = max(n, 1)
        let regionHeight = scrollBottom - scrollTop + 1
        guard regionHeight > 0 else { return }
        let lines = min(count, regionHeight)

        withActiveBufferState { buf, base, rowMap in
            if scrollTop == 0 && scrollBottom == rows - 1 {
                // Full-screen reverse scroll: rotate base by N in O(1).
                base -= lines
                while base < 0 { base += rows }
            } else {
                rotatePartialRowMap(
                    &rowMap,
                    base: base,
                    regionStart: scrollTop,
                    regionCount: regionHeight,
                    leftBy: regionHeight - lines
                )
            }

            // Clear newly exposed top lines.
            for row in scrollTop..<(scrollTop + lines) {
                let physical = physicalRow(row, base: base, map: rowMap)
                buf[physical] = makeBlankRow()
            }
        }

        if lines > 0 {
            markDirty(rows: scrollTop...scrollBottom)
        }
    }

    /// Rotate physical-row mappings within a partial scroll region without allocating.
    /// `leftBy` follows the same direction as an upward terminal scroll.
    @inline(__always)
    nonisolated func rotatePartialRowMap(
        _ rowMap: inout [Int],
        base: Int,
        regionStart: Int,
        regionCount: Int,
        leftBy requestedShift: Int
    ) {
        guard regionCount > 1 else { return }
        let shift = requestedShift % regionCount
        guard shift > 0 else { return }

        @inline(__always)
        func key(at offset: Int) -> Int {
            logicalRowIndex(regionStart + offset, base: base)
        }

        // The overwhelmingly common cases are one-line scroll up/down. Keep them
        // as tight shifts so flood output does not enter generic rotation logic.
        if shift == 1 {
            let firstValue = rowMap[key(at: 0)]
            var offset = 0
            while offset < regionCount - 1 {
                rowMap[key(at: offset)] = rowMap[key(at: offset + 1)]
                offset += 1
            }
            rowMap[key(at: regionCount - 1)] = firstValue
            return
        }

        if shift == regionCount - 1 {
            let lastValue = rowMap[key(at: regionCount - 1)]
            var offset = regionCount - 1
            while offset > 0 {
                rowMap[key(at: offset)] = rowMap[key(at: offset - 1)]
                offset -= 1
            }
            rowMap[key(at: 0)] = lastValue
            return
        }

        var a = regionCount
        var b = shift
        while b != 0 {
            (a, b) = (b, a % b)
        }

        for cycleStart in 0..<a {
            let savedValue = rowMap[key(at: cycleStart)]
            var current = cycleStart
            while true {
                let next = (current + shift) % regionCount
                if next == cycleStart { break }
                rowMap[key(at: current)] = rowMap[key(at: next)]
                current = next
            }
            rowMap[key(at: current)] = savedValue
        }
    }

    /// Index (IND / ESC D): move cursor down, scroll if at bottom of scroll region.
    nonisolated func index() {
        if cursor.row == scrollBottom {
            scrollUp(lines: 1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    /// Reverse Index (RI / ESC M): move cursor up, scroll down if at top of scroll region.
    nonisolated func reverseIndex() {
        if cursor.row == scrollTop {
            scrollDown(lines: 1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
    }

    /// Line feed: move cursor down, scroll if at bottom. Optionally CR (LNM mode).
    nonisolated func lineFeed() {
        if lineFeedMode {
            cursor.col = 0
            cursor.pendingWrap = false
        }
        index()
    }

    /// Carriage return: move cursor to column 0.
    nonisolated func carriageReturn() {
        cursor.col = 0
        cursor.pendingWrap = false
    }

    /// Backspace: move cursor left by 1, does not erase.
    nonisolated func backspace() {
        if cursor.col > 0 {
            cursor.col -= 1
            cursor.pendingWrap = false
        }
    }

    // MARK: - A.6.9 Scroll Region (DECSTBM — CSI r)

    /// Set the scroll region (top and bottom margins).
    /// Parameters are 1-based; converted to 0-based internally.
    /// Resets cursor to home position (respecting origin mode).
    nonisolated func setScrollRegion(top: Int, bottom: Int) {
        let t = max(top, 0)
        let b = min(bottom, rows - 1)

        guard t < b else { return }

        scrollTop = t
        scrollBottom = b

        // DECSTBM resets cursor to home
        if originMode {
            cursor.moveTo(row: scrollTop, col: 0, gridRows: rows, gridCols: columns)
        } else {
            cursor.moveTo(row: 0, col: 0, gridRows: rows, gridCols: columns)
        }
    }

    /// Reset scroll region to full screen.
    nonisolated func resetScrollRegion() {
        scrollTop = 0
        scrollBottom = rows - 1
    }

}
