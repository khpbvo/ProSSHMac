// TerminalCell.swift
// ProSSHV2
//
// Terminal cell (packed 20-byte layout), cell attributes bitfield,
// color types, and grapheme side table.
// These are the fundamental data types for the terminal grid model.

import Foundation

// MARK: - TerminalColor

/// Represents a terminal color value.
/// Supports default, indexed (256-color), and truecolor (24-bit RGB).
nonisolated enum TerminalColor: Sendable, Equatable, Hashable {
    /// Terminal default foreground or background color (theme-dependent).
    case `default`

    /// Indexed color (0–255).
    /// - 0–7: standard colors
    /// - 8–15: bright/high-intensity colors
    /// - 16–231: 6×6×6 color cube
    /// - 232–255: 24-step grayscale ramp
    case indexed(UInt8)

    /// 24-bit truecolor RGB.
    case rgb(UInt8, UInt8, UInt8)

    /// Resolve this color to concrete RGB values using the standard 256-color palette.
    /// Returns nil for `.default` (caller should use theme default).
    func resolvedRGB() -> (r: UInt8, g: UInt8, b: UInt8)? {
        switch self {
        case .default:
            return nil
        case .indexed(let index):
            return ColorPalette.rgb(forIndex: index)
        case .rgb(let r, let g, let b):
            return (r, g, b)
        }
    }

    /// Pack this color into a UInt32 (RGBA, alpha=0xFF) for GPU upload.
    /// Returns 0 for `.default` (shader handles default colors separately).
    func packedRGBA() -> UInt32 {
        guard let (r, g, b) = resolvedRGB() else {
            return 0
        }
        return (UInt32(r) << 24) | (UInt32(g) << 16) | (UInt32(b) << 8) | 0xFF
    }

    /// Pack with boldIsBright pre-applied at write-time.
    /// Bold + standard color (0-7) → bright variant (8-15).
    func packedRGBA(bold: Bool, boldIsBright: Bool) -> UInt32 {
        if boldIsBright && bold, case .indexed(let idx) = self, idx < 8 {
            return TerminalColor.indexed(idx + 8).packedRGBA()
        }
        return packedRGBA()
    }
}

// MARK: - CellAttributes

/// Bitfield for terminal cell text attributes.
/// Maps to SGR (Select Graphic Rendition) attributes.
nonisolated struct CellAttributes: OptionSet, Sendable, Hashable {
    let rawValue: UInt16

    static let bold          = CellAttributes(rawValue: 1 << 0)
    static let dim           = CellAttributes(rawValue: 1 << 1)
    static let italic        = CellAttributes(rawValue: 1 << 2)
    static let underline     = CellAttributes(rawValue: 1 << 3)
    static let blink         = CellAttributes(rawValue: 1 << 4)
    static let reverse       = CellAttributes(rawValue: 1 << 5)
    static let hidden        = CellAttributes(rawValue: 1 << 6)
    static let strikethrough = CellAttributes(rawValue: 1 << 7)
    static let doubleUnder   = CellAttributes(rawValue: 1 << 8)
    static let wideChar      = CellAttributes(rawValue: 1 << 9)
    static let wrapped       = CellAttributes(rawValue: 1 << 10) // Line was auto-wrapped
    static let overline      = CellAttributes(rawValue: 1 << 11)
}

// MARK: - TerminalCell (Packed 20-byte layout)

