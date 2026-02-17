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
    var graphemeCluster: String

    /// Foreground color for this cell.
    var fgColor: TerminalColor

    /// Background color for this cell.
    var bgColor: TerminalColor

    /// Underline color for this cell. When `.default`, renderer uses fgColor.
    var underlineColor: TerminalColor

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
        self.attributes = attributes
        self.underlineStyle = underlineStyle
        self.width = width
        self.isDirty = isDirty
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
}
