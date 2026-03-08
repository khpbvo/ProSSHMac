// Extracted from MetalTerminalRenderer.swift
import Metal
import CoreText
import AppKit

/// Immutable snapshot of the four CTFont variants (regular, bold, italic, bold-italic)
/// for passing to background rasterization tasks.
/// CTFont is immutable and thread-safe but not marked Sendable by Apple.
struct RasterFontSet: @unchecked Sendable {
    nonisolated(unsafe) let regular: CTFont
    nonisolated(unsafe) let bold: CTFont
    nonisolated(unsafe) let italic: CTFont
    nonisolated(unsafe) let boldItalic: CTFont
}

enum GlyphIndexPacking {
    private static let coordinateMask: UInt32 = 0x3FFF
    private static let yShift: UInt32 = 14
    private static let pageShift: UInt32 = 28

    static func pack(_ entry: AtlasEntry) -> UInt32 {
        let page = UInt32(entry.atlasPage & 0x0F) << pageShift
        let y = (UInt32(entry.y) & coordinateMask) << yShift
        let x = UInt32(entry.x) & coordinateMask
        return page | y | x
    }

    static func unpack(_ packed: UInt32) -> (atlasPage: UInt8, x: UInt16, y: UInt16)? {
        guard packed != MetalTerminalRenderer.noGlyphIndex else {
            return nil
        }

        let atlasPage = UInt8((packed >> pageShift) & 0x0F)
        let y = UInt16((packed >> yShift) & coordinateMask)
        let x = UInt16(packed & coordinateMask)
        return (atlasPage: atlasPage, x: x, y: y)
    }
}

extension MetalTerminalRenderer: GlyphResolver {

    // MARK: - Glyph Resolution

    /// Rasterize a glyph for the given key and upload it to the atlas.
    /// Called synchronously from the render path on cache miss.
    ///
    /// - Parameter key: The glyph key (codepoint + style).
    /// - Returns: An AtlasEntry describing the glyph's location in the atlas, or nil.
    func rasterizeAndUpload(key: GlyphKey) -> AtlasEntry? {
        // Scale cell dimensions for Retina-quality rasterization.
        let scale = screenScale
        let cw = Int(ceil(cellWidth * scale))
        let ch = Int(ceil(cellHeight * scale))

        guard cw > 0, ch > 0 else { return nil }
        guard let scalar = Unicode.Scalar(key.codepoint) else { return nil }

        rebuildRasterFontCacheIfNeeded(scale: scale)
        guard let regularFont = cachedRasterRegularFont else { return nil }

        let variantFont: CTFont
        if key.bold && key.italic {
            variantFont = cachedRasterBoldItalicFont ?? regularFont
        } else if key.bold {
            variantFont = cachedRasterBoldFont ?? regularFont
        } else if key.italic {
            variantFont = cachedRasterItalicFont ?? regularFont
        } else {
            variantFont = regularFont
        }

        // Font fallback: if the primary font lacks a glyph for this codepoint
        // (or the codepoint is in an emoji range where the primary font's
        // placeholder glyph is not useful), ask CoreText to resolve the best
        // system font — e.g. Apple Color Emoji for emoji, PingFang for CJK.
        let renderFont = Self.resolveRenderFont(for: scalar, primaryFont: variantFont)

        let rasterized = glyphRasterizer.rasterize(
            codepoint: scalar,
            font: renderFont,
            cellWidth: cw,
            cellHeight: ch
        )

        guard rasterized.width > 0, rasterized.height > 0, !rasterized.pixelData.isEmpty else {
            return nil
        }

        // Upload to atlas.
        let entry = rasterized.pixelData.withUnsafeBufferPointer { ptr -> AtlasEntry? in
            guard let baseAddress = ptr.baseAddress else { return nil }
            return glyphAtlas.allocate(
                width: rasterized.width,
                height: rasterized.height,
                pixelData: baseAddress,
                bearingX: Int8(clamping: rasterized.bearingX),
                bearingY: Int8(clamping: rasterized.bearingY)
            )
        }

        return entry
    }

