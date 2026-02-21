// SelectionRenderer.swift
// ProSSHV2
//
// Selection model and selection flag projection for terminal rendering.

import Foundation
import simd
import AppKit

/// A concrete cell position in the grid.
struct SelectionPoint: Sendable, Equatable {
    var row: Int
    var col: Int
}

/// Selection expansion mode.
enum SelectionType: Sendable {
    case character
    case word
    case line
}

/// A terminal selection range.
struct TerminalSelection: Sendable {
    var start: SelectionPoint
    var end: SelectionPoint
    var type: SelectionType
}

/// Computes selected cells and exposes shader-ready selection color.
final class SelectionRenderer {

    /// Active selection in grid coordinates.
    var selection: TerminalSelection? {
        didSet { needsFullRefresh = true }
    }

    /// Selection overlay alpha (0...1).
    var selectionAlpha: Float = 0.30

    /// RGB selection tint plus alpha placeholder.
    private(set) var selectionColor: SIMD4<Float> = SIMD4<Float>(0.30, 0.50, 0.90, 1.0)

    private var needsFullRefresh = false
    private var previousSelectionLinearRange: ClosedRange<Int>?

    init() {
        refreshSelectionColorFromSystemAccent()
    }

    /// Pulls the current system accent color for selection rendering.
    func refreshSelectionColorFromSystemAccent() {
        let nsColor = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
        selectionColor = SIMD4<Float>(
            Float(nsColor.redComponent),
            Float(nsColor.greenComponent),
            Float(nsColor.blueComponent),
            Float(nsColor.alphaComponent)
        )
    }

    func clearSelection() {
        selection = nil
    }

    /// Applies selection flags to snapshot cells.
    ///
    /// When selection changes, this forces a full update to ensure stale
    /// selected bits are cleared correctly across the entire grid.
    func applySelection(to snapshot: GridSnapshot) -> GridSnapshot {
        guard var selection else {
            defer {
                needsFullRefresh = false
                previousSelectionLinearRange = nil
            }

            // Normal snapshots come directly from TerminalGrid and do not carry
            // renderer selection bits. If there was a prior selection, clear only
            // the previously selected range as a conservative fallback.
            guard let previousRange = previousSelectionLinearRange,
                  !snapshot.cells.isEmpty else {
                return snapshot
            }

            let lower = max(0, previousRange.lowerBound)
            let upper = min(snapshot.cells.count - 1, previousRange.upperBound)
            guard lower <= upper else { return snapshot }

            var cleared = snapshot.cells
            for i in lower...upper {
                cleared[i].flags &= ~CellInstance.flagSelected
            }
            return GridSnapshot(
                cells: cleared,
                dirtyRange: lower..<(upper + 1),
                cursorRow: snapshot.cursorRow,
                cursorCol: snapshot.cursorCol,
                cursorVisible: snapshot.cursorVisible,
                cursorStyle: snapshot.cursorStyle,
                columns: snapshot.columns,
                rows: snapshot.rows
            )
        }

        guard snapshot.columns > 0, snapshot.rows > 0, !snapshot.cells.isEmpty else {
            return snapshot
        }

        selection = normalizedSelection(selection, columns: snapshot.columns, rows: snapshot.rows)
        selection = expandedSelection(selection, in: snapshot)

        let start = orderedMin(selection.start, selection.end, columns: snapshot.columns)
        let end = orderedMax(selection.start, selection.end, columns: snapshot.columns)
        let startLinear = start.row * snapshot.columns + start.col
        let endLinear = end.row * snapshot.columns + end.col

        var cells = snapshot.cells

        if needsFullRefresh, let previousRange = previousSelectionLinearRange {
            let lower = max(0, previousRange.lowerBound)
            let upper = min(cells.count - 1, previousRange.upperBound)
            if lower <= upper {
                for i in lower...upper {
                    cells[i].flags &= ~CellInstance.flagSelected
                }
            }
        }

        for row in start.row...end.row {
            let left = (row == start.row) ? start.col : 0
            let right = (row == end.row) ? end.col : (snapshot.columns - 1)
            guard left <= right else { continue }
            let rowBase = row * snapshot.columns
            for col in left...right {
                let idx = rowBase + col
                guard idx >= 0 && idx < cells.count else { continue }
                cells[idx].flags |= CellInstance.flagSelected
            }
        }

        needsFullRefresh = false
        let dirtyStart = min(startLinear, previousSelectionLinearRange?.lowerBound ?? startLinear)
        let dirtyEnd = max(endLinear, previousSelectionLinearRange?.upperBound ?? endLinear)
        previousSelectionLinearRange = startLinear...endLinear
        return GridSnapshot(
            cells: cells,
            dirtyRange: dirtyStart..<(dirtyEnd + 1),
            cursorRow: snapshot.cursorRow,
            cursorCol: snapshot.cursorCol,
            cursorVisible: snapshot.cursorVisible,
            cursorStyle: snapshot.cursorStyle,
            columns: snapshot.columns,
            rows: snapshot.rows
        )
    }

