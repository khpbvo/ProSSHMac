// Extracted from MetalTerminalRenderer.swift
import Metal
import CoreText
import AppKit

extension MetalTerminalRenderer {

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

        let rasterized = GlyphRasterizer.rasterize(
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
    /// Matches the Metal shader's decoding:
    ///   atlasX = float(glyphIndex & 0xFFFF)
    ///   atlasY = float((glyphIndex >> 16) & 0xFFFF)
    ///
    /// Layout: [y:16][x:16] — upper 16 bits = Y pixel position, lower 16 bits = X pixel position.
    func packAtlasEntry(_ entry: AtlasEntry) -> UInt32 {
        let x = UInt32(entry.x) & 0xFFFF
        let y = UInt32(entry.y) & 0xFFFF
        return (y << 16) | x
    }

    /// Pure CPU glyph rasterization — safe to call from any thread.
    /// Does NOT write to GlyphAtlas; caller must upload results on the main thread.
    nonisolated static func rasterizeGlyphForBackground(
        key: GlyphKey,
        cellWidth cw: Int,
        cellHeight ch: Int,
        regularFont: CTFont,
        boldFont: CTFont?,
        italicFont: CTFont?,
        boldItalicFont: CTFont?
    ) -> RasterizedGlyph? {
        guard let scalar = Unicode.Scalar(key.codepoint) else { return nil }
        let variantFont: CTFont
        if key.bold && key.italic      { variantFont = boldItalicFont ?? regularFont }
        else if key.bold               { variantFont = boldFont ?? regularFont }
        else if key.italic             { variantFont = italicFont ?? regularFont }
        else                           { variantFont = regularFont }
        let renderFont = resolveRenderFont(for: scalar, primaryFont: variantFont)
        let rasterized = GlyphRasterizer.rasterize(
            codepoint: scalar, font: renderFont, cellWidth: cw, cellHeight: ch
        )
        guard rasterized.width > 0, rasterized.height > 0, !rasterized.pixelData.isEmpty else {
            return nil
        }
        return rasterized
    }
}
