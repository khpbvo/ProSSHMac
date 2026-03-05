// GlyphRasterizer.swift
// ProSSHV2
//
// Rasterizes individual glyphs into pixel buffers for upload to a Metal texture atlas.
//
// Uses CoreText (CTFont/CTLine) to render Unicode codepoints into BGRA bitmaps.
// Handles three rendering paths:
//   1. Normal text glyphs -- rendered as white-on-transparent BGRA (shader applies color)
//   2. Color emoji -- rendered as premultiplied BGRA (Apple Color Emoji produces BGRA natively)
//   3. Wide characters (CJK) -- rasterized into a buffer that is 2x the standard cell width
//
// Each caller owns a GlyphRasterizer instance whose scratch buffer and CGContext are
// reused across rasterize() calls, eliminating per-glyph heap allocations and expensive
// CoreGraphics context creation during cache pre-population and background rasterization.

import CoreText
import CoreGraphics
import Foundation

// MARK: - RasterizedGlyph

/// The result of rasterizing a single glyph. Contains the pixel data and metrics
/// needed by GlyphAtlas to place the glyph into the texture atlas.
struct RasterizedGlyph: Sendable {
    /// Raw pixel data in BGRA premultiplied alpha format (4 bytes per pixel).
    /// Both text and color emoji use the same BGRA layout (`.bgra8Unorm` atlas).
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
    nonisolated static let empty = RasterizedGlyph(
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

/// Glyph rasterizer with a reusable scratch buffer and cached CGContext.
/// Each caller site should own or create a GlyphRasterizer instance to amortize
/// buffer allocations across multiple rasterize() calls.
///
/// Not thread-safe — each thread/task should use its own instance.
/// All methods are nonisolated to allow use from any isolation domain.
final class GlyphRasterizer: @unchecked Sendable {
    private nonisolated static let deviceRGBColorSpace = CGColorSpaceCreateDeviceRGB()

    // MARK: - Scratch Buffer State

    private nonisolated(unsafe) var scratchBuffer: UnsafeMutableRawPointer?
    private nonisolated(unsafe) var scratchBufferSize: Int = 0
    private nonisolated(unsafe) var scratchContext: CGContext?
    private nonisolated(unsafe) var scratchContextWidth: Int = 0
    private nonisolated(unsafe) var scratchContextHeight: Int = 0

    nonisolated init() {}

    deinit {
        if let buffer = scratchBuffer {
            buffer.deallocate()
        }
    }

    // MARK: - Scratch Buffer Management

    private nonisolated func ensureScratchBuffer(width: Int, height: Int) -> CGContext? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bufferSize = bytesPerRow * height

        // Reuse existing context if dimensions match
        if let ctx = scratchContext,
           scratchContextWidth == width,
           scratchContextHeight == height,
           scratchBufferSize >= bufferSize,
           let buffer = scratchBuffer {
            // Zero-fill the reused buffer
            memset(buffer, 0, bufferSize)
            return ctx
        }

        // Need to (re)allocate
        if let oldBuffer = scratchBuffer {
            oldBuffer.deallocate()
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        memset(buffer, 0, bufferSize)
        scratchBuffer = buffer
        scratchBufferSize = bufferSize

        let colorSpace = Self.deviceRGBColorSpace
        // Unified BGRA format for both text and color emoji — matches .bgra8Unorm atlas
        let bitmapInfo: UInt32 = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            scratchContext = nil
            scratchContextWidth = 0
            scratchContextHeight = 0
            return nil
        }

        scratchContext = ctx
        scratchContextWidth = width
        scratchContextHeight = height
        return ctx
    }

    // MARK: - B.2.1 Primary Rasterization Entry Point

    /// Rasterize a single Unicode codepoint using the given font and cell dimensions.
    ///
    /// - Parameters:
    ///   - codepoint: The Unicode scalar value to rasterize.
    ///   - font: The CTFont to use for rendering. Should already have the desired size applied.
    ///   - cellWidth: Width of a single terminal cell in pixels (from FontManager).
    ///   - cellHeight: Height of a single terminal cell in pixels (from FontManager).
    /// - Returns: A `RasterizedGlyph` containing the rendered pixel data and metrics.
    nonisolated func rasterize(
        codepoint: UnicodeScalar,
        font: CTFont,
        cellWidth: Int,
        cellHeight: Int
    ) -> RasterizedGlyph {
        let isColor = Self.isColorGlyph(codepoint: codepoint, font: font)
        let isWide = Self.isWideCharacter(codepoint: codepoint)

        let rasterWidth = isWide ? cellWidth * 2 : cellWidth
        let rasterHeight = cellHeight

        guard rasterWidth > 0 && rasterHeight > 0 else {
            return .empty
        }

        // Fast path: for non-emoji single codepoints, use CTFontDrawGlyphs directly.
        // This bypasses NSAttributedString + CTLine creation overhead (~99% of glyphs).
        if !isColor {
            let v = codepoint.value
            var glyphs: [CGGlyph]
            var found: Bool

            if v <= 0xFFFF {
                // BMP: single UniChar
                var char = UniChar(v)
                var glyph: CGGlyph = 0
                found = CTFontGetGlyphsForCharacters(font, &char, &glyph, 1)
                glyphs = [glyph]
            } else {
                // Supplementary: UTF-16 surrogate pair
                let hi = UniChar(0xD800 + ((v - 0x10000) >> 10))
                let lo = UniChar(0xDC00 + ((v - 0x10000) & 0x3FF))
                var chars: [UniChar] = [hi, lo]
                var glyphPair: [CGGlyph] = [0, 0]
                found = CTFontGetGlyphsForCharacters(font, &chars, &glyphPair, 2)
                glyphs = [glyphPair[0]]
            }

            if found && glyphs[0] != 0 {
                return rasterizeWithDirectDraw(
                    glyph: glyphs[0], font: font,
                    rasterWidth: rasterWidth, rasterHeight: rasterHeight,
                    isWide: isWide
                )
            }
            // Fall through to CTLine path if font doesn't have the glyph
        }

        // Slow path: CTLine-based rendering for emoji and fallback cases.
        return rasterizeWithCTLine(
            codepoint: codepoint, font: font,
            rasterWidth: rasterWidth, rasterHeight: rasterHeight,
            isColor: isColor, isWide: isWide
        )
    }

    // MARK: - Fast Path: Direct CTFontDrawGlyphs

    /// Rasterize a single glyph using CTFontDrawGlyphs — no NSAttributedString or CTLine overhead.
    private nonisolated func rasterizeWithDirectDraw(
        glyph: CGGlyph,
        font: CTFont,
        rasterWidth: Int,
        rasterHeight: Int,
        isWide: Bool
    ) -> RasterizedGlyph {
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

        guard let context = ensureScratchBuffer(width: rasterWidth, height: rasterHeight) else {
            return .empty
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        context.setShouldSmoothFonts(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setShouldSubpixelQuantizeFonts(false)

        var glyphBuf = glyph
        var position = CGPoint(x: 0, y: penY)
        CTFontDrawGlyphs(font, &glyphBuf, &position, 1, context)

        // Compute bearing from glyph bounding rect
        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyphBuf, &boundingRect, 1)

        let bearingX: Int
        let bearingY: Int
        if boundingRect.isEmpty {
            bearingX = 0
            bearingY = 0
        } else {
            bearingX = Int(floor(boundingRect.origin.x))
            bearingY = Int(ceil(boundingRect.origin.y + boundingRect.size.height))
        }

        // Copy pixel data out
        let bytesPerPixel = 4
        let bufferSize = rasterWidth * bytesPerPixel * rasterHeight
        guard let buffer = scratchBuffer else { return .empty }
        let pixelData = [UInt8](unsafeUninitializedCapacity: bufferSize) { destPtr, initializedCount in
            memcpy(destPtr.baseAddress!, buffer, bufferSize)
            initializedCount = bufferSize
        }

        return RasterizedGlyph(
            pixelData: pixelData,
            width: rasterWidth,
            height: rasterHeight,
            bearingX: bearingX,
            bearingY: bearingY,
            isColor: false,
            isWide: isWide
        )
    }

    // MARK: - Slow Path: CTLine-based Rendering

    /// Rasterize using NSAttributedString + CTLine. Used for color emoji and fallback cases.
    private nonisolated func rasterizeWithCTLine(
        codepoint: UnicodeScalar,
        font: CTFont,
        rasterWidth: Int,
        rasterHeight: Int,
        isColor: Bool,
        isWide: Bool
    ) -> RasterizedGlyph {
        let string = String(codepoint)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let attrString = NSAttributedString(string: string, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let imageBounds = CTLineGetImageBounds(line, nil)

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

        guard let context = ensureScratchBuffer(width: rasterWidth, height: rasterHeight) else {
            return .empty
        }

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

        context.textPosition = CGPoint(x: 0, y: penY)
        CTLineDraw(line, context)

        let bytesPerPixel = 4
        let bufferSize = rasterWidth * bytesPerPixel * rasterHeight
        let pixelData: [UInt8]
        if let buffer = scratchBuffer {
            pixelData = [UInt8](unsafeUninitializedCapacity: bufferSize) { destPtr, initializedCount in
                memcpy(destPtr.baseAddress!, buffer, bufferSize)
                initializedCount = bufferSize
            }
        } else {
            return .empty
        }

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
            pixelData: pixelData,
            width: rasterWidth,
            height: rasterHeight,
            bearingX: bearingX,
            bearingY: bearingY,
            isColor: isColor,
            isWide: isWide
        )
    }

    // MARK: - B.2.3 Color Emoji Detection

    private nonisolated static func isColorGlyph(codepoint: UnicodeScalar, font: CTFont) -> Bool {
        if isEmojiCodepoint(codepoint) {
            return true
        }

        let traits = CTFontGetSymbolicTraits(font)
        let hasColorGlyphs = traits.contains(.traitColorGlyphs)

        if hasColorGlyphs {
            var glyph: CGGlyph = 0
            var char = UInt16(truncatingIfNeeded: codepoint.value)

            if codepoint.value <= 0xFFFF {
                let found = CTFontGetGlyphsForCharacters(font, &char, &glyph, 1)
                return found && glyph != 0
            }
        }

        return false
    }

    private nonisolated static func isEmojiCodepoint(_ scalar: UnicodeScalar) -> Bool {
        UnicodeClassification.isEmojiScalar(scalar)
    }

    // MARK: - B.2.4 Wide Character Detection

    private nonisolated static func isWideCharacter(codepoint: UnicodeScalar) -> Bool {
        CharacterWidth.isWide(codepoint)
    }

    // MARK: - Grapheme Cluster Rasterization

    /// Rasterize a full grapheme cluster (which may contain multiple codepoints)
    /// into a pixel buffer.
    nonisolated func rasterize(
        graphemeCluster: String,
        font: CTFont,
        cellWidth: Int,
        cellHeight: Int,
        isWide: Bool
    ) -> RasterizedGlyph {
        guard !graphemeCluster.isEmpty else {
            return .empty
        }

        let scalars = graphemeCluster.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first {
            return rasterize(
                codepoint: scalar,
                font: font,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            )
        }

        let isColor = graphemeCluster.unicodeScalars.contains { Self.isEmojiCodepoint($0) }

        let rasterWidth = isWide ? cellWidth * 2 : cellWidth
        let rasterHeight = cellHeight

        guard rasterWidth > 0 && rasterHeight > 0 else {
            return .empty
        }

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let attrString = NSAttributedString(string: graphemeCluster, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)

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

        guard let context = ensureScratchBuffer(width: rasterWidth, height: rasterHeight) else {
            return .empty
        }

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

        // Copy pixel data out of scratch buffer
        let bytesPerPixel = 4
        let bufferSize = rasterWidth * bytesPerPixel * rasterHeight
        let pixelData: [UInt8]
        if let buffer = scratchBuffer {
            pixelData = [UInt8](unsafeUninitializedCapacity: bufferSize) { destPtr, initializedCount in
                memcpy(destPtr.baseAddress!, buffer, bufferSize)
                initializedCount = bufferSize
            }
        } else {
            return .empty
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
            pixelData: pixelData,
            width: rasterWidth,
            height: rasterHeight,
            bearingX: bearingX,
            bearingY: bearingY,
            isColor: isColor,
            isWide: isWide
        )
    }
}
