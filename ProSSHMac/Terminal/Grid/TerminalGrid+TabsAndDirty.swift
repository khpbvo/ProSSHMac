// Extracted from TerminalGrid.swift

import Foundation

extension TerminalGrid {

    // MARK: - A.6.12 Tab Stop Management

    /// Advance cursor to the next tab stop (HT / CHT).
    nonisolated func tabForward(count: Int = 1) {
        for _ in 0..<max(count, 1) {
            cursor.advanceToTab(tabStops: tabStopMask, gridCols: columns)
        }
    }

    /// Move cursor to the previous tab stop (CBT — CSI Z).
    nonisolated func tabBackward(count: Int = 1) {
        for _ in 0..<max(count, 1) {
            cursor.reverseToTab(tabStops: tabStopMask)
        }
    }

    /// Set a tab stop at the current cursor column (HTS — ESC H).
    nonisolated func setTabStop() {
        guard cursor.col >= 0 && cursor.col < tabStopMask.count else { return }
        tabStopMask[cursor.col] = true
    }

    /// Clear tab stops (TBC — CSI g).
    /// - 0: Clear tab stop at current column
    /// - 3: Clear all tab stops
    nonisolated func clearTabStop(mode: Int) {
        switch mode {
        case 0:
            if cursor.col >= 0 && cursor.col < tabStopMask.count {
                tabStopMask[cursor.col] = false
            }
        case 3:
            tabStopMask = [Bool](repeating: false, count: columns)
        default:
            break
        }
    }

    /// Reset tab stops to default (every 8 columns).
    nonisolated func resetTabStops() {
        tabStopMask = TerminalDefaults.defaultTabStopMask(columns: columns)
    }

    // MARK: - A.6.13 Dirty Tracking

    /// Mark a specific row as dirty.
    nonisolated func markDirty(row: Int) {
        hasDirtyCells = true
        dirtyRowMin = min(dirtyRowMin, row)
        dirtyRowMax = max(dirtyRowMax, row)
    }

    /// Mark a contiguous row range as dirty.
    nonisolated func markDirty(rows range: ClosedRange<Int>) {
        guard !range.isEmpty else { return }
        hasDirtyCells = true
        dirtyRowMin = min(dirtyRowMin, range.lowerBound)
        dirtyRowMax = max(dirtyRowMax, range.upperBound)
    }

    /// Mark all rows as dirty (used after buffer switch, full reset, resize).
    nonisolated func markAllDirty() {
        hasDirtyCells = true
        dirtyRowMin = 0
        dirtyRowMax = rows - 1
    }

    /// Clear the dirty state after producing a snapshot.
    nonisolated func clearDirtyState() {
        hasDirtyCells = false
        dirtyRowMin = Int.max
        dirtyRowMax = -1
    }

}