    func rebuildRasterFontCacheIfNeeded(scale: CGFloat) {
        let clampedScale = max(scale, 1.0)
        let scaledFontSize = rasterFontSize * clampedScale
        let isCacheValid =
            cachedRasterRegularFont != nil &&
            cachedRasterFontName == rasterFontName &&
            abs(cachedRasterFontSize - scaledFontSize) < 0.001 &&
            abs(cachedRasterScale - clampedScale) < 0.001
        if isCacheValid {
            return
        }

        let base = CTFontCreateWithName(rasterFontName as CFString, scaledFontSize, nil)
        cachedRasterRegularFont = base
        cachedRasterBoldFont = CTFontCreateCopyWithSymbolicTraits(
            base,
            scaledFontSize,
            nil,
            .boldTrait,
            .boldTrait
        ) ?? base
        cachedRasterItalicFont = CTFontCreateCopyWithSymbolicTraits(
            base,
            scaledFontSize,
            nil,
            .italicTrait,
            .italicTrait
        ) ?? base
        let boldItalicTraits: CTFontSymbolicTraits = [.boldTrait, .italicTrait]
        cachedRasterBoldItalicFont = CTFontCreateCopyWithSymbolicTraits(
            base,
            scaledFontSize,
            nil,
            boldItalicTraits,
            boldItalicTraits
        ) ?? base
        cachedRasterFontName = rasterFontName
        cachedRasterFontSize = scaledFontSize
        cachedRasterScale = clampedScale

        cachedRasterFontSet = RasterFontSet(
            regular: cachedRasterRegularFont!,
            bold: cachedRasterBoldFont!,
            italic: cachedRasterItalicFont!,
            boldItalic: cachedRasterBoldItalicFont!
        )
    }

