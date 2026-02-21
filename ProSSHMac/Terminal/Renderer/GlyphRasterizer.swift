// GlyphRasterizer.swift
// ProSSHV2
//
// Rasterizes individual glyphs into pixel buffers for upload to a Metal texture atlas.
//
// Uses CoreText (CTFont/CTLine) to render Unicode codepoints into RGBA bitmaps.
// Handles three rendering paths:
//   1. Normal text glyphs -- rendered as white-on-transparent RGBA (shader applies color)
//   2. Color emoji -- rendered as premultiplied BGRA (Apple Color Emoji produces BGRA)
//   3. Wide characters (CJK) -- rasterized into a buffer that is 2x the standard cell width
//
// The rasterizer is stateless: pure function from (font + codepoint + cell dimensions) to pixels.
// Thread-safe for concurrent use from any isolation domain.

import CoreText
import CoreGraphics
import Foundation

// MARK: - RasterizedGlyph

/// The result of rasterizing a single glyph. Contains the pixel data and metrics
/// needed by GlyphAtlas to place the glyph into the texture atlas.
struct RasterizedGlyph: Sendable {
    /// Raw pixel data in RGBA premultiplied alpha format (4 bytes per pixel).
    /// For color emoji, the source is BGRA; the rasterizer swizzles to RGBA for
    /// uniform Metal texture format.
    let pixelData: [UInt8]

    /// Width of the rasterized bitmap in pixels.
    let width: Int

    /// Height of the rasterized bitmap in pixels.
    let height: Int

    /// Horizontal bearing: offset from the pen position to the left edge of the bitmap.
    /// Positive means the bitmap starts to the right of the pen position.
    let bearingX: Int

    /// Vertical bearing: offset from the baseline to the top edge of the bitmap.
    /// Positive means the bitmap extends above the baseline.
    let bearingY: Int

    /// True if this glyph contains color data (emoji). When false, the shader
    /// should treat the alpha channel as coverage and apply the foreground color.
    let isColor: Bool

    /// True if this is a wide (double-width) character occupying two cells.
    let isWide: Bool

    /// An empty glyph with zero dimensions. Used as a fallback for unprintable
    /// codepoints or rasterization failures.
    static let empty = RasterizedGlyph(
        pixelData: [],
        width: 0,
        height: 0,
        bearingX: 0,
        bearingY: 0,
        isColor: false,
        isWide: false
    )
}

// MARK: - GlyphRasterizer

/// Stateless glyph rasterizer. Renders Unicode codepoints into pixel buffers
/// suitable for upload to a Metal texture atlas.
///
/// All methods are static and thread-safe. No instance state is required
/// because rasterization is a pure function of its inputs.
enum GlyphRasterizer {
    private static let deviceRGBColorSpace = CGColorSpaceCreateDeviceRGB()

    // MARK: - B.2.1 Primary Rasterization Entry Point