/// A single cell in the terminal grid.
/// Packed layout: 4×UInt32 + UInt16 + 2×UInt8 = 20 bytes (down from ~50).
///
/// Removed stored fields: `graphemeCluster` (String), `fgColor`/`bgColor`/`underlineColor`
/// (TerminalColor enums), `primaryCodepoint` (redundant), `isDirty` (grid-level tracking).
/// Backward-compatible computed properties are provided for these.
nonisolated struct TerminalCell: Sendable {

    // MARK: Stored Properties (20 bytes total)

    /// Unicode codepoint. 0=blank, valid scalar=direct, 0x80000000|idx=side table.
    var codepoint: UInt32

    /// GPU-ready foreground RGBA. boldIsBright pre-applied at write-time. 0=default.
    var fgPackedRGBA: UInt32

    /// GPU-ready background RGBA. 0=default.
    var bgPackedRGBA: UInt32

    /// GPU-ready underline RGBA. 0=use fgColor.
    var underlinePackedRGBA: UInt32

    /// Text attributes (bold, italic, underline, etc.).
    var attributes: CellAttributes

    /// Underline rendering style (none, single, double, curly, dotted, dashed).
    var underlineStyle: UnderlineStyle

    /// Cell width: 1 for normal, 2 for wide (CJK), 0 for continuation of a wide char.
    var width: UInt8

    // MARK: Primary Init (zero-computation, hot path)

    /// Pure field assignment — zero computation. Used by printCharacter and
    /// printASCIIBytesBulk where packed colors are cached per-run.
    @inline(__always)
    init(codepoint: UInt32, fgPacked: UInt32, bgPacked: UInt32, ulPacked: UInt32,
         attributes: CellAttributes, underlineStyle: UnderlineStyle, width: UInt8) {
        self.codepoint = codepoint
        self.fgPackedRGBA = fgPacked
        self.bgPackedRGBA = bgPacked
        self.underlinePackedRGBA = ulPacked
        self.attributes = attributes
        self.underlineStyle = underlineStyle
        self.width = width
    }

    // MARK: Backward-Compatible Init (tests, cold paths)

    /// Create a cell from enum colors and a string. Computes packed values internally.
    /// The `isDirty` parameter is accepted for call-site compatibility but ignored
    /// (grid-level dirty tracking is sufficient).
    init(
        graphemeCluster: String = "",
        fgColor: TerminalColor = .default,
        bgColor: TerminalColor = .default,
        underlineColor: TerminalColor = .default,
        attributes: CellAttributes = [],
        underlineStyle: UnderlineStyle = .none,
        width: UInt8 = 1,
        isDirty: Bool = true
    ) {
        self.codepoint = Self.extractPrimaryCodepoint(from: graphemeCluster)
        self.fgPackedRGBA = fgColor.packedRGBA()
        self.bgPackedRGBA = bgColor.packedRGBA()
        self.underlinePackedRGBA = underlineColor.packedRGBA()
        self.attributes = attributes
        self.underlineStyle = underlineStyle
        self.width = width
    }

    // MARK: Static Factories

    /// A blank (space) cell with default colors and no attributes.
    static let blank = TerminalCell(
        codepoint: 0, fgPacked: 0, bgPacked: 0, ulPacked: 0,
        attributes: [], underlineStyle: .none, width: 1
    )

    /// Pre-erased cell with only a packed background color.
    static func erased(bgPacked: UInt32) -> TerminalCell {
        TerminalCell(codepoint: 0, fgPacked: 0, bgPacked: bgPacked, ulPacked: 0,
                     attributes: [], underlineStyle: .none, width: 1)
    }

    /// Pre-erased cell (backward-compatible signature; bgColor param is unused).
    static func erased(bgColor: TerminalColor, bgPacked: UInt32) -> TerminalCell {
        TerminalCell(codepoint: 0, fgPacked: 0, bgPacked: bgPacked, ulPacked: 0,
                     attributes: [], underlineStyle: .none, width: 1)
    }

    // MARK: Computed Properties (backward compatibility)

    /// The character(s) displayed in this cell.
    /// Reconstructs a String from the codepoint. Returns "\u{FFFD}" for side-table entries
    /// (caller should use `TerminalGrid.resolveGrapheme(for:)` for full grapheme clusters).
    var graphemeCluster: String {
        get {
            if codepoint == 0 { return "" }
            if codepoint & GraphemeSideTable.sentinel != 0 { return "\u{FFFD}" }
            if let scalar = UnicodeScalar(codepoint) {
                return String(scalar)
            }
            return "\u{FFFD}"
        }
        set {
            codepoint = Self.extractPrimaryCodepoint(from: newValue)
        }
    }

    /// Foreground color (decoded from packed RGBA).
    /// Lossy for indexed colors: uses palette reverse lookup to reconstruct `.indexed()`
    /// where possible, otherwise returns `.rgb()`.
    var fgColor: TerminalColor {
        get { Self.decodeColor(fgPackedRGBA) }
        set { fgPackedRGBA = newValue.packedRGBA() }
    }

    /// Background color (decoded from packed RGBA).
    var bgColor: TerminalColor {
        get { Self.decodeColor(bgPackedRGBA) }
        set { bgPackedRGBA = newValue.packedRGBA() }
    }

    /// Underline color (decoded from packed RGBA).
    var underlineColor: TerminalColor {
        get { Self.decodeColor(underlinePackedRGBA) }
        set { underlinePackedRGBA = newValue.packedRGBA() }
    }

    /// Primary codepoint (alias). Returns 0 for side-table entries.
    var primaryCodepoint: UInt32 {
        get { codepoint & GraphemeSideTable.sentinel != 0 ? 0 : codepoint }
        set { codepoint = newValue }
    }

    /// Always returns true. Grid-level dirty tracking is sufficient;
    /// per-cell dirty is no longer stored. Setter is a no-op.
    var isDirty: Bool {
        get { true }
        set { /* no-op — grid-level tracking */ }
    }

    // MARK: Cell State

    /// Returns true if this cell is visually blank (space or empty, default colors,
    /// no attributes). Uses packed values directly — no String comparison.
    var isBlank: Bool {
        (codepoint == 0 || codepoint == 0x20)
            && fgPackedRGBA == 0
            && bgPackedRGBA == 0
            && underlinePackedRGBA == 0
            && attributes.isEmpty
            && width == 1
    }

    /// Reset this cell to a blank state.
    mutating func clear() {
        codepoint = 0
        fgPackedRGBA = 0
        bgPackedRGBA = 0
        underlinePackedRGBA = 0
        attributes = []
        underlineStyle = .none
        width = 1
    }

    /// Reset this cell to an erased state with a specific background color
    /// (used for erase operations that apply current SGR state).
    mutating func erase(bgColor: TerminalColor) {
        codepoint = 0
        fgPackedRGBA = 0
        bgPackedRGBA = bgColor.packedRGBA()
        underlinePackedRGBA = 0
        attributes = []
        underlineStyle = .none
        width = 1
    }

    // MARK: Internal Helpers

    /// Extract the first Unicode scalar value from a string. Returns 0 for empty strings.
    static func extractPrimaryCodepoint(from text: String) -> UInt32 {
        text.unicodeScalars.first?.value ?? 0
    }

    /// Reverse lookup table: packed RGBA → palette index.
    /// Built once at startup for the standard 256-color palette.
    private static let packedToIndexed: [UInt32: UInt8] = {
        var dict = [UInt32: UInt8]()
        dict.reserveCapacity(256)
        for i in 0..<256 {
            let idx = UInt8(i)
            let rgb = ColorPalette.rgb(forIndex: idx)
            let packed = (UInt32(rgb.r) << 24) | (UInt32(rgb.g) << 16) | (UInt32(rgb.b) << 8) | 0xFF
            if dict[packed] == nil {
                dict[packed] = idx
            }
        }
        return dict
    }()

    /// Decode packed RGBA back to TerminalColor.
    /// Uses palette reverse lookup to reconstruct `.indexed()` where possible.
    private static func decodeColor(_ packed: UInt32) -> TerminalColor {
        if packed == 0 { return .default }
        if let index = packedToIndexed[packed] {
            return .indexed(index)
        }
        let r = UInt8((packed >> 24) & 0xFF)
        let g = UInt8((packed >> 16) & 0xFF)
        let b = UInt8((packed >> 8) & 0xFF)
        return .rgb(r, g, b)
    }
}

