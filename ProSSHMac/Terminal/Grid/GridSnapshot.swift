// GridSnapshot.swift
// ProSSHV2
//
// Immutable snapshot of the terminal grid for the renderer.
// Crosses the actor boundary as a Sendable value type —
// no shared mutable state between grid actor and renderer.

import Foundation

// MARK: - CellInstance (GPU-ready)

/// GPU-ready representation of a single terminal cell.
/// Mirrors the Metal `CellInstance` struct layout for direct buffer upload.
nonisolated struct CellInstance: Sendable {
    /// Grid position: (row, col) as packed UInt16 pair.
    var row: UInt16
    var col: UInt16

    /// Initially holds the Unicode codepoint (set by grid snapshot).
    /// The renderer replaces this with the packed atlas position after glyph lookup.
    var glyphIndex: UInt32

    /// Foreground color as packed RGBA UInt32.
    var fgColor: UInt32

    /// Background color as packed RGBA UInt32.
    var bgColor: UInt32

    /// Underline color as packed RGBA UInt32. 0 = use fgColor.
    var underlineColor: UInt32

    /// Cell attributes bitfield (matches CellAttributes.rawValue).
    var attributes: UInt16

    /// Flags bitfield: bit 0 = dirty, bit 1 = cursor, bit 2 = selected.
    var flags: UInt8

    /// Underline style (0=none, 1=single, 2=double, 3=curly, 4=dotted, 5=dashed).
    var underlineStyle: UInt8

    // MARK: - Flag Constants

    static let flagDirty: UInt8    = 1 << 0
    static let flagCursor: UInt8   = 1 << 1
    static let flagSelected: UInt8 = 1 << 2
}

// MARK: - GridSnapshot

/// Immutable snapshot of the terminal grid state, ready for rendering.
/// Produced by the TerminalGrid actor, consumed by the Metal renderer on @MainActor.
nonisolated struct GridSnapshot: Sendable {
    /// Flattened cell data ready for GPU upload. Row-major order.
    /// Uses ContiguousArray for cache-friendly iteration and zero NSArray bridging.
    let cells: ContiguousArray<CellInstance>

    /// If non-nil, only this range of cells changed since the last snapshot.
    /// The renderer can do a partial MTLBuffer update for efficiency.
    let dirtyRange: Range<Int>?

    /// Current cursor row.
    let cursorRow: Int

    /// Current cursor column.
    let cursorCol: Int

    /// Whether the cursor should be visible.
    let cursorVisible: Bool

    /// Cursor display style.
    let cursorStyle: CursorStyle

    /// Grid column count.
    let columns: Int

    /// Grid row count.
    let rows: Int
}
