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
    /// Snapshot captured at the moment synchronized output ended.
    /// Used by SessionManager to show the intermediate visible frame
    /// when sync-off and sync-on happen within a single data chunk.
    var syncExitSnapshot: GridSnapshot?
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

    // MARK: - A.6.3 Print Character

    /// Print a character at the cursor position with current attributes.
    /// Handles auto-wrap, insert mode, and wide characters.
    func printCharacter(_ char: Character) {
        // If pending wrap, perform the actual wrap now
        if cursor.pendingWrap {
            performWrap()
        }

        let charStr: String
        if let scalar = char.unicodeScalars.first,
           char.unicodeScalars.count == 1,
           scalar.value < 128 {
            charStr = Self.asciiScalarStringCache[Int(scalar.value)]
        } else {
            charStr = String(char)
        }
        let isWide = char.isWideCharacter

        // Wide character at the last column: wrap first so the character
        // starts at column 0 of the next row (matching xterm/VTE behavior).
        // Without this, the primary cell is written at columns-1 but the
        // continuation cell at columns would be out of bounds.
        if isWide && cursor.col >= columns - 1 {
            if autoWrapMode {
                performWrap()
            }
        }

        let row = cursor.row
        let col = cursor.col

        // In insert mode, shift existing chars right
        if insertMode {
            let shiftCount = isWide ? 2 : 1
            insertBlanks(count: shiftCount, atRow: row, col: col)
        }

        let attributes = isWide ? currentAttributes.union(.wideChar) : currentAttributes

        // Pre-apply boldIsBright at write-time
        let fgPacked: UInt32
        if TerminalDefaults.boldIsBright && attributes.contains(.bold) {
            fgPacked = currentFgColor.packedRGBA(bold: true, boldIsBright: true)
        } else {
            fgPacked = currentFgPacked
        }

        let cp = encodeGrapheme(charStr)

        // Write the cell(s) in place.
        withActiveBuffer { buffer, base in
            let physical = physicalRow(row, base: base)
            releaseCellGrapheme(buffer[physical][col].codepoint)
            buffer[physical][col] = TerminalCell(
                codepoint: cp,
                fgPacked: fgPacked,
                bgPacked: currentBgPacked,
                ulPacked: currentUnderlinePacked,
                attributes: attributes,
                underlineStyle: currentUnderlineStyle,
                width: isWide ? 2 : 1
            )

            // For wide characters, write a continuation cell.
            if isWide && col + 1 < columns {
                releaseCellGrapheme(buffer[physical][col + 1].codepoint)
                buffer[physical][col + 1] = TerminalCell(
                    codepoint: 0,
                    fgPacked: fgPacked,
                    bgPacked: currentBgPacked,
                    ulPacked: currentUnderlinePacked,
                    attributes: currentAttributes,
                    underlineStyle: currentUnderlineStyle,
                    width: 0  // continuation
                )
            }
        }
        markDirty(row: row)

        lastPrintedChar = char

        // Advance cursor
        if isWide {
            if cursor.col + 1 < columns - 1 {
                cursor.col += 2
            } else {
                // Wide char at end — cursor goes to last col, pending wrap
                cursor.col = columns - 1
                if autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        } else {
            cursor.advanceAfterPrint(gridCols: columns, autoWrap: autoWrapMode)
        }
    }

    /// Repeat the last printed character `n` times (REP — CSI b).
    func repeatLastCharacter(_ n: Int) {
        guard let ch = lastPrintedChar else { return }
        for _ in 0..<max(n, 1) {
            printCharacter(ch)
        }
    }

    /// Print a run of printable ASCII bytes using a bulk fast path.
    /// Calls `withActiveCells` once for the entire run, skips wide-character
    /// checks (ASCII is never wide), and calls `markDirty` once per affected
    /// row range. This avoids per-character overhead in high-throughput output.
    /// Accepts Data + range to avoid per-chunk byte array materialization from VTParser.
    func printASCIIBytesBulk(_ bytes: Data, range: Range<Int>) {
        guard !range.isEmpty else { return }

        // Insert mode is rare; fall back to the per-character path for all
        // bytes so that insertBlanks() is called for each character.
        if insertMode {
            let charset: Charset = (activeCharset == 1) ? g1Charset : g0Charset
            let needsCharsetMapping = charset != .ascii
            for i in range {
                let byte = bytes[i]
                guard byte >= 0x20 && byte <= 0x7E else { continue }
                let ch: Character
                if needsCharsetMapping {
                    switch charset {
                    case .ascii:
                        ch = Self.asciiCharacterCache[Int(byte)]
                    case .ukNational:
                        ch = (byte == 0x23) ? "£" : Self.asciiCharacterCache[Int(byte)]
                    case .decSpecialGraphics:
                        if (0x60...0x7E).contains(byte),
                           let mapped = DECSpecialGraphics.mapCharacter(byte) {
                            ch = mapped
                        } else {
                            ch = Self.asciiCharacterCache[Int(byte)]
                        }
                    }
                } else {
                    ch = Self.asciiCharacterCache[Int(byte)]
                }
                printCharacter(ch)
            }
            return
        }

        let charset: Charset = (activeCharset == 1) ? g1Charset : g0Charset
        let needsCharsetMapping = charset != .ascii

        // Capture cached packed colors once for the entire run.
        // Pre-apply boldIsBright at write-time so snapshot() needs no per-cell check.
        let attrs = currentAttributes
        let fgPacked: UInt32
        if TerminalDefaults.boldIsBright && attrs.contains(.bold) {
            fgPacked = currentFgColor.packedRGBA(bold: true, boldIsBright: true)
        } else {
            fgPacked = currentFgPacked
        }
        let bgPacked = currentBgPacked
        let ulPacked = currentUnderlinePacked
        let ulStyle = currentUnderlineStyle

        withActiveBufferState { buf, base, rowMap in
            var dirtyRowLo = Int.max
            var dirtyRowHi = -1

            for i in range {
                let byte = bytes[i]
                guard byte >= 0x20 && byte <= 0x7E else { continue }

                // Handle pending wrap
                if cursor.pendingWrap {
                    // Mark the current line as wrapped
                    let lastCol = columns - 1
                    let wrappedPhysical = physicalRow(cursor.row, base: base, map: rowMap)
                    var lastCell = buf[wrappedPhysical][lastCol]
                    lastCell.attributes.insert(.wrapped)
                    lastCell.isDirty = true
                    buf[wrappedPhysical][lastCol] = lastCell

                    dirtyRowLo = min(dirtyRowLo, cursor.row)
                    dirtyRowHi = max(dirtyRowHi, cursor.row)

                    cursor.col = 0
                    cursor.pendingWrap = false

                    if cursor.row == scrollBottom {
                        // Inline scrollUp(lines: 1), using O(1) ring rotation
                        // for the common full-screen scroll region.
                        if !usingAlternateBuffer {
                            let topPhysical = physicalRow(scrollTop, base: base, map: rowMap)
                            var topRow = buf[topPhysical]
                            let graphemeOverrides = resolveSideTableEntries(in: &topRow)
                            let isWrapped = topRow.last.map { $0.attributes.contains(.wrapped) } ?? false
                            scrollback.push(cells: topRow, isWrapped: isWrapped, graphemeOverrides: graphemeOverrides)
                        }

                        if scrollTop == 0 && scrollBottom == rows - 1 {
                            base += 1
                            if base == rows { base = 0 }
                        } else {
                            let regionCount = scrollBottom - scrollTop + 1
                            var regionKeys = [Int]()
                            regionKeys.reserveCapacity(regionCount)
                            for row in scrollTop...scrollBottom {
                                regionKeys.append(logicalRowIndex(row, base: base))
                            }
                            let regionPhysicalRows = regionKeys.map { rowMap[$0] }
                            for i in 0..<regionCount {
                                rowMap[regionKeys[i]] = regionPhysicalRows[(i + 1) % regionCount]
                            }
                        }

                        let bottomPhysical = physicalRow(scrollBottom, base: base, map: rowMap)
                        buf[bottomPhysical] = makeBlankRow()
                        dirtyRowLo = min(dirtyRowLo, scrollTop)
                        dirtyRowHi = max(dirtyRowHi, scrollBottom)
                    } else if cursor.row < rows - 1 {
                        cursor.row += 1
                    }
                }

                // Resolve character string and codepoint — ASCII is never wide
                let charStr: String
                let codepoint: UInt32
                if needsCharsetMapping {
                    switch charset {
                    case .ascii:
                        charStr = Self.asciiScalarStringCache[Int(byte)]
                        codepoint = UInt32(byte)
                    case .ukNational:
                        if byte == 0x23 {
                            charStr = "£"
                            codepoint = 0xA3 // £ Unicode scalar
                        } else {
                            charStr = Self.asciiScalarStringCache[Int(byte)]
                            codepoint = UInt32(byte)
                        }
                    case .decSpecialGraphics:
                        if (0x60...0x7E).contains(byte),
                           let mapped = DECSpecialGraphics.mapCharacter(byte) {
                            charStr = String(mapped)
                            codepoint = mapped.unicodeScalars.first?.value ?? UInt32(byte)
                        } else {
                            charStr = Self.asciiScalarStringCache[Int(byte)]
                            codepoint = UInt32(byte)
                        }
                    }
                } else {
                    charStr = Self.asciiScalarStringCache[Int(byte)]
                    codepoint = UInt32(byte)
                }

                let row = cursor.row
                let col = cursor.col
                let physical = physicalRow(row, base: base, map: rowMap)

                buf[physical][col] = TerminalCell(
                    codepoint: codepoint,
                    fgPacked: fgPacked,
                    bgPacked: bgPacked,
                    ulPacked: ulPacked,
                    attributes: attrs,
                    underlineStyle: ulStyle,
                    width: 1
                )

                dirtyRowLo = min(dirtyRowLo, row)
                dirtyRowHi = max(dirtyRowHi, row)

                lastPrintedChar = needsCharsetMapping
                    ? charStr.first ?? Self.asciiCharacterCache[Int(byte)]
                    : Self.asciiCharacterCache[Int(byte)]

                // Advance cursor (ASCII is always width 1)
                if cursor.col >= columns - 1 {
                    if autoWrapMode {
                        cursor.pendingWrap = true
                    }
                } else {
                    cursor.col += 1
                }
            }

            // Batch mark dirty for all affected rows
            if dirtyRowLo <= dirtyRowHi {
                for r in dirtyRowLo...dirtyRowHi {
                    markDirty(row: r)
                }
            }
        }
    }

    /// Process plain ground-state text bytes in bulk.
    /// Supports printable ASCII plus CR/LF controls.
    /// Accepts Data + range to avoid extra copies from VTParser.
    func processGroundTextBytes(_ bytes: Data, range: Range<Int>) {
        guard !range.isEmpty else { return }

        var runStart: Int = -1

        for idx in range {
            let byte = bytes[idx]
            if byte >= 0x20 && byte <= 0x7E {
                if runStart < 0 {
                    runStart = idx
                }
                continue
            }

            // Flush printable run
            if runStart >= 0 {
                printASCIIBytesBulk(bytes, range: runStart..<idx)
                runStart = -1
            }

            switch byte {
            case 0x0A: // LF
                lineFeed()
            case 0x0D: // CR
                carriageReturn()
            default:
                break
            }
        }

        // Flush trailing printable run
        if runStart >= 0 {
            printASCIIBytesBulk(bytes, range: runStart..<range.upperBound)
        }
    }

    /// Perform the actual line wrap: CR + LF, scrolling if needed.
    func performWrap() {
        // Mark the current line as wrapped
        if cursor.col < columns {
            let row = cursor.row
            let lastCol = columns - 1
            withActiveBuffer { buffer, base in
                let physical = physicalRow(row, base: base)
                var lastCell = buffer[physical][lastCol]
                lastCell.attributes.insert(.wrapped)
                lastCell.isDirty = true
                buffer[physical][lastCol] = lastCell
            }
        }

        cursor.col = 0
        cursor.pendingWrap = false

        if cursor.row == scrollBottom {
            scrollUp(lines: 1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    // MARK: - A.6.10 Alternate Screen Buffer (Mode 1049)

    /// Switch to the alternate screen buffer.
    /// Saves cursor, clears the alternate buffer.
    func enableAlternateBuffer() {
        guard !usingAlternateBuffer else { return }

        // Save cursor for primary screen
        cursor.savedPrimary = cursor.save(
            attributes: currentAttributes,
            fgColor: currentFgColor,
            bgColor: currentBgColor,
            underlineColor: currentUnderlineColor,
            underlineStyle: currentUnderlineStyle,
            originMode: originMode,
            autoWrapMode: autoWrapMode,
            activeCharset: activeCharset,
            g0Charset: g0Charset,
            g1Charset: g1Charset
        )

        usingAlternateBuffer = true

        // Clear the alternate buffer
        let blankRow = makeBlankRow()
        alternateCells = [[TerminalCell]](repeating: blankRow, count: rows)
        alternateRowBase = 0
        alternateRowMap = Array(0..<rows)

        // Reset cursor position
        cursor.moveTo(row: 0, col: 0, gridRows: rows, gridCols: columns)

        markAllDirty()
    }

    /// Switch back to the primary screen buffer.
    /// Restores cursor from saved state.
    func disableAlternateBuffer() {
        guard usingAlternateBuffer else { return }

        usingAlternateBuffer = false

        // The TUI app that enabled synchronized output is leaving the
        // alternate buffer — disable sync mode so snapshot() returns
        // live primary-buffer content instead of a stale cached frame.
        synchronizedOutput = false
        lastSnapshot = nil

        // Restore cursor from saved primary state
        if let saved = cursor.savedPrimary {
            cursor.restore(from: saved, gridRows: rows, gridCols: columns)
            originMode = saved.originMode
            autoWrapMode = saved.autoWrapMode
            activeCharset = saved.activeCharset
            g0Charset = saved.g0Charset
            g1Charset = saved.g1Charset
        }

        // Always reset SGR attributes to defaults when leaving alternate buffer.
        // TUI programs may exit without resetting colors (especially on Ctrl+C),
        // leaving dark fg colors that render invisible on dark backgrounds.
        // The shell will re-apply its own prompt colors immediately after.
        currentAttributes = []
        currentFgColor = .default
        currentBgColor = .default
        currentUnderlineColor = .default
        currentUnderlineStyle = .none
        invalidatePackedColors()

        markAllDirty()
    }

    // MARK: - A.6.11 Cursor Save/Restore (DECSC/DECRC)

    /// Save cursor and attributes (DECSC — ESC 7).
    func saveCursor() {
        let saved = cursor.save(
            attributes: currentAttributes,
            fgColor: currentFgColor,
            bgColor: currentBgColor,
            underlineColor: currentUnderlineColor,
            underlineStyle: currentUnderlineStyle,
            originMode: originMode,
            autoWrapMode: autoWrapMode,
            activeCharset: activeCharset,
            g0Charset: g0Charset,
            g1Charset: g1Charset
        )
        if usingAlternateBuffer {
            cursor.savedAlternate = saved
        } else {
            cursor.savedPrimary = saved
        }
    }

    /// Restore cursor and attributes (DECRC — ESC 8).
    func restoreCursor() {
        let saved = usingAlternateBuffer ? cursor.savedAlternate : cursor.savedPrimary
        guard let s = saved else { return }

        cursor.restore(from: s, gridRows: rows, gridCols: columns)
        currentAttributes = s.attributes
        currentFgColor = s.fgColor
        currentBgColor = s.bgColor
        currentUnderlineColor = s.underlineColor
        currentUnderlineStyle = s.underlineStyle
        originMode = s.originMode
        autoWrapMode = s.autoWrapMode
        activeCharset = s.activeCharset
        g0Charset = s.g0Charset
        g1Charset = s.g1Charset
        invalidatePackedColors()
    }

    // MARK: - A.6.14 Grid Snapshot Generation

    /// Produce an immutable snapshot of the current grid state for the renderer.
    /// Clears dirty tracking after snapshot is taken.
    ///
    /// When synchronized output (mode 2026) is active, returns the previously
    /// cached snapshot so the renderer keeps displaying the last complete frame
    /// while the remote app is mid-update.
    func snapshot() -> GridSnapshot {
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
            rows: rows
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
    func snapshot(scrollOffset: Int) -> GridSnapshot {
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
            rows: rows
        )
    }

    /// The number of scrollback lines available.
    var scrollbackCount: Int {
        scrollback.count
    }

    // MARK: - A.6.15 Text Extraction

    /// Extract visible rows as an array of strings (trailing whitespace trimmed).
    /// Used by the text-based fallback view, password detection, and search.
    func visibleText() -> [String] {
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

    // MARK: - Full Reset (RIS — ESC c)

    /// Perform a full terminal reset.
    func fullReset() {
        // Reset buffers
        let blankRow = makeBlankRow()
        primaryCells = [[TerminalCell]](repeating: blankRow, count: rows)
        alternateCells = [[TerminalCell]](repeating: blankRow, count: rows)
        primaryRowBase = 0
        alternateRowBase = 0
        primaryRowMap = Array(0..<rows)
        alternateRowMap = Array(0..<rows)
        usingAlternateBuffer = false

        // Reset cursor
        cursor = CursorState()

        // Reset scroll region
        scrollTop = 0
        scrollBottom = rows - 1

        // Reset modes
        originMode = false
        autoWrapMode = true
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        bracketedPasteMode = false
        synchronizedOutput = false
        lastSnapshot = nil
        reverseVideo = false
        mouseTracking = .none
        mouseEncoding = .x10
        focusReporting = false
        lineFeedMode = false

        // Reset charsets
        activeCharset = 0
        g0Charset = .ascii
        g1Charset = .ascii

        // Reset tab stops
        resetTabStops()

        // Reset attributes
        currentAttributes = []
        currentFgColor = .default
        currentBgColor = .default
        currentUnderlineColor = .default
        currentUnderlineStyle = .none
        currentHyperlink = nil
        invalidatePackedColors()

        // Reset scrollback and side table
        scrollback.clear()
        graphemeSideTable.clear()

        lastPrintedChar = nil

        markAllDirty()
    }

    /// Soft terminal reset (DECSTR — CSI ! p).
    func softReset() {
        cursor.visible = true
        cursor.style = .block
        cursor.pendingWrap = false

        originMode = false
        autoWrapMode = true
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        mouseTracking = .none
        mouseEncoding = .x10
        reverseVideo = false

        scrollTop = 0
        scrollBottom = rows - 1

        activeCharset = 0
        g0Charset = .ascii
        g1Charset = .ascii

        currentAttributes = []
        currentFgColor = .default
        currentBgColor = .default
        currentUnderlineColor = .default
        currentUnderlineStyle = .none
        invalidatePackedColors()

        resetTabStops()

        cursor.savedPrimary = nil
        cursor.savedAlternate = nil
    }

    /// Fill screen with 'E' for alignment test (DECALN — ESC # 8).
    func screenAlignmentPattern() {
        let eCell = TerminalCell(
            codepoint: 0x45, fgPacked: 0, bgPacked: 0, ulPacked: 0,
            attributes: [], underlineStyle: .none, width: 1)
        withActiveBuffer { buf, base in
            for row in 0..<rows {
                let physical = physicalRow(row, base: base)
                for col in 0..<columns {
                    releaseCellGrapheme(buf[physical][col].codepoint)
                    buf[physical][col] = eCell
                }
            }
        }
        cursor.moveTo(row: 0, col: 0, gridRows: rows, gridCols: columns)
        markAllDirty()
    }

    // MARK: - Resize

    /// Resize the terminal grid with proper content reflow.
    /// Primary buffer uses GridReflow for correct unwrap/rewrap behavior.
    /// Alternate buffer uses simple resize (TUI apps redraw on SIGWINCH anyway).
    func resize(newColumns: Int, newRows: Int) {
        guard newColumns > 0 && newRows > 0 else { return }
        guard newColumns != columns || newRows != rows else { return }

        let oldColumns = columns

        // When the alternate buffer is active, the primary cursor is saved
        // in cursor.savedPrimary. Use it for reflowing the primary buffer
        // so the primary cursor position is preserved correctly.
        let primaryCursorRow = usingAlternateBuffer
            ? (cursor.savedPrimary?.row ?? 0)
            : cursor.row
        let primaryCursorCol = usingAlternateBuffer
            ? (cursor.savedPrimary?.col ?? 0)
            : cursor.col

        // Resolve all side-table entries before linearizing so reflow
        // doesn't carry stale side-table indices.
        resolveAllSideTableEntries()

        let primaryForReflow = linearizedRows(primaryCells, base: primaryRowBase, map: primaryRowMap)

        // Reflow primary buffer (the one with scrollback that needs proper reflow)
        let reflowResult = GridReflow.reflow(
            screenRows: primaryForReflow,
            scrollback: scrollback,
            cursorRow: primaryCursorRow,
            cursorCol: primaryCursorCol,
            oldColumns: oldColumns,
            newColumns: newColumns,
            newRows: newRows
        )

        primaryCells = reflowResult.screenRows
        primaryRowBase = 0

        // Rebuild scrollback from reflow result
        scrollback = ScrollbackBuffer(maxLines: maxScrollbackLines)
        for line in reflowResult.scrollbackLines {
            scrollback.push(line)
        }

        // Simple resize for alternate buffer (TUI apps redraw on SIGWINCH)
        let alternateForResize = linearizedRows(alternateCells, base: alternateRowBase, map: alternateRowMap)
        alternateCells = simpleResizeBuffer(
            alternateForResize, newRows: newRows, newColumns: newColumns
        )
        alternateRowBase = 0

        // Update cursor from reflow result
        if !usingAlternateBuffer {
            cursor.row = reflowResult.cursorRow
            cursor.col = reflowResult.cursorCol
        } else {
            // Update the saved primary cursor from the reflow result
            if var saved = cursor.savedPrimary {
                saved.row = reflowResult.cursorRow
                saved.col = reflowResult.cursorCol
                cursor.savedPrimary = saved
            }
            cursor.row = min(cursor.row, newRows - 1)
            cursor.col = min(cursor.col, newColumns - 1)
        }
        cursor.pendingWrap = false

        columns = newColumns
        rows = newRows
        primaryRowMap = Array(0..<newRows)
        alternateRowMap = Array(0..<newRows)

        // Adjust scroll region
        scrollTop = 0
        scrollBottom = newRows - 1

        // Reset tab stops for new width
        tabStopMask = TerminalDefaults.defaultTabStopMask(columns: newColumns)

        markAllDirty()
    }

    /// Simple buffer resize without reflow (for alternate screen buffer).
    func simpleResizeBuffer(
        _ buffer: [[TerminalCell]],
        newRows: Int, newColumns: Int
    ) -> [[TerminalCell]] {
        var newBuf = [[TerminalCell]]()
        newBuf.reserveCapacity(newRows)

        for row in 0..<newRows {
            if row < buffer.count {
                var existingRow = buffer[row]
                if newColumns > existingRow.count {
                    existingRow.append(contentsOf:
                        [TerminalCell](repeating: .blank, count: newColumns - existingRow.count)
                    )
                } else if newColumns < existingRow.count {
                    existingRow = Array(existingRow.prefix(newColumns))
                }
                newBuf.append(existingRow)
            } else {
                newBuf.append([TerminalCell](repeating: .blank, count: newColumns))
            }
        }

        return newBuf
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
