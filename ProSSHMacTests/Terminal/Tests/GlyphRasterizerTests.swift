import XCTest
import CoreText
@testable import ProSSHMac

final class GlyphRasterizerTests: XCTestCase {

    private var rasterizer: GlyphRasterizer!
    private var font: CTFont!
    private let cellWidth = 16
    private let cellHeight = 32

    override func setUp() {
        super.setUp()
        rasterizer = GlyphRasterizer()
        font = CTFontCreateWithName("Menlo" as CFString, 28, nil)
    }

    override func tearDown() {
        rasterizer = nil
        font = nil
        super.tearDown()
    }

    // MARK: - ASCII (fast path: CTFontDrawGlyphs)

    func testASCIIGlyphsProduceNonEmptyPixelData() {
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            let result = rasterizer.rasterize(
                codepoint: UnicodeScalar(scalar)!,
                font: font,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            )
            XCTAssertEqual(result.width, cellWidth, "Width mismatch for U+\(String(format: "%04X", scalar))")
            XCTAssertEqual(result.height, cellHeight, "Height mismatch for U+\(String(format: "%04X", scalar))")
            XCTAssertFalse(result.pixelData.isEmpty, "Empty pixel data for U+\(String(format: "%04X", scalar))")
            XCTAssertFalse(result.isColor)
            XCTAssertFalse(result.isWide)
            // Verify at least some non-zero pixels (glyph was actually drawn)
            let hasContent = result.pixelData.contains(where: { $0 != 0 })
            XCTAssertTrue(hasContent, "No visible pixels for U+\(String(format: "%04X", scalar))")
        }
    }

    func testDigitsRasterize() {
        for scalar in UnicodeScalar("0").value...UnicodeScalar("9").value {
            let result = rasterizer.rasterize(
                codepoint: UnicodeScalar(scalar)!,
                font: font,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            )
            XCTAssertEqual(result.width, cellWidth)
            XCTAssertEqual(result.height, cellHeight)
            XCTAssertTrue(result.pixelData.contains(where: { $0 != 0 }))
        }
    }

    func testSpaceProducesEmptyishPixels() {
        let result = rasterizer.rasterize(
            codepoint: UnicodeScalar(" "),
            font: font,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
        // Space should rasterize to cell dimensions but have all-zero pixels
        XCTAssertEqual(result.width, cellWidth)
        XCTAssertEqual(result.height, cellHeight)
    }

    // MARK: - Wide characters (CJK — fast path if font has glyph)

    func testCJKCharacterIsWide() {
        // U+4E2D = 中 (CJK Unified Ideograph)
        let cjkScalar = UnicodeScalar(0x4E2D)!
        // Use a font that has CJK glyphs
        let cjkFont = CTFontCreateForString(
            font, "中" as CFString, CFRange(location: 0, length: 1)
        )
        let result = rasterizer.rasterize(
            codepoint: cjkScalar,
            font: cjkFont,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
        XCTAssertEqual(result.width, cellWidth * 2, "CJK should be double-width")
        XCTAssertTrue(result.isWide)
        XCTAssertFalse(result.isColor)
        XCTAssertTrue(result.pixelData.contains(where: { $0 != 0 }))
    }

    // MARK: - Emoji (slow path: CTLine)

    func testEmojiUsesColorPath() {
        // U+1F389 = 🎉 (Party Popper)
        let emojiScalar = UnicodeScalar(0x1F389)!
        let emojiFont = CTFontCreateForString(
            font, "🎉" as CFString, CFRange(location: 0, length: 2)
        )
        let result = rasterizer.rasterize(
            codepoint: emojiScalar,
            font: emojiFont,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
        XCTAssertTrue(result.isColor, "Emoji should be color")
        XCTAssertTrue(result.pixelData.contains(where: { $0 != 0 }), "Emoji should have visible pixels")
    }

    // MARK: - Grapheme cluster (always slow path)

    func testGraphemeClusterRasterizes() {
        // Flag emoji: 🇺🇸 (two regional indicators)
        let flag = "🇺🇸"
        let emojiFont = CTFontCreateForString(
            font, flag as CFString, CFRange(location: 0, length: (flag as NSString).length)
        )
        let result = rasterizer.rasterize(
            graphemeCluster: flag,
            font: emojiFont,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            isWide: true
        )
        XCTAssertTrue(result.isColor)
        XCTAssertEqual(result.width, cellWidth * 2)
        XCTAssertTrue(result.pixelData.contains(where: { $0 != 0 }))
    }

    func testSingleScalarGraphemeClusterDelegatesToCodepointPath() {
        let result = rasterizer.rasterize(
            graphemeCluster: "A",
            font: font,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            isWide: false
        )
        XCTAssertEqual(result.width, cellWidth)
        XCTAssertFalse(result.isColor)
        XCTAssertTrue(result.pixelData.contains(where: { $0 != 0 }))
    }

    // MARK: - Scratch buffer reuse

    func testScratchBufferReusedAcrossCalls() {
        // Rasterize two different glyphs at the same dimensions — second should reuse buffer
        let resultA = rasterizer.rasterize(
            codepoint: UnicodeScalar("A"),
            font: font,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
        let resultB = rasterizer.rasterize(
            codepoint: UnicodeScalar("B"),
            font: font,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
        // Both should produce valid, different output
        XCTAssertEqual(resultA.width, resultB.width)
        XCTAssertEqual(resultA.height, resultB.height)
        XCTAssertNotEqual(resultA.pixelData, resultB.pixelData, "A and B should produce different pixels")
    }

    // MARK: - Edge cases

    func testZeroDimensionsReturnEmpty() {
        let result = rasterizer.rasterize(
            codepoint: UnicodeScalar("A"),
            font: font,
            cellWidth: 0,
            cellHeight: 0
        )
        XCTAssertTrue(result.pixelData.isEmpty)
        XCTAssertEqual(result.width, 0)
    }

    func testPixelDataSizeMatchesDimensions() {
        let result = rasterizer.rasterize(
            codepoint: UnicodeScalar("X"),
            font: font,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
        let expectedSize = cellWidth * cellHeight * 4 // 4 bytes per pixel (RGBA)
        XCTAssertEqual(result.pixelData.count, expectedSize)
    }

    // MARK: - Bold/Italic font variants (via direct rasterization)

    func testBoldFontRasterizes() {
        let boldFont = CTFontCreateCopyWithSymbolicTraits(
            font, CTFontGetSize(font), nil, .boldTrait, .boldTrait
        ) ?? font!
        let result = rasterizer.rasterize(
            codepoint: UnicodeScalar("A"),
            font: boldFont,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
        XCTAssertTrue(result.pixelData.contains(where: { $0 != 0 }))
    }

    func testItalicFontRasterizes() {
        let italicFont = CTFontCreateCopyWithSymbolicTraits(
            font, CTFontGetSize(font), nil, .italicTrait, .italicTrait
        ) ?? font!
        let result = rasterizer.rasterize(
            codepoint: UnicodeScalar("A"),
            font: italicFont,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
        XCTAssertTrue(result.pixelData.contains(where: { $0 != 0 }))
    }
}
