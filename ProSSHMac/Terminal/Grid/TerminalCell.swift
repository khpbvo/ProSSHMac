// TerminalCell.swift
// ProSSHV2
//
// Terminal cell, cell attributes bitfield, and color types.
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

// MARK: - TerminalCell

/// A single cell in the terminal grid.
/// Each cell holds one character (or grapheme cluster), its colors, and text attributes.
nonisolated struct TerminalCell: Sendable {
    /// The character(s) displayed in this cell.
    /// Empty string represents a space. May contain multi-codepoint grapheme clusters.
    var graphemeCluster: String {
        didSet {
            primaryCodepoint = Self.extractPrimaryCodepoint(from: graphemeCluster)
        }
    }

    /// Foreground color for this cell.
    var fgColor: TerminalColor {
        didSet {
            fgPackedRGBA = fgColor.packedRGBA()
        }
    }

    /// Background color for this cell.
    var bgColor: TerminalColor {
        didSet {
            bgPackedRGBA = bgColor.packedRGBA()
        }
    }

    /// Underline color for this cell. When `.default`, renderer uses fgColor.
    var underlineColor: TerminalColor {
        didSet {
            underlinePackedRGBA = underlineColor.packedRGBA()
        }
    }

    /// Cached primary Unicode scalar value for snapshot generation.
    /// 0 means empty cell.
    var primaryCodepoint: UInt32

    /// Cached packed foreground color for GPU upload.
    var fgPackedRGBA: UInt32

    /// Cached packed background color for GPU upload.
    var bgPackedRGBA: UInt32

    /// Cached packed underline color for GPU upload.
    /// 0 means renderer should use fg color.
    var underlinePackedRGBA: UInt32

    /// Text attributes (bold, italic, underline, etc.).
    var attributes: CellAttributes

    /// Underline rendering style (none, single, double, curly, dotted, dashed).
    var underlineStyle: UnderlineStyle

    /// Cell width: 1 for normal, 2 for wide (CJK), 0 for continuation of a wide char.
    var width: UInt8

    /// Whether this cell has been modified since the last GPU upload.
    var isDirty: Bool

    /// Create a blank (space) cell with default colors and no attributes.
    static let blank = TerminalCell(
        graphemeCluster: "",
        fgColor: .default,
        bgColor: .default,
        underlineColor: .default,
        attributes: [],
        underlineStyle: .none,
        width: 1,
        isDirty: true
    )

    /// Create a cell with a single character and the given style.
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
        self.graphemeCluster = graphemeCluster
        self.fgColor = fgColor
        self.bgColor = bgColor
        self.underlineColor = underlineColor
        self.primaryCodepoint = Self.extractPrimaryCodepoint(from: graphemeCluster)
        self.fgPackedRGBA = fgColor.packedRGBA()
        self.bgPackedRGBA = bgColor.packedRGBA()
        self.underlinePackedRGBA = underlineColor.packedRGBA()
        self.attributes = attributes
        self.underlineStyle = underlineStyle
        self.width = width
        self.isDirty = isDirty
    }

    /// Fast initializer that accepts pre-computed codepoint and packed RGBA values.
    /// Pure field assignment — zero computation. Used by the ASCII hot path
    /// where packed colors are cached per-run and codepoint is just UInt32(byte).
    init(codepoint: UInt32, graphemeCluster: String,
         fgColor: TerminalColor, bgColor: TerminalColor, underlineColor: TerminalColor,
         fgPacked: UInt32, bgPacked: UInt32, underlinePacked: UInt32,
         attributes: CellAttributes, underlineStyle: UnderlineStyle, width: UInt8) {
        self.graphemeCluster = graphemeCluster
        self.fgColor = fgColor
        self.bgColor = bgColor
        self.underlineColor = underlineColor
        self.primaryCodepoint = codepoint
        self.fgPackedRGBA = fgPacked
        self.bgPackedRGBA = bgPacked
        self.underlinePackedRGBA = underlinePacked
        self.attributes = attributes
        self.underlineStyle = underlineStyle
        self.width = width
        self.isDirty = true
    }

    /// Construct a pre-erased cell without triggering 4 didSet handlers.
    /// Used by erase operations and makeBlankRow() on the hot path.
    static func erased(bgColor: TerminalColor, bgPacked: UInt32) -> TerminalCell {
        TerminalCell(
            codepoint: 0, graphemeCluster: "",
            fgColor: .default, bgColor: bgColor, underlineColor: .default,
            fgPacked: 0, bgPacked: bgPacked, underlinePacked: 0,
            attributes: [], underlineStyle: .none, width: 1
        )
    }

    /// Returns true if this cell is visually blank (space or empty, default colors, no attributes).
    var isBlank: Bool {
        (graphemeCluster.isEmpty || graphemeCluster == " ")
            && fgColor == .default
            && bgColor == .default
            && underlineColor == .default
            && attributes.isEmpty
            && width == 1
    }

    /// Reset this cell to a blank state, preserving the dirty flag.
    mutating func clear() {
        graphemeCluster = ""
        fgColor = .default
        bgColor = .default
        underlineColor = .default
        attributes = []
        underlineStyle = .none
        width = 1
        isDirty = true
    }

    /// Reset this cell to a blank state with specific colors/attributes
    /// (used for erase operations that should apply current SGR state).
    mutating func erase(bgColor: TerminalColor) {
        graphemeCluster = ""
        fgColor = .default
        self.bgColor = bgColor
        underlineColor = .default
        attributes = []
        underlineStyle = .none
        width = 1
        isDirty = true
    }

    private static func extractPrimaryCodepoint(from text: String) -> UInt32 {
        text.unicodeScalars.first?.value ?? 0
    }
}
