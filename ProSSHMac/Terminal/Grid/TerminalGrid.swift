// swiftlint:disable file_length
// TerminalGrid.swift
// ProSSHV2
//
// The terminal grid. Owns the cell buffer, cursor, scroll region,
// mode flags, and all operations the VT parser drives.
// Produces GridSnapshot values for the renderer.
// Thread safety: owned exclusively by the TerminalEngine actor.

import Foundation
#if DEBUG
import os.signpost
#endif

// MARK: - TerminalGrid

nonisolated final class TerminalGrid: @unchecked Sendable {
    #if DEBUG
    static let perfSignpostLog = OSLog(subsystem: "com.prossh", category: "TerminalPerf")
    #endif

    /// Reuse one-character ASCII strings to avoid per-character allocations
    /// in the common shell-output fast path.
    static let asciiScalarStringCache: [String] = (0..<128).map {
        String(UnicodeScalar($0)!)
    }

    /// Reuse ASCII Characters for parser fast-path bulk printing.
    static let asciiCharacterCache: [Character] = (0..<128).map {
        Character(UnicodeScalar($0)!)
    }

    // MARK: - Dimensions

    var columns: Int
    var rows: Int

    // MARK: - Screen Buffers

    /// Primary screen buffer (normal shell output).
    var primaryCells: [[TerminalCell]]
    /// Ring-buffer base offset for primaryCells (logical row 0 -> physical row base).
    var primaryRowBase: Int = 0
    /// Logical-to-physical row indirection for primary buffer.
    var primaryRowMap: [Int]

    /// Alternate screen buffer (for full-screen TUI apps: htop, vim, etc.).
    var alternateCells: [[TerminalCell]]
    /// Ring-buffer base offset for alternateCells.
    var alternateRowBase: Int = 0
    /// Logical-to-physical row indirection for alternate buffer.
    var alternateRowMap: [Int]

    /// Which buffer is currently active.
    var usingAlternateBuffer: Bool = false

    // MARK: - Scrollback

    var scrollback: ScrollbackBuffer

    // MARK: - Grapheme Side Table

    /// Storage for multi-codepoint grapheme clusters. Cells store a sentinel
    /// codepoint referencing this table; entries are resolved when scrolling
    /// to scrollback or extracting text.
    var graphemeSideTable = GraphemeSideTable()

    /// Maximum scrollback lines.
    let maxScrollbackLines: Int

    // MARK: - Cursor

    var cursor: CursorState = CursorState()

    /// The last printed character (for REP — repeat preceding character).
    var lastPrintedChar: Character?

    // MARK: - Scroll Region

    /// Top margin of the scroll region (0-based, inclusive).
    var scrollTop: Int = 0

    /// Bottom margin of the scroll region (0-based, inclusive).
    var scrollBottom: Int

    // MARK: - Mode Flags

    var originMode: Bool = false              // DECOM
    var autoWrapMode: Bool = true             // DECAWM
    var insertMode: Bool = false              // IRM
    var applicationCursorKeys: Bool = false   // DECCKM
    var applicationKeypad: Bool = false       // DECKPAM/DECKPNM
    var bracketedPasteMode: Bool = false      // Mode 2004
    var synchronizedOutput: Bool = false // Mode 2026
    /// Snapshots captured at the moment synchronized output is re-enabled.
    /// Used by SessionManager to publish every visible frame when one parser
    /// batch contains multiple sync-off -> draw -> sync-on windows.
    var syncExitSnapshots: [GridSnapshot] = []
    var reverseVideo: Bool = false            // DECSCNM
    var mouseTracking: MouseTrackingMode = .none
    var mouseEncoding: MouseEncoding = .x10
    var focusReporting: Bool = false
    var lineFeedMode: Bool = false            // LNM — LF acts as CR+LF

    // MARK: - Character Set State

    var activeCharset: Int = 0   // 0 = G0, 1 = G1
    var g0Charset: Charset = .ascii
    var g1Charset: Charset = .ascii

    // MARK: - Tab Stops

    /// Internal tab-stop mask indexed by column (true = tab stop).
    var tabStopMask: [Bool]

    /// Tab stops as column indices (used by tests and diagnostics).
    var tabStops: Set<Int> {
        var result = Set<Int>()
        for (col, hasStop) in tabStopMask.enumerated() where hasStop {
            result.insert(col)
        }
        return result
    }

    // MARK: - Window Title

    /// The window/tab title set by OSC 0/1/2.
    var windowTitle: String = ""

    /// The icon name set by OSC 1.
    var iconName: String = ""

    // MARK: - Bell

    /// Accumulated bell events since the last snapshot read.
    /// The renderer reads and resets this counter each frame.
    var pendingBellCount: Int = 0

    // MARK: - Working Directory (OSC 7)

    /// The current working directory reported by the shell via OSC 7.
    var workingDirectory: String = ""

    // MARK: - Hyperlink State (OSC 8)

    /// The currently active hyperlink URI (nil = no hyperlink).
    /// When set, all subsequently printed characters are part of this hyperlink.
    /// Stub: stored but not yet rendered differently or made clickable.
    var currentHyperlink: String?

    /// Increment the pending bell counter (called on BEL 0x07).
    func ringBell() {
        pendingBellCount += 1
    }

    /// Read and reset the pending bell counter.
    func consumeBellCount() -> Int {
        let count = pendingBellCount
        pendingBellCount = 0
        return count
    }

    // MARK: - Color Palette (256 custom colors, overridable by OSC 4)

    /// Custom color palette overrides. Key = palette index, value = (r, g, b).
    /// If an index is not in this dictionary, the default from ColorPalette is used.
    var customPalette: [UInt8: (UInt8, UInt8, UInt8)] = [:]

    /// The cursor color set by OSC 12 (nil = use default).
    var cursorColor: (UInt8, UInt8, UInt8)?

    /// Current default foreground RGB (OSC 10 override).
    var defaultForegroundColor: (UInt8, UInt8, UInt8) = (255, 255, 255)

    /// Current default background RGB (OSC 11 override).
    var defaultBackgroundColor: (UInt8, UInt8, UInt8) = (0, 0, 0)

    // MARK: - Current Text Attributes (applied to next printed character)

    var currentAttributes: CellAttributes = []
    var currentFgColor: TerminalColor = .default
    var currentBgColor: TerminalColor = .default
    var currentUnderlineColor: TerminalColor = .default
    var currentUnderlineStyle: UnderlineStyle = .none

    // MARK: - Cached Packed Colors (for hot-path TerminalCell construction)

    /// Pre-computed packed RGBA for currentFgColor, updated on color mutation.
    var currentFgPacked: UInt32 = 0
    /// Pre-computed packed RGBA for currentBgColor, updated on color mutation.
    var currentBgPacked: UInt32 = 0
    /// Pre-computed packed RGBA for currentUnderlineColor, updated on color mutation.
    var currentUnderlinePacked: UInt32 = 0

    /// Recompute cached packed RGBA values from the current colors.
    /// Must be called after any mutation of currentFgColor/currentBgColor/currentUnderlineColor.
    @inline(__always)
    func invalidatePackedColors() {
        currentFgPacked = currentFgColor.packedRGBA()
        currentBgPacked = currentBgColor.packedRGBA()
        currentUnderlinePacked = currentUnderlineColor.packedRGBA()
    }

    // MARK: - Dirty Tracking

    /// Range of rows that have been modified since last snapshot.
    var dirtyRowMin: Int = Int.max
    var dirtyRowMax: Int = -1

    /// Whether any cell has changed since the last snapshot.
    var hasDirtyCells: Bool = false

    /// Cached snapshot returned during synchronized output (mode 2026).
    var lastSnapshot: GridSnapshot?

    // MARK: - Pre-allocated Snapshot Buffers

    /// Double-buffered CellInstance storage for snapshot generation.
    /// Alternating between two buffers ensures the active buffer is uniquely
    /// owned (ref count 1) by the time we write to it, avoiding copy-on-write.
    /// At 120fps with 10,000 cells (24 bytes each), this eliminates ~28.8 MB/s
    /// of allocation churn in steady state.
    var snapshotBufferA = ContiguousArray<CellInstance>()
    var snapshotBufferB = ContiguousArray<CellInstance>()
    var useSnapshotBufferA = true

    // MARK: - Initialization

    init(columns: Int = TerminalDefaults.columns,
         rows: Int = TerminalDefaults.rows,
         maxScrollbackLines: Int = TerminalDefaults.maxScrollbackLines) {
        self.columns = columns
        self.rows = rows
        self.maxScrollbackLines = maxScrollbackLines
        self.scrollBottom = rows - 1
        self.tabStopMask = TerminalDefaults.defaultTabStopMask(columns: columns)
        self.scrollback = ScrollbackBuffer(maxLines: maxScrollbackLines)

        let blankRow = [TerminalCell](repeating: .blank, count: columns)
        self.primaryCells = [[TerminalCell]](repeating: blankRow, count: rows)
        self.alternateCells = [[TerminalCell]](repeating: blankRow, count: rows)
        self.primaryRowMap = Array(0..<rows)
        self.alternateRowMap = Array(0..<rows)
    }

    // MARK: - Active Buffer Access

    /// The currently active cell buffer.
    var cells: [[TerminalCell]] {
        get { usingAlternateBuffer ? alternateCells : primaryCells }
        set {
            if usingAlternateBuffer {
                alternateCells = newValue
            } else {
                primaryCells = newValue
            }
        }
    }

    /// Active buffer ring base (logical row 0 -> physical row index).
    var activeRowBase: Int {
        get { usingAlternateBuffer ? alternateRowBase : primaryRowBase }
        set {
            if usingAlternateBuffer {
                alternateRowBase = newValue
            } else {
                primaryRowBase = newValue
            }
        }
    }

    /// Mutate the active buffer and its ring base together.
    func withActiveBuffer(_ body: (inout [[TerminalCell]], inout Int) -> Void) {
        if usingAlternateBuffer {
            body(&alternateCells, &alternateRowBase)
        } else {
            body(&primaryCells, &primaryRowBase)
        }
    }

    /// Mutate the active buffer, ring base, and logical row map together.
    func withActiveBufferState(_ body: (inout [[TerminalCell]], inout Int, inout [Int]) -> Void) {
        if usingAlternateBuffer {
            body(&alternateCells, &alternateRowBase, &alternateRowMap)
        } else {
            body(&primaryCells, &primaryRowBase, &primaryRowMap)
        }
    }

    /// Active buffer logical-to-physical row map.
    var activeRowMap: [Int] {
        get { usingAlternateBuffer ? alternateRowMap : primaryRowMap }
        set {
            if usingAlternateBuffer {
                alternateRowMap = newValue
            } else {
                primaryRowMap = newValue
            }
        }
    }

    /// Translate a logical row index into the backing physical row index.
    @inline(__always)
    func physicalRow(_ logicalRow: Int, base: Int) -> Int {
        let map = activeRowMap
        return physicalRow(logicalRow, base: base, map: map)
    }

    @inline(__always)
    func logicalRowIndex(_ logicalRow: Int, base: Int) -> Int {
        guard rows > 0 else { return 0 }
        let idx = logicalRow + base
        return idx >= rows ? idx - rows : idx
    }

    /// Translate a logical row index into the backing physical row index for an explicit row map.
    @inline(__always)
    func physicalRow(_ logicalRow: Int, base: Int, map: [Int]) -> Int {
        map[logicalRowIndex(logicalRow, base: base)]
    }

    /// Return a logically ordered copy of a ring-backed screen buffer.
    func linearizedRows(_ buffer: [[TerminalCell]], base: Int, map: [Int]) -> [[TerminalCell]] {
        guard rows > 0 else { return buffer }
        let isIdentityMap = map.count == rows && map.enumerated().allSatisfy { index, value in
            index == value
        }
        if base == 0 && isIdentityMap {
            return buffer
        }
        var ordered = [[TerminalCell]]()
        ordered.reserveCapacity(rows)
        for logicalRow in 0..<rows {
            ordered.append(buffer[physicalRow(logicalRow, base: base, map: map)])
        }
        return ordered
    }

    // MARK: - Grapheme Encoding/Decoding

    /// Encode a grapheme cluster string into a codepoint.
    /// Single-scalar strings store the scalar directly; multi-scalar strings
    /// allocate in the side table and return a sentinel codepoint.
    @inline(__always)
    func encodeGrapheme(_ string: String) -> UInt32 {
        var scalars = string.unicodeScalars.makeIterator()
        guard let first = scalars.next() else { return 0 }
        if scalars.next() == nil {
            return first.value  // Single scalar — store directly
        }
        return graphemeSideTable.allocate(string)
    }

    /// Resolve a cell's codepoint to its full grapheme cluster string.
    /// For single-scalar cells, reconstructs from the codepoint.
    /// For side-table entries, looks up the stored string.
    func resolveGrapheme(for cell: TerminalCell) -> String {
        let cp = cell.codepoint
        if cp == 0 { return "" }
        if GraphemeSideTable.isSideTable(cp) {
            return graphemeSideTable.resolve(cp) ?? "\u{FFFD}"
        }
        if let scalar = UnicodeScalar(cp) {
            return String(scalar)
        }
        return "\u{FFFD}"
    }

    /// Release a cell's side-table entry if it has one.
    /// Fast no-op for the 99%+ of cells that are not side-table references.
    @inline(__always)
    func releaseCellGrapheme(_ codepoint: UInt32) {
        guard codepoint & GraphemeSideTable.sentinel != 0 else { return }
        graphemeSideTable.release(codepoint)
    }

    /// Resolve side-table entries in a row, mutating codepoints to first-scalar values.
    /// Returns grapheme overrides dictionary for multi-codepoint entries.
    /// Used before pushing rows to scrollback.
    func resolveSideTableEntries(in row: inout [TerminalCell]) -> [Int: String]? {
        guard graphemeSideTable.activeCount > 0 else { return nil }
        var overrides: [Int: String]? = nil
        for col in 0..<row.count {
            let cp = row[col].codepoint
            if GraphemeSideTable.isSideTable(cp) {
                if let str = graphemeSideTable.resolve(cp) {
                    if overrides == nil { overrides = [:] }
                    overrides![col] = str
                    row[col].codepoint = TerminalCell.extractPrimaryCodepoint(from: str)
                } else {
                    row[col].codepoint = 0
                }
                graphemeSideTable.release(cp)
            }
        }
        return overrides
    }

    /// Resolve all side-table entries in both buffers, replacing sentinel
    /// codepoints with their first scalar value. Used before resize/reflow
    /// to ensure no stale side-table indices survive.
    func resolveAllSideTableEntries() {
        guard graphemeSideTable.activeCount > 0 else { return }
        for physical in 0..<primaryCells.count {
            for col in 0..<primaryCells[physical].count {
                let cp = primaryCells[physical][col].codepoint
                if GraphemeSideTable.isSideTable(cp) {
                    if let str = graphemeSideTable.resolve(cp) {
                        primaryCells[physical][col].codepoint = TerminalCell.extractPrimaryCodepoint(from: str)
                    } else {
                        primaryCells[physical][col].codepoint = 0
                    }
                }
            }
        }
        for physical in 0..<alternateCells.count {
            for col in 0..<alternateCells[physical].count {
                let cp = alternateCells[physical][col].codepoint
                if GraphemeSideTable.isSideTable(cp) {
                    if let str = graphemeSideTable.resolve(cp) {
                        alternateCells[physical][col].codepoint = TerminalCell.extractPrimaryCodepoint(from: str)
                    } else {
                        alternateCells[physical][col].codepoint = 0
                    }
                }
            }
        }
        graphemeSideTable.clear()
    }

    // MARK: - Scrollback Access

    /// The current scrollback buffer (read-only).
    var scrollbackBuffer: ScrollbackBuffer {
        scrollback
    }

    // MARK: - Helpers

    /// Create a blank row with the current background color.
    func makeBlankRow() -> [TerminalCell] {
        let cell = TerminalCell.erased(bgColor: currentBgColor, bgPacked: currentBgPacked)
        return [TerminalCell](repeating: cell, count: columns)
    }
}

// MARK: - Character Width Detection

nonisolated extension Character {
    /// Returns true if this character is a wide (double-width) character,
    /// such as CJK ideographs, fullwidth forms, or emoji with default emoji presentation.
    /// Delegates to `CharacterWidth.isWide(_:)` for the actual classification.
    var isWideCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return CharacterWidth.isWide(scalar)
    }
}
