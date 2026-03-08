import XCTest
@testable import ProSSHMac

final class GlyphIndexPackingTests: XCTestCase {

    func testPackingPreservesAtlasPageAndCoordinates() {
        let entry = AtlasEntry(
            atlasPage: 7,
            x: 1024,
            y: 1536,
            width: 16,
            bearingX: 0,
            bearingY: 0
        )

        let packed = GlyphIndexPacking.pack(entry)
        let unpacked = GlyphIndexPacking.unpack(packed)

        XCTAssertEqual(unpacked?.atlasPage, entry.atlasPage)
        XCTAssertEqual(unpacked?.x, entry.x)
        XCTAssertEqual(unpacked?.y, entry.y)
    }

    func testPackingDiffersAcrossAtlasPagesForSameCoordinates() {
        let first = AtlasEntry(
            atlasPage: 0,
            x: 128,
            y: 256,
            width: 16,
            bearingX: 0,
            bearingY: 0
        )
        let second = AtlasEntry(
            atlasPage: 1,
            x: 128,
            y: 256,
            width: 16,
            bearingX: 0,
            bearingY: 0
        )

        XCTAssertNotEqual(GlyphIndexPacking.pack(first), GlyphIndexPacking.pack(second))
    }

    func testUnpackReturnsNilForNoGlyphSentinel() {
        XCTAssertNil(GlyphIndexPacking.unpack(MetalTerminalRenderer.noGlyphIndex))
    }
}