    private func normalizedSelection(
        _ selection: TerminalSelection,
        columns: Int,
        rows: Int
    ) -> TerminalSelection {
        var s = selection
        s.start.row = Swift.min(Swift.max(0, s.start.row), Swift.max(0, rows - 1))
        s.start.col = Swift.min(Swift.max(0, s.start.col), Swift.max(0, columns - 1))
        s.end.row = Swift.min(Swift.max(0, s.end.row), Swift.max(0, rows - 1))
        s.end.col = Swift.min(Swift.max(0, s.end.col), Swift.max(0, columns - 1))
        return s
    }

    private func expandedSelection(_ selection: TerminalSelection, in snapshot: GridSnapshot) -> TerminalSelection {
        switch selection.type {
        case .character:
            return selection
        case .line:
            var s = selection
            s.start.col = 0
            s.end.col = Swift.max(0, snapshot.columns - 1)
            return s
        case .word:
            var s = selection
            s.start = expandWordBoundaryLeft(from: s.start, in: snapshot)
            s.end = expandWordBoundaryRight(from: s.end, in: snapshot)
            return s
        }
    }

    private func expandWordBoundaryLeft(from point: SelectionPoint, in snapshot: GridSnapshot) -> SelectionPoint {
        var col = point.col
        while col > 0 {
            let idx = point.row * snapshot.columns + (col - 1)
            guard idx >= 0 && idx < snapshot.cells.count else { break }
            guard isWordCell(snapshot.cells[idx]) else { break }
            col -= 1
        }
        return SelectionPoint(row: point.row, col: col)
    }

    private func expandWordBoundaryRight(from point: SelectionPoint, in snapshot: GridSnapshot) -> SelectionPoint {
        var col = point.col
        let maxCol = Swift.max(0, snapshot.columns - 1)
        while col < maxCol {
            let idx = point.row * snapshot.columns + (col + 1)
            guard idx >= 0 && idx < snapshot.cells.count else { break }
            guard isWordCell(snapshot.cells[idx]) else { break }
            col += 1
        }
        return SelectionPoint(row: point.row, col: col)
    }

    private func isWordCell(_ cell: CellInstance) -> Bool {
        // Best-effort heuristic for renderer-level snapshots.
        // Non-zero glyph indices imply visible glyphs and are considered word cells.
        if cell.glyphIndex != 0 { return true }
        let attrs = CellAttributes(rawValue: cell.attributes)
        return attrs.contains(.wideChar)
    }

    private func orderedMin(_ lhs: SelectionPoint, _ rhs: SelectionPoint, columns: Int) -> SelectionPoint {
        let l = lhs.row * columns + lhs.col
        let r = rhs.row * columns + rhs.col
        return l <= r ? lhs : rhs
    }

    private func orderedMax(_ lhs: SelectionPoint, _ rhs: SelectionPoint, columns: Int) -> SelectionPoint {
        let l = lhs.row * columns + lhs.col
        let r = rhs.row * columns + rhs.col
        return l >= r ? lhs : rhs
    }
}
