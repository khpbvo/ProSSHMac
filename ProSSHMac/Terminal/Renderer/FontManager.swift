// FontManager.swift
// ProSSHV2
//
// Terminal font manager for the Metal-based renderer (spec B.1).
// Handles font loading, cell dimension calculation, variant resolution
// (regular/bold/italic/bold-italic), fallback chains for CJK/emoji/symbols,
// and Dynamic Type scaling. Produces metrics and font references consumed
// by GlyphRasterizer — contains no rendering logic itself.

import CoreText
import CoreGraphics
import Foundation

// MARK: - GlyphKey

/// Unique key for a rasterized glyph in the atlas.
/// Combines a Unicode codepoint with its bold/italic style variant.
nonisolated struct GlyphKey: Hashable, Sendable {
    /// Unicode scalar value (U+0000 through U+10FFFF).
    let codepoint: UInt32

    /// Whether the glyph should be rendered in bold weight.
    let bold: Bool

    /// Whether the glyph should be rendered in italic style.
    let italic: Bool
}

// MARK: - FontVariant

/// The four text style variants maintained by the font manager.
/// Each variant maps to a separate atlas page in the glyph rasterizer.
nonisolated enum FontVariant: CaseIterable, Sendable {
    case regular
    case bold
    case italic
    case boldItalic
}

// MARK: - CellDimensions

/// Fixed-size cell dimensions derived from font metrics.
/// The terminal grid uses these to lay out characters in a uniform grid.
nonisolated struct CellDimensions: Sendable, Equatable {
    /// Width of a single monospace cell in points.
    let width: CGFloat

    /// Height of a single monospace cell in points (ascent + descent + leading).
    let height: CGFloat

    /// Distance from the cell top to the font baseline.
    let baseline: CGFloat

    /// The font ascent component.
    let ascent: CGFloat

    /// The font descent component (positive value).
    let descent: CGFloat

    /// The font leading component.
    let leading: CGFloat
}

// MARK: - FontManager

