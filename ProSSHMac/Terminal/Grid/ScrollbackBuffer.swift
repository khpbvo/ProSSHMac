// ScrollbackBuffer.swift
// ProSSHV2
//
// Ring buffer for terminal scrollback history.
// Stores lines that have scrolled off the top of the visible terminal grid.

import Foundation

// MARK: - ScrollbackLine

/// A single line stored in the scrollback buffer.
/// Preserves the original cells and whether the line was auto-wrapped.
nonisolated struct ScrollbackLine: Sendable {
    /// The cells that make up this line.
    var cells: [TerminalCell]

    /// Whether this line was auto-wrapped (continued from the line above).
    var isWrapped: Bool

    /// Multi-codepoint grapheme overrides for cells that had side-table entries.
    /// Key is column index, value is the full grapheme cluster string.
    /// nil when no cells in this line had multi-codepoint graphemes.
    var graphemeOverrides: [Int: String]?

    /// Create a scrollback line from a row of cells.
    init(cells: [TerminalCell], isWrapped: Bool = false, graphemeOverrides: [Int: String]? = nil) {
        self.cells = cells
        self.isWrapped = isWrapped
        self.graphemeOverrides = graphemeOverrides
    }

    /// The number of cells in this line.
    var count: Int { cells.count }

    /// Get the grapheme cluster for a cell at the given column, checking overrides first.
    func grapheme(at col: Int) -> String {
        if let overrides = graphemeOverrides, let str = overrides[col] {
            return str
        }
        return cells[col].graphemeCluster
    }

    /// Trim trailing blank cells to save memory.
    mutating func trimTrailingBlanks() {
        guard !cells.isEmpty else { return }

        if let lastNonBlank = cells.lastIndex(where: { !$0.isBlank }) {
            let trimStart = cells.index(after: lastNonBlank)
            if trimStart < cells.endIndex {
                // Remove grapheme overrides for trimmed columns
                if graphemeOverrides != nil {
                    for col in trimStart..<cells.endIndex {
                        graphemeOverrides?.removeValue(forKey: col)
                    }
                    if graphemeOverrides?.isEmpty == true {
                        graphemeOverrides = nil
                    }
                }
                cells.removeSubrange(trimStart..<cells.endIndex)
            }
        } else {
            cells.removeAll(keepingCapacity: true)
            graphemeOverrides = nil
        }
    }
}

// MARK: - ScrollbackBuffer

/// A fixed-capacity ring buffer that stores scrollback history lines.
///
/// When the buffer reaches its maximum capacity, the oldest lines are
/// discarded as new lines are added. This provides O(1) push and O(1)
/// indexed access.
nonisolated struct ScrollbackBuffer: Sendable {

    /// The maximum number of lines this buffer can hold.
    let maxLines: Int

    /// Internal storage array (ring buffer).
    private var storage: [ScrollbackLine]

    /// Index of the oldest element in the ring buffer.
    private var head: Int = 0

    /// The current number of lines stored.
    private(set) var count: Int = 0

    // MARK: - Initialization

    /// Create a scrollback buffer with the given maximum line capacity.
    init(maxLines: Int = TerminalDefaults.maxScrollbackLines) {
        self.maxLines = max(maxLines, 0)
        self.storage = []
        self.storage.reserveCapacity(min(maxLines, 1024))
    }

    // MARK: - Adding Lines

    /// Push a new line onto the end of the scrollback buffer.
    /// If the buffer is full, the oldest line is discarded.
    mutating func push(_ line: ScrollbackLine) {
        guard maxLines > 0 else { return }

        if storage.count < maxLines {
            // Still filling up — just append
            storage.append(line)
            count = storage.count
        } else {
            // Buffer is full — overwrite the oldest entry
            storage[head] = line
            head = (head + 1) % maxLines
            // count stays at maxLines
        }
    }

    /// Push a row of cells as a new scrollback line.
    mutating func push(cells: [TerminalCell], isWrapped: Bool = false, graphemeOverrides: [Int: String]? = nil) {
        var line = ScrollbackLine(cells: cells, isWrapped: isWrapped, graphemeOverrides: graphemeOverrides)
        line.trimTrailingBlanks()
        push(line)
    }

    // MARK: - Accessing Lines

    /// Access a line by logical index (0 = oldest line in buffer).
    /// Returns nil if index is out of range.
    func line(at index: Int) -> ScrollbackLine? {
        guard index >= 0 && index < count else { return nil }
        let storageIndex = (head + index) % storage.count
        return storage[storageIndex]
    }

    /// Access a line by logical index (0 = oldest).
    subscript(index: Int) -> ScrollbackLine {
        precondition(index >= 0 && index < count && !storage.isEmpty,
                     "ScrollbackBuffer index \(index) out of range (count: \(count))")
        let storageIndex = (head + index) % storage.count
        return storage[storageIndex]
    }

    /// The most recently added line (bottom of scrollback, just above visible area).
    /// Returns nil if the buffer is empty.
    var last: ScrollbackLine? {
        guard count > 0 else { return nil }
        return line(at: count - 1)
    }

    /// The oldest line in the buffer (top of scrollback).
    /// Returns nil if the buffer is empty.
    var first: ScrollbackLine? {
        guard count > 0 else { return nil }
        return line(at: 0)
    }

    /// Whether the buffer is empty.
    var isEmpty: Bool { count == 0 }

    /// Whether the buffer is at full capacity.
    var isFull: Bool { count >= maxLines }

    // MARK: - Removing Lines

    /// Remove and return the most recently added line (pop from end).
    /// Used when scrolling down to restore a line back to the visible grid.
    mutating func popLast() -> ScrollbackLine? {
        guard count > 0 else { return nil }

        let lastIndex = (head + count - 1) % storage.count
        let line = storage[lastIndex]
        count -= 1

        // If we've emptied the buffer, reset state
        if count == 0 {
            head = 0
            storage.removeAll(keepingCapacity: true)
        }

        return line
    }

    /// Clear all lines from the buffer.
    mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        count = 0
    }

    // MARK: - Bulk Operations

    /// Return all lines as an array, ordered from oldest to newest.
    func allLines() -> [ScrollbackLine] {
        guard count > 0 else { return [] }
        var result = [ScrollbackLine]()
        result.reserveCapacity(count)
        for i in 0..<count {
            result.append(self[i])
        }
        return result
    }

    /// Return the last `n` lines (most recent), ordered oldest to newest.
    func lastLines(_ n: Int) -> [ScrollbackLine] {
        let take = min(max(n, 0), count)
        guard take > 0 else { return [] }
        var result = [ScrollbackLine]()
        result.reserveCapacity(take)
        let start = count - take
        for i in start..<count {
            result.append(self[i])
        }
        return result
    }

    /// Search scrollback for lines containing the given string.
    /// Returns logical indices of matching lines (0 = oldest).
    func search(_ query: String, caseSensitive: Bool = false) -> [Int] {
        var matches = [Int]()
        let searchText = caseSensitive ? query : query.lowercased()

        for i in 0..<count {
            let line = self[i]
            let lineText = (0..<line.count).map { line.grapheme(at: $0) }.joined()
            let compareText = caseSensitive ? lineText : lineText.lowercased()
            if compareText.contains(searchText) {
                matches.append(i)
            }
        }
        return matches
    }
}