    /// Resolve the best font for rendering a specific Unicode scalar.
    ///
    /// For emoji codepoints, always asks CoreText for the system's preferred
    /// emoji font (Apple Color Emoji) since monospace fonts like SF Mono map
    /// emoji codepoints to placeholder "?" glyphs that pass glyph-presence
    /// checks but render incorrectly.
    ///
    /// For non-emoji codepoints, checks whether the primary font contains
    /// the glyph. If not, uses `CTFontCreateForString` to find a system
    /// fallback (e.g. PingFang for CJK, Symbols for Powerline glyphs).
    ///
    /// - Parameters:
    ///   - scalar: The Unicode scalar to render.
    ///   - primaryFont: The primary terminal font (SF Mono variant).
    /// - Returns: The best CTFont for rendering this scalar.
    nonisolated static func resolveRenderFont(
        for scalar: Unicode.Scalar,
        primaryFont: CTFont
    ) -> CTFont {
        let scalarValue = scalar.value

        // Block-element glyphs are used by TUIs such as Claude Code to build
        // prompt art. Some primary monospace fonts technically "contain" these
        // codepoints but render them with poor/stylized geometry. Prefer a
        // stable Menlo fallback for this range when available.
        if isBlockElementRange(scalarValue),
           let blockFont = preferredBlockElementFont(matching: primaryFont),
           fontContainsGlyph(blockFont, scalar: scalar) {
            return blockFont
        }

        // For emoji codepoints, always prefer the system emoji font.
        // Monospace fonts (SF Mono, Menlo, etc.) often have placeholder glyphs
        // for emoji that pass CTFontGetGlyphsForCharacters but render as "?".
        if isEmojiRange(scalarValue) {
            let string = String(scalar)
            let cfString = string as CFString
            let range = CFRange(location: 0, length: CFStringGetLength(cfString))
            let fallback = CTFontCreateForString(primaryFont, cfString, range)
            let fallbackFamily = CTFontCopyFamilyName(fallback) as String
            let primaryFamily = CTFontCopyFamilyName(primaryFont) as String
            // If CoreText found a different (emoji) font, use it.
            // If it returned the same font, there's no better option available.
            if fallbackFamily != primaryFamily {
                return fallback
            }
        }

        // For non-emoji: check if the primary font has the glyph.
        if scalarValue <= 0xFFFF {
            var char = UInt16(truncatingIfNeeded: scalarValue)
            var glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(primaryFont, &char, &glyph, 1), glyph != 0 {
                return primaryFont
            }
        } else {
            let string = String(scalar)
            let utf16 = Array(string.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            let found = CTFontGetGlyphsForCharacters(primaryFont, utf16, &glyphs, utf16.count)
            if found && glyphs[0] != 0 {
                return primaryFont
            }
        }

        // Primary font lacks the glyph — use CoreText system fallback.
        let string = String(scalar)
        let cfString = string as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfString))
        let fallback = CTFontCreateForString(primaryFont, cfString, range)
        return fallback
    }

    /// Check if a Unicode scalar value falls within well-known emoji ranges.
    /// These ranges should use a color emoji font rather than the monospace
    /// terminal font, which typically renders placeholders for these codepoints.
    nonisolated static func isEmojiRange(_ v: UInt32) -> Bool {
        UnicodeClassification.isEmojiCodepoint(v)
    }

    nonisolated static func isBlockElementRange(_ v: UInt32) -> Bool {
        (0x2580...0x259F).contains(v)
    }

    nonisolated static func preferredBlockElementFont(matching primaryFont: CTFont) -> CTFont? {
        let size = CTFontGetSize(primaryFont)
        let menlo = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let resolvedFamily = CTFontCopyFamilyName(menlo) as String
        guard resolvedFamily.caseInsensitiveCompare("Menlo") == .orderedSame else {
            return nil
        }
        return menlo
    }

    nonisolated static func fontContainsGlyph(_ font: CTFont, scalar: Unicode.Scalar) -> Bool {
        let scalarValue = scalar.value
        if scalarValue <= 0xFFFF {
            var char = UInt16(truncatingIfNeeded: scalarValue)
            var glyph: CGGlyph = 0
            return CTFontGetGlyphsForCharacters(font, &char, &glyph, 1) && glyph != 0
        }

        let utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) && glyphs[0] != 0
    }

    func resolveGlyphIndex(for cell: CellInstance) -> UInt32 {
        let attributes = CellAttributes(rawValue: cell.attributes)
        let bold = attributes.contains(.bold)
        let italic = attributes.contains(.italic)

        // The grid snapshot stores the Unicode codepoint in glyphIndex initially.
        let codepoint = cell.glyphIndex
        let key = GlyphKey(codepoint: codepoint, bold: bold, italic: italic)

        // Look up in cache.
        if let entry = glyphCache.trackedLookup(key) {
            return packAtlasEntry(entry)
        }

        // Cache miss: enqueue for background rasterization; return blank sentinel for this frame.
        pendingGlyphKeys.insert(key)
        return Self.noGlyphIndex
    }

    /// Pack an AtlasEntry into a UInt32 for the shader.
    /// Layout: [page:4][y:14][x:14].
    func packAtlasEntry(_ entry: AtlasEntry) -> UInt32 {
        GlyphIndexPacking.pack(entry)
    }

    /// Pure CPU glyph rasterization — safe to call from any thread.
    /// Does NOT write to GlyphAtlas; caller must upload results on the main thread.
    nonisolated static func rasterizeGlyphForBackground(
        key: GlyphKey,
        cellWidth cw: Int,
        cellHeight ch: Int,
        fontSet: RasterFontSet,
        rasterizer: GlyphRasterizer
    ) -> RasterizedGlyph? {
        guard let scalar = Unicode.Scalar(key.codepoint) else { return nil }
        let variantFont: CTFont
        if key.bold && key.italic      { variantFont = fontSet.boldItalic }
        else if key.bold               { variantFont = fontSet.bold }
        else if key.italic             { variantFont = fontSet.italic }
        else                           { variantFont = fontSet.regular }
        let renderFont = resolveRenderFont(for: scalar, primaryFont: variantFont)
        let rasterized = rasterizer.rasterize(
            codepoint: scalar, font: renderFont, cellWidth: cw, cellHeight: ch
        )
        guard rasterized.width > 0, rasterized.height > 0, !rasterized.pixelData.isEmpty else {
            return nil
        }
        return rasterized
    }
}