    /// Rasterize a single Unicode codepoint using the given font and cell dimensions.
    ///
    /// - Parameters:
    ///   - codepoint: The Unicode scalar value to rasterize.
    ///   - font: The CTFont to use for rendering. Should already have the desired size applied.
    ///   - cellWidth: Width of a single terminal cell in pixels (from FontManager).
    ///   - cellHeight: Height of a single terminal cell in pixels (from FontManager).
    /// - Returns: A `RasterizedGlyph` containing the rendered pixel data and metrics.
    static func rasterize(
        codepoint: UnicodeScalar,
        font: CTFont,
        cellWidth: Int,
        cellHeight: Int
    ) -> RasterizedGlyph {
        // Determine if this codepoint is a color glyph (emoji)
        let isColor = isColorGlyph(codepoint: codepoint, font: font)

        // Determine if this is a wide character (CJK, fullwidth, etc.)
        let isWide = isWideCharacter(codepoint: codepoint)

        // B.2.4: Wide characters get double-width rasterization buffer
        let rasterWidth = isWide ? cellWidth * 2 : cellWidth
        let rasterHeight = cellHeight

        guard rasterWidth > 0 && rasterHeight > 0 else {
            return .empty
        }

        // Fast path for the dominant case: single BMP scalar, non-color glyph.
        var line: CTLine?
        var imageBounds = CGRect.zero
        var directGlyph: CGGlyph = 0
        var hasDirectGlyph = false
        if !isColor, codepoint.value <= 0xFFFF {
            var char = UInt16(truncatingIfNeeded: codepoint.value)
            if CTFontGetGlyphsForCharacters(font, &char, &directGlyph, 1), directGlyph != 0 {
                imageBounds = CTFontGetBoundingRectsForGlyphs(font, .default, &directGlyph, nil, 1)
                hasDirectGlyph = true
            }
        }

        if !hasDirectGlyph {
            let string = String(codepoint)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ]
            let attrString = NSAttributedString(string: string, attributes: attributes)
            let textLine = CTLineCreateWithAttributedString(attrString)
            line = textLine
            imageBounds = CTLineGetImageBounds(textLine, nil)
        }

        // Terminal cells are fixed-advance slots; draw at the cell origin.
        let penX: CGFloat = 0

        // Vertically position so the baseline sits at the correct place within the cell
        // Baseline is positioned so that ascent fills from top and descent fills at bottom
        let fontAscent = CTFontGetAscent(font)
        let fontDescent = CTFontGetDescent(font)
        let fontHeight = fontAscent + fontDescent
        let penY: CGFloat
        if fontHeight > 0 {
            // Center the font metrics vertically, then place baseline accordingly
            let verticalOffset = (CGFloat(rasterHeight) - fontHeight) / 2.0
            penY = verticalOffset + fontDescent
        } else {
            penY = fontDescent
        }

        // Allocate pixel buffer
        let bytesPerPixel = 4
        let bytesPerRow = rasterWidth * bytesPerPixel
        let bufferSize = bytesPerRow * rasterHeight
        var pixelBuffer = [UInt8](repeating: 0, count: bufferSize)

        // B.2.3: Choose color space and bitmap info based on glyph type
        let colorSpace: CGColorSpace
        let bitmapInfo: UInt32

        if isColor {
            // Color emoji: Apple renders these in BGRA premultiplied alpha
            // We render in BGRA and then swizzle to RGBA for Metal
            colorSpace = deviceRGBColorSpace
            bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        } else {
            // Normal text: render as white text on transparent background
            // The shader will apply the actual foreground color using alpha as coverage
            colorSpace = deviceRGBColorSpace
            bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        }

        // Create bitmap context
        guard let context = CGContext(
            data: &pixelBuffer,
            width: rasterWidth,
            height: rasterHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return .empty
        }

        // Configure context
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        if isColor {
            // Color emoji: no need to set fill color, the glyphs carry their own color
            context.setShouldSmoothFonts(false)
        } else {
            // Normal text: draw white glyphs; shader multiplies by foreground color
            context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
            context.setShouldSmoothFonts(true)
            // B.2.2: Enable subpixel positioning for sharper text
            context.setShouldSubpixelPositionFonts(true)
            context.setShouldSubpixelQuantizeFonts(false)
        }

        // Set the text drawing position
        context.textPosition = CGPoint(x: penX, y: penY)

        // Draw the glyph
        if hasDirectGlyph {
            var glyph = directGlyph
            var position = CGPoint(x: penX, y: penY)
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        } else if let line {
            CTLineDraw(line, context)
        }

        // B.2.3: For BGRA rendering (color emoji), swizzle to RGBA
        if isColor {
            swizzleBGRAtoRGBA(&pixelBuffer, count: bufferSize)
        }

        // Compute bearing values from image bounds relative to pen position
        let bearingX: Int
        let bearingY: Int

