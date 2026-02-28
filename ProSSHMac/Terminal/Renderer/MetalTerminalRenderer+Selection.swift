// Extracted from MetalTerminalRenderer.swift
import AppKit

extension MetalTerminalRenderer {

    // MARK: - Selection

    /// Update selection range and immediately re-project selection flags if a snapshot exists.
    func setSelection(
        start: SelectionPoint,
        end: SelectionPoint,
        type: SelectionType
    ) {
        selectionRenderer.selection = TerminalSelection(start: start, end: end, type: type)
        if let latestSnapshot {
            updateSnapshot(latestSnapshot)
        }
    }

    /// Clear active selection and re-render.
    func clearSelection() {
        selectionRenderer.clearSelection()
        if let latestSnapshot {
            updateSnapshot(latestSnapshot)
        }
    }

    /// Select all visible cells.
    func selectAll() {
        guard let snapshot = latestSnapshot, snapshot.rows > 0, snapshot.columns > 0 else { return }
        setSelection(
            start: SelectionPoint(row: 0, col: 0),
            end: SelectionPoint(row: snapshot.rows - 1, col: snapshot.columns - 1),
            type: .character
        )
    }

    /// Whether there is an active selection.
    var hasSelection: Bool {
        selectionRenderer.selection != nil
    }

    /// Extract the selected text from the latest snapshot using original Unicode codepoints.
    func selectedText() -> String? {
        guard let selection = selectionRenderer.selection,
              let snapshot = latestSnapshot else { return nil }

        let cols = snapshot.columns
        let rows = snapshot.rows
        guard cols > 0, rows > 0 else { return nil }

        // Normalize start/end ordering
        let startLinear = selection.start.row * cols + selection.start.col
        let endLinear = selection.end.row * cols + selection.end.col
        let (selStart, selEnd) = startLinear <= endLinear
            ? (selection.start, selection.end)
            : (selection.end, selection.start)

        // Expand word/line boundaries
        var expanded = TerminalSelection(start: selStart, end: selEnd, type: selection.type)
        if selection.type == .line {
            expanded.start.col = 0
            expanded.end.col = cols - 1
        }

        var result = ""
        for row in expanded.start.row...expanded.end.row {
            let left = (row == expanded.start.row) ? expanded.start.col : 0
            let right = (row == expanded.end.row) ? expanded.end.col : (cols - 1)

            var lineChars: [Character] = []
            var skipNext = false
            for col in left...right {
                let idx = row * cols + col
                guard idx >= 0 && idx < snapshot.cells.count else { continue }

                if skipNext {
                    skipNext = false
                    continue
                }

                let cell = snapshot.cells[idx]
                let isWide = (cell.attributes & CellAttributes.wideChar.rawValue) != 0
                if isWide { skipNext = true }

                let codepoint = cell.glyphIndex
                if codepoint == 0 {
                    lineChars.append(" ")
                } else if let scalar = Unicode.Scalar(codepoint) {
                    lineChars.append(Character(scalar))
                }
            }

            // Trim trailing spaces for each line
            while lineChars.last == " " { lineChars.removeLast() }
            result += String(lineChars)

            if row < expanded.end.row {
                result += "\n"
            }
        }

        return result.isEmpty ? nil : result
    }

    /// Convert a point position (in the MTKView's coordinate space) to a grid cell.
    func gridCell(at point: CGPoint) -> SelectionPoint? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let col = Int(point.x / cellWidth)

        // macOS NSView coordinates have origin at bottom-left (y increases upward),
        // but the terminal grid has row 0 at the top. Flip the y-coordinate.
        let scale = max(screenScale, 1.0)
        let viewHeightPoints = viewportSize.height / scale
        let flippedY = max(0, viewHeightPoints - point.y)
        let row = Int(flippedY / cellHeight)

        return SelectionPoint(row: max(0, row), col: max(0, col))
    }
}
