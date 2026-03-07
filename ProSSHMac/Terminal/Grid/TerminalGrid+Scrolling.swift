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
                // Partial scroll region: rotate row indirection in-region.
                let regionCount = scrollBottom - scrollTop + 1
                var regionKeys = [Int]()
                regionKeys.reserveCapacity(regionCount)
                for row in scrollTop...scrollBottom {
                    regionKeys.append(logicalRowIndex(row, base: base))
                }
                let regionPhysicalRows = regionKeys.map { rowMap[$0] }
                for i in 0..<regionCount {
                    rowMap[regionKeys[i]] = regionPhysicalRows[(i + lines) % regionCount]
                }
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
                // Partial scroll region: rotate row indirection in-region.
                let regionCount = scrollBottom - scrollTop + 1
                var regionKeys = [Int]()
                regionKeys.reserveCapacity(regionCount)
                for row in scrollTop...scrollBottom {
                    regionKeys.append(logicalRowIndex(row, base: base))
                }
                let regionPhysicalRows = regionKeys.map { rowMap[$0] }
                for i in 0..<regionCount {
                    rowMap[regionKeys[i]] = regionPhysicalRows[(i - lines + regionCount) % regionCount]
                }
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
