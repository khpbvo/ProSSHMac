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
        return TerminalSelectionTextExtractor.selectedText(from: snapshot, selection: selection)
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

enum TerminalSelectionTextExtractor {
    static func selectedText(from snapshot: GridSnapshot, selection: TerminalSelection) -> String? {
        let cols = snapshot.columns
        let rows = snapshot.rows
        guard cols > 0, rows > 0 else { return nil }

        let expanded = normalizedSelection(selection, in: snapshot)

        var result = ""
        for row in expanded.start.row...expanded.end.row {
            let left = (row == expanded.start.row) ? expanded.start.col : 0
            let right = (row == expanded.end.row) ? expanded.end.col : (cols - 1)

            var line = ""
            for col in left...right {
                let idx = row * cols + col
                guard idx >= 0 && idx < snapshot.cells.count else { continue }

                let cell = snapshot.cells[idx]
                let attributes = CellAttributes(rawValue: cell.attributes)
                if attributes.contains(.wideContinuation) {
                    continue
                }

                line.append(textForCell(at: idx, in: snapshot) ?? " ")
            }

            if let lastNonSpace = line.lastIndex(where: { $0 != " " }) {
                result += String(line[...lastNonSpace])
            }

            if row < expanded.end.row {
                result += "\n"
            }
        }

        return result.isEmpty ? nil : result
    }

    private static func normalizedSelection(
        _ selection: TerminalSelection,
        in snapshot: GridSnapshot
    ) -> TerminalSelection {
        var normalized = selection
        normalized.start = clampedSelectionPoint(normalized.start, in: snapshot)
        normalized.end = clampedSelectionPoint(normalized.end, in: snapshot)

        let startLinear = normalized.start.row * snapshot.columns + normalized.start.col
        let endLinear = normalized.end.row * snapshot.columns + normalized.end.col
        if startLinear > endLinear {
            swap(&normalized.start, &normalized.end)
        }

        switch normalized.type {
        case .character:
            return normalized
        case .line:
            normalized.start.col = 0
            normalized.end.col = snapshot.columns - 1
            return normalized
        case .word:
            normalized.start = expandWordBoundaryLeft(from: normalized.start, in: snapshot)
            normalized.end = expandWordBoundaryRight(from: normalized.end, in: snapshot)
            return normalized
        }
    }

    private static func clampedSelectionPoint(_ point: SelectionPoint, in snapshot: GridSnapshot) -> SelectionPoint {
        SelectionPoint(
            row: min(max(0, point.row), max(0, snapshot.rows - 1)),
            col: min(max(0, point.col), max(0, snapshot.columns - 1))
        )
    }

    private static func expandWordBoundaryLeft(from point: SelectionPoint, in snapshot: GridSnapshot) -> SelectionPoint {
        var col = point.col
        while col > 0 {
            let idx = point.row * snapshot.columns + (col - 1)
            guard idx >= 0 && idx < snapshot.cells.count else { break }
            guard isWordCell(snapshot.cells[idx], index: idx, in: snapshot) else { break }
            col -= 1
        }
        return SelectionPoint(row: point.row, col: col)
    }

    private static func expandWordBoundaryRight(from point: SelectionPoint, in snapshot: GridSnapshot) -> SelectionPoint {
        var col = point.col
        let maxCol = max(0, snapshot.columns - 1)
        while col < maxCol {
            let idx = point.row * snapshot.columns + (col + 1)
            guard idx >= 0 && idx < snapshot.cells.count else { break }
            guard isWordCell(snapshot.cells[idx], index: idx, in: snapshot) else { break }
            col += 1
        }
        return SelectionPoint(row: point.row, col: col)
    }

    private static func isWordCell(_ cell: CellInstance, index: Int, in snapshot: GridSnapshot) -> Bool {
        if let grapheme = snapshot.graphemeOverrides?[index], !grapheme.isEmpty {
            return true
        }
        if cell.glyphIndex != 0 {
            return true
        }
        let attributes = CellAttributes(rawValue: cell.attributes)
        return attributes.contains(.wideChar) || attributes.contains(.wideContinuation)
    }

    private static func textForCell(at index: Int, in snapshot: GridSnapshot) -> String? {
        if let grapheme = snapshot.graphemeOverrides?[index], !grapheme.isEmpty {
            return grapheme
        }

        let codepoint = snapshot.cells[index].glyphIndex
        guard codepoint != 0 else { return nil }
        guard let scalar = Unicode.Scalar(codepoint) else { return "\u{FFFD}" }
        return String(scalar)
    }
}