        if imageBounds.isEmpty {
            bearingX = 0
            bearingY = 0
        } else {
            bearingX = Int(floor(imageBounds.origin.x))
            bearingY = Int(ceil(imageBounds.origin.y + imageBounds.size.height))
        }

        return RasterizedGlyph(
            pixelData: pixelBuffer,
            width: rasterWidth,
            height: rasterHeight,
            bearingX: bearingX,
            bearingY: bearingY,
            isColor: isColor,
            isWide: isWide
        )
    }

    // MARK: - B.2.3 Color Emoji Detection

    /// Determine whether a codepoint should be rendered as a color glyph.
    ///
    /// Detection strategy:
    /// 1. Check if the font has the `kCTFontColorGlyphsTrait` trait (sbix/COLR/CBDT table)
    /// 2. Check common emoji Unicode ranges
    /// 3. For ambiguous codepoints, attempt to resolve with Apple Color Emoji font
    ///
    /// - Parameters:
    ///   - codepoint: The Unicode scalar value to check.
    ///   - font: The CTFont being used for rendering.
    /// - Returns: True if the codepoint should be rendered as a color (emoji) glyph.
    private static func isColorGlyph(codepoint: UnicodeScalar, font: CTFont) -> Bool {
        // Fast path: check if the codepoint falls in well-known emoji ranges
        if isEmojiCodepoint(codepoint) {
            return true
        }

        // Check if the font itself reports color glyph support via traits
        let traits = CTFontGetSymbolicTraits(font)
        let hasColorGlyphs = traits.contains(.traitColorGlyphs)

        if hasColorGlyphs {
            // The font has color tables. Check if this specific codepoint
            // maps to a glyph in the font (not all codepoints in a color font
            // are necessarily color glyphs).
            var glyph: CGGlyph = 0
            var char = UInt16(truncatingIfNeeded: codepoint.value)

            // For BMP codepoints, use direct lookup
            if codepoint.value <= 0xFFFF {
                let found = CTFontGetGlyphsForCharacters(font, &char, &glyph, 1)
                return found && glyph != 0
            }
        }

        return false
    }

    /// Check if a Unicode scalar value falls within well-known emoji ranges.
    ///
    /// This covers the majority of emoji without needing to query the font.
    /// Includes pictographs, emoticons, symbols, flags, and modifier sequences.
    private static func isEmojiCodepoint(_ scalar: UnicodeScalar) -> Bool {
        UnicodeClassification.isEmojiScalar(scalar)
    }

    // MARK: - B.2.4 Wide Character Detection

    /// Determine if a codepoint is a wide (double-width) character.
    /// Delegates to `CharacterWidth.isWide(_:)` for consistency with the grid.
    private static func isWideCharacter(codepoint: UnicodeScalar) -> Bool {
        CharacterWidth.isWide(codepoint)
    }

    // MARK: - BGRA to RGBA Swizzle

    /// Swizzle pixel data from BGRA byte order to RGBA byte order in-place.
    ///
    /// Apple Color Emoji renders in BGRA premultiplied alpha format (byte order
    /// 32-little with premultiplied-first alpha). Metal textures expect RGBA, so
    /// we swap the red and blue channels.
    ///
    /// - Parameters:
    ///   - buffer: The pixel buffer to swizzle in-place.
    ///   - count: Total number of bytes in the buffer.
    private static func swizzleBGRAtoRGBA(_ buffer: inout [UInt8], count: Int) {
        let pixelCount = count / 4
        buffer.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt32.self)
            guard pixelCount <= words.count else { return }
            for i in 0..<pixelCount {
                let value = words[i] // BGRA bytes in memory => 0xAARRGGBB on little-endian
                words[i] = (value & 0xFF00_FF00) | ((value & 0x00FF_0000) >> 16) | ((value & 0x0000_00FF) << 16)
            }
        }
    }

    // MARK: - Grapheme Cluster Rasterization

    /// Rasterize a full grapheme cluster (which may contain multiple codepoints)
    /// into a pixel buffer.
    ///
    /// This is useful for complex emoji sequences (flag pairs, skin tone modifiers,
    /// ZWJ sequences) and combining character sequences that cannot be represented
    /// as a single `UnicodeScalar`.
    ///
    /// - Parameters:
    ///   - graphemeCluster: The string containing the grapheme cluster to rasterize.
    ///   - font: The CTFont to use for rendering.
    ///   - cellWidth: Width of a single terminal cell in pixels.
    ///   - cellHeight: Height of a single terminal cell in pixels.
    ///   - isWide: Whether this grapheme occupies two terminal cells.
    /// - Returns: A `RasterizedGlyph` containing the rendered pixel data and metrics.
    static func rasterize(
        graphemeCluster: String,
        font: CTFont,
        cellWidth: Int,
        cellHeight: Int,
        isWide: Bool
    ) -> RasterizedGlyph {
        guard !graphemeCluster.isEmpty else {
            return .empty
        }

        // For single-scalar strings, delegate to the codepoint-based path
        let scalars = graphemeCluster.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first {
            return rasterize(
                codepoint: scalar,
                font: font,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            )
        }

        // Multi-scalar grapheme cluster (emoji sequences, combining marks, etc.)
        // These are almost always color emoji sequences
        let isColor = graphemeCluster.unicodeScalars.contains { isEmojiCodepoint($0) }

        let rasterWidth = isWide ? cellWidth * 2 : cellWidth
        let rasterHeight = cellHeight

        guard rasterWidth > 0 && rasterHeight > 0 else {
            return .empty
        }

        // Create attributed string
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let attrString = NSAttributedString(string: graphemeCluster, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)

        // Terminal cells are fixed-advance slots; draw at the cell origin.
        let penX: CGFloat = 0

        let fontAscent = CTFontGetAscent(font)
        let fontDescent = CTFontGetDescent(font)
        let fontHeight = fontAscent + fontDescent
        let penY: CGFloat
        if fontHeight > 0 {
            let verticalOffset = (CGFloat(rasterHeight) - fontHeight) / 2.0
            penY = verticalOffset + fontDescent
        } else {
            penY = fontDescent
        }

        // Allocate pixel buffer
        let bytesPerPixel = 4
        let bytesPerRow = rasterWidth * bytesPerPixel
        let bufferSize = bytesPerRow * rasterHeight
        var pixelBuffer = [UInt8](repeating: 0, count: bufferSize)

        // Set up color space and bitmap info
        let colorSpace = deviceRGBColorSpace
        let bitmapInfo: UInt32

        if isColor {
            bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        } else {
            bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        }

        guard let context = CGContext(
            data: &pixelBuffer,
            width: rasterWidth,
            height: rasterHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return .empty
        }

        // Configure context
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        if isColor {
            context.setShouldSmoothFonts(false)
        } else {
            context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
            context.setShouldSmoothFonts(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setShouldSubpixelQuantizeFonts(false)
        }

        context.textPosition = CGPoint(x: penX, y: penY)
        CTLineDraw(line, context)

        if isColor {
            swizzleBGRAtoRGBA(&pixelBuffer, count: bufferSize)
        }

        let imageBounds = CTLineGetImageBounds(line, nil)
        let bearingX: Int
        let bearingY: Int

        if imageBounds.isEmpty {
            bearingX = 0
            bearingY = 0
        } else {
            bearingX = Int(floor(imageBounds.origin.x))
            bearingY = Int(ceil(imageBounds.origin.y + imageBounds.size.height))
        }

        return RasterizedGlyph(
            pixelData: pixelBuffer,
            width: rasterWidth,
            height: rasterHeight,
            bearingX: bearingX,
            bearingY: bearingY,
            isColor: isColor,
            isWide: isWide
        )
    }
}