/// Manages terminal fonts, metrics, and fallback resolution for the Metal renderer.
///
/// The font manager is an actor to ensure thread-safe access from concurrent
/// rendering and layout operations. It loads a user-preferred monospace font
/// (defaulting to SF Mono), resolves bold/italic variants, calculates fixed-width
/// cell dimensions, and provides fallback fonts for CJK, emoji, and symbol characters.
///
/// ## Atlas Integration
/// Each ``FontVariant`` (regular, bold, italic, bold-italic) corresponds to a
/// separate atlas page. The ``GlyphKey`` struct identifies a specific glyph
/// across all variants.
///
/// ## Dynamic Type
/// Call ``updateForContentSizeCategory(_:)`` when the system content size changes.
/// This recalculates the effective font size and cell dimensions, allowing the
/// terminal grid to reflow.
actor FontManager {

    // MARK: - Configuration

    /// The user-requested font family name (e.g., "SF Mono", "Menlo", "JetBrains Mono").
    private(set) var fontName: String

    /// The base font size in points before Dynamic Type scaling.
    private(set) var baseFontSize: CGFloat

    /// The current effective font size after Dynamic Type scaling.
    private(set) var effectiveFontSize: CGFloat

    // MARK: - Resolved Fonts

    /// The resolved CTFont for each variant at the current effective size.
    private var resolvedFonts: [FontVariant: CTFont] = [:]

    // MARK: - Cell Dimensions

    /// The current cell dimensions derived from the regular font variant.
    private(set) var cellDimensions: CellDimensions

    // MARK: - Fallback Chain

    /// Ordered list of monospace font family names to try when the preferred font is unavailable.
    private static let monospaceFallbackChain: [String] = [
        "SF Mono",
        "Menlo",
        "Monaco",
        "Courier",
    ]

    /// CJK fallback font families for wide characters.
    private static let cjkFallbackFamilies: [String] = [
        "PingFang SC",
        "PingFang TC",
        "PingFang HK",
        "Hiragino Sans",
        "Heiti SC",
        "Heiti TC",
    ]

    /// Emoji font family name.
    private static let emojiFontFamily = "Apple Color Emoji"

    /// Well-known Powerline / Nerd Font families for ligature font detection.
    private static let powerlineFontFamilies: Set<String> = [
        "FiraCode Nerd Font",
        "FiraCode Nerd Font Mono",
        "Fira Code",
        "JetBrains Mono",
        "JetBrainsMono Nerd Font",
        "JetBrainsMono Nerd Font Mono",
        "Hack Nerd Font",
        "Hack Nerd Font Mono",
        "Hack",
        "Source Code Pro",
        "SauceCodePro Nerd Font",
        "SauceCodePro Nerd Font Mono",
        "Cascadia Code",
        "CaskaydiaCove Nerd Font",
        "CaskaydiaCove Nerd Font Mono",
        "Inconsolata",
        "Inconsolata Nerd Font",
        "MesloLGS NF",
        "MesloLGS Nerd Font",
        "Iosevka",
        "Iosevka Nerd Font",
    ]

    // MARK: - Dynamic Type Scaling Table

    /// Scaling multipliers indexed by content size category name.
    /// These approximate the UIKit Dynamic Type scaling curve for body text.
    private static let dynamicTypeScaleFactors: [String: CGFloat] = [
        "UICTContentSizeCategoryXS":                0.80,
        "UICTContentSizeCategoryS":                 0.85,
        "UICTContentSizeCategoryM":                 0.90,
        "UICTContentSizeCategoryL":                 1.00,   // Default
        "UICTContentSizeCategoryXL":                1.10,
        "UICTContentSizeCategoryXXL":               1.20,
        "UICTContentSizeCategoryXXXL":              1.30,
        "UICTContentSizeCategoryAccessibilityM":    1.40,
        "UICTContentSizeCategoryAccessibilityL":    1.50,
        "UICTContentSizeCategoryAccessibilityXL":   1.60,
        "UICTContentSizeCategoryAccessibilityXXL":  1.70,
        "UICTContentSizeCategoryAccessibilityXXXL": 1.80,
    ]

    // MARK: - Cached Fallback Fonts

    /// Lazily resolved CJK fallback font (first available from the CJK chain).
    private var cachedCJKFont: CTFont?
    private var cjkFontResolved = false

    /// Lazily resolved emoji font.
    private var cachedEmojiFont: CTFont?
    private var emojiFontResolved = false

    /// Lazily resolved symbol/Powerline fallback font.
    private var cachedSymbolFont: CTFont?
    private var symbolFontResolved = false

    // MARK: - Initialization

    static let platformDefaultFontSize: CGFloat = 14.0

    /// Create a font manager with the specified font name and base size.
    ///
    /// - Parameters:
    ///   - fontName: Preferred monospace font family name. Defaults to "SF Mono".
    ///   - baseFontSize: Base font size in points before Dynamic Type scaling.
    init(fontName: String = "SF Mono", baseFontSize: CGFloat = platformDefaultFontSize) {
        self.fontName = fontName
        self.baseFontSize = baseFontSize
        self.effectiveFontSize = baseFontSize

        // Temporary placeholder; will be overwritten immediately.
        self.cellDimensions = CellDimensions(
            width: 0, height: 0, baseline: 0, ascent: 0, descent: 0, leading: 0
        )

        // Resolve fonts and compute real cell dimensions.
        self.resolvedFonts = Self.resolveFontVariants(
            fontName: fontName,
            size: baseFontSize
        )
        // Update fontName to the actually resolved font so downstream consumers
        // (e.g. the rasterizer) recreate the same font, not a fallback like Helvetica.
        self.fontName = CTFontCopyFamilyName(resolvedFonts[.regular]!) as String
        self.cellDimensions = Self.computeCellDimensions(
            from: resolvedFonts[.regular]!
        )
    }

    // MARK: - B.1.1 Font Loading

    /// Change the font family and/or base size. Re-resolves all variants and
    /// recalculates cell dimensions.
    ///
    /// - Parameters:
    ///   - name: New font family name, or nil to keep the current name.
    ///   - size: New base font size in points, or nil to keep the current size.
    func setFont(name: String? = nil, size: CGFloat? = nil) {
        if let name { self.fontName = name }
        if let size { self.baseFontSize = size }

        rebuildFonts()
    }

    // MARK: - B.1.2 Cell Dimensions

    /// Returns the current cell dimensions. These are derived from the regular
    /// font variant and define the fixed-width grid cell size.
    func currentCellDimensions() -> CellDimensions {
        cellDimensions
    }

    // MARK: - B.1.4 Font Variant Resolution

    /// Returns the CTFont for the requested variant at the current effective size.
    ///
    /// - Parameter variant: The style variant (regular, bold, italic, bold-italic).
    /// - Returns: A resolved CTFont suitable for rasterization.
    func font(for variant: FontVariant) -> CTFont {
        resolvedFonts[variant]!
    }

    /// Returns the CTFont for the style described by a GlyphKey.
    ///
    /// - Parameter key: The glyph key specifying bold/italic flags.
    /// - Returns: The matching CTFont variant.
    func font(for key: GlyphKey) -> CTFont {
        let variant = Self.variant(bold: key.bold, italic: key.italic)
        return font(for: variant)
    }

    /// Map bold/italic flags to a FontVariant.
    static func variant(bold: Bool, italic: Bool) -> FontVariant {
        switch (bold, italic) {
        case (false, false): return .regular
        case (true, false):  return .bold
        case (false, true):  return .italic
        case (true, true):   return .boldItalic
        }
    }

    // MARK: - B.1.3 Font Fallback

    /// Find the appropriate font for a given Unicode scalar value.
    /// Checks the primary font first, then falls back through CJK, emoji,
    /// and symbol chains as needed.
    ///
    /// - Parameters:
    ///   - scalar: The Unicode scalar value to look up.
    ///   - variant: The desired style variant.
    /// - Returns: A CTFont that contains a glyph for the given scalar, or
    ///   the primary variant font if no fallback has a glyph either.
    func fontForCharacter(_ scalar: Unicode.Scalar, variant: FontVariant) -> CTFont {
        let primaryFont = font(for: variant)

        // Emoji range detection — checked BEFORE the primary font because
        // monospace fonts (SF Mono, Menlo, etc.) often map emoji codepoints
        // to placeholder glyphs (rendered as "?") that pass fontContainsGlyph
        // but produce incorrect output. Emoji should always prefer Apple Color Emoji.
        if Self.isEmojiScalar(scalar) {
            if let emoji = resolveEmojiFont() {
                if Self.fontContainsGlyph(emoji, scalar: scalar) {
                    return emoji
                }
            }
        }

        // Check if the primary font already has a glyph for this codepoint.
        if Self.fontContainsGlyph(primaryFont, scalar: scalar) {
            return primaryFont
        }

        // CJK / wide character detection.
        if Self.isCJKScalar(scalar) {
            if let cjk = resolveCJKFont() {
                if Self.fontContainsGlyph(cjk, scalar: scalar) {
                    return cjk
                }
            }
        }

        // Powerline / private-use-area symbols.
        if Self.isPowerlineScalar(scalar) {
            if let symbol = resolveSymbolFont() {
                if Self.fontContainsGlyph(symbol, scalar: scalar) {
                    return symbol
                }
            }
        }

        // Last resort: ask CoreText to find any system font with this glyph.
        if let systemFallback = Self.systemFallbackFont(
            for: scalar,
            baseFont: primaryFont
        ) {
            return systemFallback
        }

        // Nothing found; return the primary font (renderer will show .notdef / tofu).
        return primaryFont
    }

    /// Convenience overload that accepts a UInt32 codepoint.
    func fontForCodepoint(_ codepoint: UInt32, bold: Bool, italic: Bool) -> CTFont {
        guard let scalar = Unicode.Scalar(codepoint) else {
            return font(for: Self.variant(bold: bold, italic: italic))
        }
        return fontForCharacter(scalar, variant: Self.variant(bold: bold, italic: italic))
    }

    // MARK: - B.1.5 Dynamic Type Scaling

    /// Update the effective font size based on a content size category string.
    /// Recalculates all font variants and cell dimensions.
    ///
    /// - Parameter category: The content size category name
    ///   (e.g., "UICTContentSizeCategoryL"). Pass the raw value from
    ///   `UIApplication.shared.preferredContentSizeCategory.rawValue`.
    func updateForContentSizeCategory(_ category: String) {
        let scale = Self.dynamicTypeScaleFactors[category] ?? 1.0
        let newSize = baseFontSize * scale

        guard abs(newSize - effectiveFontSize) > 0.01 else { return }
        effectiveFontSize = newSize

        rebuildFonts()
    }

    /// Whether the currently loaded font is a known Powerline / Nerd Font.
    var isPowerlineFont: Bool {
        Self.powerlineFontFamilies.contains(fontName)
    }

    // MARK: - Internal: Font Resolution

    /// Resolve all four font variants for the given family name and size.
    /// Falls through the monospace fallback chain if the requested family
    /// is not available on the system.
    private static func resolveFontVariants(
        fontName: String,
        size: CGFloat
    ) -> [FontVariant: CTFont] {
        let regular = resolveMonospaceFont(name: fontName, size: size)

        let bold = createVariant(
            from: regular,
            traits: .boldTrait,
            size: size
        )

        let italic = createVariant(
            from: regular,
            traits: .italicTrait,
            size: size
        )

        let boldItalic = createVariant(
            from: regular,
            traits: [.boldTrait, .italicTrait],
            size: size
        )

        return [
            .regular: regular,
            .bold: bold,
            .italic: italic,
            .boldItalic: boldItalic,
        ]
    }

    /// Attempt to load a monospace font by name, falling through the chain
    /// if the requested name is not available.
    private static func resolveMonospaceFont(name: String, size: CGFloat) -> CTFont {
        // Try the user-requested font first.
        if let font = createFontIfAvailable(name: name, size: size) {
            return font
        }

        // Walk the fallback chain.
        for fallbackName in monospaceFallbackChain {
            if let font = createFontIfAvailable(name: fallbackName, size: size) {
                return font
            }
        }

        // Absolute last resort: ask the system for any monospace font.
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [
                kCTFontFamilyNameAttribute: "Courier" as CFString,
            ] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Create a CTFont from a family name, returning nil if the font is not
    /// present on the system (detected by checking the resolved family name).
    private static func createFontIfAvailable(name: String, size: CGFloat) -> CTFont? {
        let font = CTFontCreateWithName(name as CFString, size, nil)

        // CTFontCreateWithName never returns nil, but may substitute a different font.
        // Verify we got what we asked for by checking the family name.
        let resolvedFamily = CTFontCopyFamilyName(font) as String
        if resolvedFamily.lowercased() == name.lowercased() {
            return font
        }

        // Also try matching the PostScript name or display name.
        let resolvedPostScript = CTFontCopyPostScriptName(font) as String
        if resolvedPostScript.lowercased().contains(name.lowercased().replacingOccurrences(of: " ", with: "")) {
            return font
        }

        return nil
    }

    /// Create a bold, italic, or bold-italic variant of the base font using
    /// CoreText symbolic trait resolution.
    private static func createVariant(
        from baseFont: CTFont,
        traits: CTFontSymbolicTraits,
        size: CGFloat
    ) -> CTFont {
        // Ask CoreText to derive a variant with the requested traits.
        if let derived = CTFontCreateCopyWithSymbolicTraits(
            baseFont,
            size,
            nil,
            traits,
            traits
        ) {
            return derived
        }

        // Trait derivation failed (font family has no bold/italic variant).
        // Synthesize bold by increasing weight slightly, or return the base font.
        if traits.contains(.boldTrait) && !traits.contains(.italicTrait) {
            // Try creating a heavier weight from the family.
            let familyName = CTFontCopyFamilyName(baseFont) as String
            let descriptor = CTFontDescriptorCreateWithAttributes(
                [
                    kCTFontFamilyNameAttribute: familyName as CFString,
                    kCTFontTraitsAttribute: [
                        kCTFontWeightTrait: 0.4,
                    ] as CFDictionary,
                ] as CFDictionary
            )
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }

        if traits.contains(.italicTrait) && !traits.contains(.boldTrait) {
            // Synthesize italic with an affine transform (12-degree slant).
            var matrix = CGAffineTransform(a: 1.0, b: 0.0, c: CGFloat(tan(12.0 * .pi / 180.0)), d: 1.0, tx: 0.0, ty: 0.0)
            return CTFontCreateCopyWithAttributes(baseFont, size, &matrix, nil)
        }

        // Bold-italic fallback: try bold first, then slant it.
        if traits == [.boldTrait, .italicTrait] {
            let boldFont = createVariant(from: baseFont, traits: .boldTrait, size: size)
            var matrix = CGAffineTransform(a: 1.0, b: 0.0, c: CGFloat(tan(12.0 * .pi / 180.0)), d: 1.0, tx: 0.0, ty: 0.0)
            return CTFontCreateCopyWithAttributes(boldFont, size, &matrix, nil)
        }

        return baseFont
    }

    // MARK: - Internal: Cell Dimension Calculation

    /// Compute cell dimensions from the regular font's metrics.
    /// Uses the advance width of 'M' (or the font's fixed advance if available)
    /// for cell width, and ascent + descent + leading for cell height.
    private static func computeCellDimensions(from font: CTFont) -> CellDimensions {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        // Calculate monospace advance width.
        // Try measuring 'M' first (most reliable for monospace fonts).
        let cellWidth = measureMonospaceAdvance(font: font)

        // Cell height = ascent + descent + leading, ensuring at least 1pt spacing.
        let cellHeight = ceil(ascent + descent + max(leading, 1.0))

        // Return the exact advance width — the renderer pixel-aligns this
        // to the display scale so atlas slots and shader cell quads match.
        return CellDimensions(
            width: cellWidth,
            height: cellHeight,
            baseline: ceil(ascent),
            ascent: ascent,
            descent: descent,
            leading: leading
        )
    }

    /// Measure the advance width for a monospace cell.
    /// Tries 'M' first, then falls back to the font's average advance.
    private static func measureMonospaceAdvance(font: CTFont) -> CGFloat {
        // Get the glyph for 'M'.
        var characters: [UniChar] = [0x004D] // 'M'
        var glyphs: [CGGlyph] = [0]
        let found = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1)

        if found && glyphs[0] != 0 {
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
            if advance.width > 0 {
                return advance.width
            }
        }

        // Fallback: try space character (U+0020).
        characters = [0x0020]
        glyphs = [0]
        let foundSpace = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1)

        if foundSpace && glyphs[0] != 0 {
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
            if advance.width > 0 {
                return advance.width
            }
        }

        // Last resort: estimate from font size (typically ~0.6 * font size for monospace).
        return CTFontGetSize(font) * 0.6
    }

    // MARK: - Internal: Fallback Font Resolution

    /// Resolve the CJK fallback font (cached after first lookup).
    private func resolveCJKFont() -> CTFont? {
        if cjkFontResolved { return cachedCJKFont }
        cjkFontResolved = true

        for family in Self.cjkFallbackFamilies {
            let font = CTFontCreateWithName(family as CFString, effectiveFontSize, nil)
            let resolved = CTFontCopyFamilyName(font) as String
            if resolved.lowercased() == family.lowercased() {
                cachedCJKFont = font
                return font
            }
        }

        cachedCJKFont = nil
        return nil
    }

    /// Resolve the emoji font (cached after first lookup).
    private func resolveEmojiFont() -> CTFont? {
        if emojiFontResolved { return cachedEmojiFont }
        emojiFontResolved = true

        let font = CTFontCreateWithName(Self.emojiFontFamily as CFString, effectiveFontSize, nil)
        let resolved = CTFontCopyFamilyName(font) as String
        if resolved == Self.emojiFontFamily {
            cachedEmojiFont = font
            return font
        }

        cachedEmojiFont = nil
        return nil
    }

    /// Resolve a symbol/Powerline fallback font.
    /// Uses the Symbol font or the user's current font if it is a known Nerd Font.
    private func resolveSymbolFont() -> CTFont? {
        if symbolFontResolved { return cachedSymbolFont }
        symbolFontResolved = true

        // If the user's primary font is a Powerline/Nerd Font, it should already
        // contain the private-use-area glyphs. Use the regular variant.
        if isPowerlineFont {
            cachedSymbolFont = resolvedFonts[.regular]
            return cachedSymbolFont
        }

        // Try "Symbols Nerd Font" or "Symbols Nerd Font Mono" as dedicated symbol fonts.
        for name in ["Symbols Nerd Font Mono", "Symbols Nerd Font"] {
            if let font = Self.createFontIfAvailable(name: name, size: effectiveFontSize) {
                cachedSymbolFont = font
                return font
            }
        }

        cachedSymbolFont = nil
        return nil
    }

    /// Ask CoreText to find a system fallback font containing a glyph for the given scalar.
    private static func systemFallbackFont(
        for scalar: Unicode.Scalar,
        baseFont: CTFont
    ) -> CTFont? {
        let utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let found = CTFontGetGlyphsForCharacters(baseFont, utf16, &glyphs, utf16.count)

        if found && glyphs[0] != 0 {
            // The base font already has it — should not reach here, but be safe.
            return baseFont
        }

        // Use CTFontCreateForString to find a system fallback.
        let string = String(scalar) as CFString
        let fallback = CTFontCreateForString(baseFont, string, CFRange(location: 0, length: CFStringGetLength(string)))

        // Verify the fallback actually has the glyph.
        let fallbackFamily = CTFontCopyFamilyName(fallback) as String
        let baseFamily = CTFontCopyFamilyName(baseFont) as String
        if fallbackFamily != baseFamily {
            return fallback
        }

        return nil
    }

    // MARK: - Internal: Glyph Presence Check

    /// Check whether a CTFont contains a glyph for the given Unicode scalar.
    private static func fontContainsGlyph(_ font: CTFont, scalar: Unicode.Scalar) -> Bool {
        let utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let found = CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
        return found && glyphs[0] != 0
    }

    // MARK: - Internal: Unicode Range Detection

    /// Check if a scalar is in an emoji range.
    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value

        // Common emoji ranges.
        if (0x1F600...0x1F64F).contains(v) { return true }  // Emoticons
        if (0x1F300...0x1F5FF).contains(v) { return true }  // Misc Symbols and Pictographs
        if (0x1F680...0x1F6FF).contains(v) { return true }  // Transport and Map
        if (0x1F700...0x1F77F).contains(v) { return true }  // Alchemical Symbols
        if (0x1F900...0x1F9FF).contains(v) { return true }  // Supplemental Symbols
        if (0x1FA00...0x1FA6F).contains(v) { return true }  // Chess Symbols
        if (0x1FA70...0x1FAFF).contains(v) { return true }  // Symbols Extended-A
        if (0x2600...0x26FF).contains(v)   { return true }  // Misc Symbols
        if (0x2700...0x27BF).contains(v)   { return true }  // Dingbats
        if (0xFE00...0xFE0F).contains(v)   { return true }  // Variation Selectors
        if (0x200D...0x200D).contains(v)   { return true }  // ZWJ
        if v == 0x20E3                     { return true }   // Combining Enclosing Keycap
        if (0xE0020...0xE007F).contains(v) { return true }  // Tags
        if (0x231A...0x231B).contains(v)   { return true }  // Watch, Hourglass
        if (0x23E9...0x23F3).contains(v)   { return true }  // Various symbols
        if (0x23F8...0x23FA).contains(v)   { return true }  // Various symbols

        return false
    }

    /// Check if a scalar is in a CJK range (unified ideographs, kana, hangul, etc.).
    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value

        if (0x4E00...0x9FFF).contains(v)   { return true }  // CJK Unified Ideographs
        if (0x3400...0x4DBF).contains(v)   { return true }  // CJK Extension A
        if (0x20000...0x2A6DF).contains(v) { return true }  // CJK Extension B
        if (0x2A700...0x2FA1F).contains(v) { return true }  // CJK Extensions C-F + Compat
        if (0xF900...0xFAFF).contains(v)   { return true }  // CJK Compat Ideographs
        if (0xAC00...0xD7AF).contains(v)   { return true }  // Hangul Syllables
        if (0x3040...0x309F).contains(v)   { return true }  // Hiragana
        if (0x30A0...0x30FF).contains(v)   { return true }  // Katakana
        if (0x3000...0x303F).contains(v)   { return true }  // CJK Symbols and Punctuation
        if (0xFF01...0xFF60).contains(v)   { return true }  // Fullwidth Forms
        if (0xFFE0...0xFFE6).contains(v)   { return true }  // Fullwidth Signs
        if (0x3100...0x312F).contains(v)   { return true }  // Bopomofo
        if (0x31A0...0x31BF).contains(v)   { return true }  // Bopomofo Extended
        if (0x2E80...0x2FDF).contains(v)   { return true }  // CJK Radicals, Kangxi
        if (0x3200...0x33FF).contains(v)   { return true }  // Enclosed CJK

        return false
    }

    /// Check if a scalar is in a Powerline / Nerd Font private-use-area range.
    private static func isPowerlineScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value

        // Powerline symbols (standard range).
        if (0xE0A0...0xE0A3).contains(v) { return true }
        if (0xE0B0...0xE0B3).contains(v) { return true }

        // Powerline Extra symbols.
        if (0xE0A4...0xE0A7).contains(v) { return true }
        if (0xE0B4...0xE0C8).contains(v) { return true }
        if (0xE0CA...0xE0CA).contains(v) { return true }
        if (0xE0CC...0xE0D4).contains(v) { return true }

        // Nerd Fonts: Seti-UI + Custom, Devicons, Font Awesome, etc.
        if (0xE5FA...0xE6AC).contains(v) { return true }  // Seti-UI + Custom
        if (0xE700...0xE7C5).contains(v) { return true }  // Devicons
        if (0xF000...0xF2E0).contains(v) { return true }  // Font Awesome
        if (0xE200...0xE2A9).contains(v) { return true }  // Font Awesome Extension
        if (0xF0001...0xF1AF0).contains(v) { return true } // Material Design Icons
        if (0xE300...0xE3E3).contains(v) { return true }  // Weather
        if (0xF500...0xFD46).contains(v) { return true }  // Octicons + others
        if (0xE000...0xE00A).contains(v) { return true }  // Pomicons
        if (0x2800...0x28FF).contains(v) { return true }  // Braille Patterns (used by some TUIs)

        return false
    }

    // MARK: - Internal: Rebuild

    /// Rebuild all font variants, invalidate fallback caches, and recompute cell dimensions.
    private func rebuildFonts() {
        resolvedFonts = Self.resolveFontVariants(
            fontName: fontName,
            size: effectiveFontSize
        )
        fontName = CTFontCopyFamilyName(resolvedFonts[.regular]!) as String
        cellDimensions = Self.computeCellDimensions(
            from: resolvedFonts[.regular]!
        )

        // Invalidate fallback caches so they pick up the new size.
        cachedCJKFont = nil
        cjkFontResolved = false
        cachedEmojiFont = nil
        emojiFontResolved = false
        cachedSymbolFont = nil
        symbolFontResolved = false
    }
}
