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
        if Self.isBlockElement(codepoint) {
            return rasterizeBlockElement(
                codepoint: codepoint,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            )
        }

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

    private nonisolated func rasterizeBlockElement(
        codepoint: UnicodeScalar,
        cellWidth: Int,
        cellHeight: Int
    ) -> RasterizedGlyph {
        guard cellWidth > 0, cellHeight > 0,
              let context = ensureScratchBuffer(width: cellWidth, height: cellHeight),
              let buffer = scratchBuffer else {
            return .empty
        }

        let byteCount = cellWidth * cellHeight * 4
        memset(buffer, 0, byteCount)
        context.clear(CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))

        let pixelBuffer = UnsafeMutableBufferPointer(
            start: buffer.assumingMemoryBound(to: UInt8.self),
            count: byteCount
        )

        func fillRect(
            xStartUnits: Int,
            xEndUnits: Int,
            xDivisions: Int,
            yStartUnits: Int,
            yEndUnits: Int,
            yDivisions: Int,
            alpha: UInt8 = 0xFF
        ) {
            let minX = scaledBoundary(xStartUnits, total: cellWidth, divisions: xDivisions)
            let maxX = scaledBoundary(xEndUnits, total: cellWidth, divisions: xDivisions)
            let minY = scaledBoundary(yStartUnits, total: cellHeight, divisions: yDivisions)
            let maxY = scaledBoundary(yEndUnits, total: cellHeight, divisions: yDivisions)
            fillBlockPixels(
                pixelBuffer,
                width: cellWidth,
                height: cellHeight,
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                alpha: alpha
            )
        }

        switch codepoint.value {
        case 0x2580: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 0, yEndUnits: 4, yDivisions: 8)
        case 0x2581: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 7, yEndUnits: 8, yDivisions: 8)
        case 0x2582: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 6, yEndUnits: 8, yDivisions: 8)
        case 0x2583: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 5, yEndUnits: 8, yDivisions: 8)
        case 0x2584: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 4, yEndUnits: 8, yDivisions: 8)
        case 0x2585: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 3, yEndUnits: 8, yDivisions: 8)
        case 0x2586: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 2, yEndUnits: 8, yDivisions: 8)
        case 0x2587: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 1, yEndUnits: 8, yDivisions: 8)
        case 0x2588: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8)
        case 0x2589: fillRect(xStartUnits: 0, xEndUnits: 7, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8)
        case 0x258A: fillRect(xStartUnits: 0, xEndUnits: 6, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8)
        case 0x258B: fillRect(xStartUnits: 0, xEndUnits: 5, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8)
        case 0x258C: fillRect(xStartUnits: 0, xEndUnits: 4, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8)
        case 0x258D: fillRect(xStartUnits: 0, xEndUnits: 3, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8)
        case 0x258E: fillRect(xStartUnits: 0, xEndUnits: 2, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8)
        case 0x258F: fillRect(xStartUnits: 0, xEndUnits: 1, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8)
        case 0x2590: fillRect(xStartUnits: 4, xEndUnits: 8, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8)
        case 0x2591: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8, alpha: 0x40)
        case 0x2592: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8, alpha: 0x80)
        case 0x2593: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8, alpha: 0xC0)
        case 0x2594: fillRect(xStartUnits: 0, xEndUnits: 8, xDivisions: 8, yStartUnits: 0, yEndUnits: 1, yDivisions: 8)
        case 0x2595: fillRect(xStartUnits: 7, xEndUnits: 8, xDivisions: 8, yStartUnits: 0, yEndUnits: 8, yDivisions: 8)
        case 0x2596:
            fillQuadrants(pixelBuffer, width: cellWidth, height: cellHeight, mask: Self.quadrantBottomLeft)
        case 0x2597:
            fillQuadrants(pixelBuffer, width: cellWidth, height: cellHeight, mask: Self.quadrantBottomRight)
        case 0x2598:
            fillQuadrants(pixelBuffer, width: cellWidth, height: cellHeight, mask: Self.quadrantTopLeft)
        case 0x2599:
            fillQuadrants(pixelBuffer, width: cellWidth, height: cellHeight, mask: Self.quadrantTopLeft | Self.quadrantBottomLeft | Self.quadrantBottomRight)
        case 0x259A:
            fillQuadrants(pixelBuffer, width: cellWidth, height: cellHeight, mask: Self.quadrantTopLeft | Self.quadrantBottomRight)
        case 0x259B:
            fillQuadrants(pixelBuffer, width: cellWidth, height: cellHeight, mask: Self.quadrantTopLeft | Self.quadrantTopRight | Self.quadrantBottomLeft)
        case 0x259C:
            fillQuadrants(pixelBuffer, width: cellWidth, height: cellHeight, mask: Self.quadrantTopLeft | Self.quadrantTopRight | Self.quadrantBottomRight)
        case 0x259D:
            fillQuadrants(pixelBuffer, width: cellWidth, height: cellHeight, mask: Self.quadrantTopRight)
        case 0x259E:
            fillQuadrants(pixelBuffer, width: cellWidth, height: cellHeight, mask: Self.quadrantTopRight | Self.quadrantBottomLeft | Self.quadrantBottomRight)
        case 0x259F:
            fillQuadrants(pixelBuffer, width: cellWidth, height: cellHeight, mask: Self.quadrantTopRight | Self.quadrantBottomLeft)
        default:
            break
        }

        let pixelData = [UInt8](unsafeUninitializedCapacity: byteCount) { destPtr, initializedCount in
            memcpy(destPtr.baseAddress!, buffer, byteCount)
            initializedCount = byteCount
        }

        return RasterizedGlyph(
            pixelData: pixelData,
            width: cellWidth,
            height: cellHeight,
            bearingX: 0,
            bearingY: 0,
            isColor: false,
            isWide: false
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

    private nonisolated static func isBlockElement(_ scalar: UnicodeScalar) -> Bool {
        (0x2580...0x259F).contains(scalar.value)
    }

    private nonisolated static func isWideCharacter(codepoint: UnicodeScalar) -> Bool {
        CharacterWidth.isWide(codepoint)
    }

    private nonisolated static let quadrantTopLeft = 1 << 0
    private nonisolated static let quadrantTopRight = 1 << 1
    private nonisolated static let quadrantBottomLeft = 1 << 2
    private nonisolated static let quadrantBottomRight = 1 << 3

    private nonisolated func fillQuadrants(
        _ pixelBuffer: UnsafeMutableBufferPointer<UInt8>,
        width: Int,
        height: Int,
        mask: Int
    ) {
        let xMid = scaledBoundary(1, total: width, divisions: 2)
        let yMid = scaledBoundary(1, total: height, divisions: 2)

        if (mask & Self.quadrantTopLeft) != 0 {
            fillBlockPixels(pixelBuffer, width: width, height: height, minX: 0, maxX: xMid, minY: 0, maxY: yMid)
        }
        if (mask & Self.quadrantTopRight) != 0 {
            fillBlockPixels(pixelBuffer, width: width, height: height, minX: xMid, maxX: width, minY: 0, maxY: yMid)
        }
        if (mask & Self.quadrantBottomLeft) != 0 {
            fillBlockPixels(pixelBuffer, width: width, height: height, minX: 0, maxX: xMid, minY: yMid, maxY: height)
        }
        if (mask & Self.quadrantBottomRight) != 0 {
            fillBlockPixels(pixelBuffer, width: width, height: height, minX: xMid, maxX: width, minY: yMid, maxY: height)
        }
    }

    private nonisolated func scaledBoundary(_ value: Int, total: Int, divisions: Int) -> Int {
        guard divisions > 0 else { return 0 }
        let scaled = (Double(value) * Double(total) / Double(divisions)).rounded()
        return min(max(Int(scaled), 0), total)
    }

    private nonisolated func fillBlockPixels(
        _ pixelBuffer: UnsafeMutableBufferPointer<UInt8>,
        width: Int,
        height: Int,
        minX: Int,
        maxX: Int,
        minY: Int,
        maxY: Int,
        alpha: UInt8 = 0xFF
    ) {
        guard width > 0, height > 0, minX < maxX, minY < maxY else { return }

        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = ((y * width) + x) * 4
                pixelBuffer[offset + 0] = alpha
                pixelBuffer[offset + 1] = alpha
                pixelBuffer[offset + 2] = alpha
                pixelBuffer[offset + 3] = alpha
            }
        }
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