// MARK: - GraphemeSideTable

/// Storage for multi-codepoint grapheme clusters (emoji combining sequences, etc.).
/// 99%+ of terminal cells are single-codepoint (ASCII, BMP). For the rare
/// multi-codepoint grapheme clusters, cells store `0x80000000 | sideTableIndex`
/// and the full string lives here. Uses a free-list to recycle slots.
nonisolated struct GraphemeSideTable: Sendable {

    /// Bit 31 sentinel marking a codepoint as a side-table reference.
    static let sentinel: UInt32 = 0x80000000

    /// String storage. nil entries are free slots.
    private var storage: [String?] = []

    /// Free slot indices for reuse.
    private var freeIndices: [Int] = []

    /// Number of active (non-free) entries.
    private(set) var activeCount: Int = 0

    /// Whether there are any active entries.
    var isEmpty: Bool { activeCount == 0 }

    /// Allocate a slot for the given grapheme cluster string.
    /// Returns a codepoint with the sentinel bit set.
    mutating func allocate(_ string: String) -> UInt32 {
        let index: Int
        if let recycled = freeIndices.popLast() {
            index = recycled
            storage[index] = string
        } else {
            index = storage.count
            storage.append(string)
        }
        activeCount += 1
        return Self.sentinel | UInt32(index)
    }

    /// Resolve a side-table codepoint to its grapheme cluster string.
    /// Returns nil if the codepoint is not a side-table reference or the slot is empty.
    func resolve(_ codepoint: UInt32) -> String? {
        guard codepoint & Self.sentinel != 0 else { return nil }
        let index = Int(codepoint & ~Self.sentinel)
        guard index >= 0 && index < storage.count else { return nil }
        return storage[index]
    }

    /// Release a side-table slot back to the free list.
    mutating func release(_ codepoint: UInt32) {
        guard codepoint & Self.sentinel != 0 else { return }
        let index = Int(codepoint & ~Self.sentinel)
        guard index >= 0 && index < storage.count else { return }
        guard storage[index] != nil else { return }
        storage[index] = nil
        freeIndices.append(index)
        activeCount -= 1
    }

    /// Check if a codepoint is a side-table reference.
    @inline(__always)
    static func isSideTable(_ codepoint: UInt32) -> Bool {
        codepoint & sentinel != 0
    }

    /// Clear all entries and free list.
    mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        freeIndices.removeAll(keepingCapacity: true)
        activeCount = 0
    }
}
