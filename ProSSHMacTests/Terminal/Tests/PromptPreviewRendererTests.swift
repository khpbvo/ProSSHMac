#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class PromptPreviewRendererTests: XCTestCase {
    func testEmptyRainbowPaletteHasNoIndexedColor() {
        XCTAssertNil(PromptPreviewRenderer.rainbowColor(at: 0, in: []))
        XCTAssertNil(PromptPreviewRenderer.rainbowColor(at: 5, in: []))
    }

    func testRainbowPaletteCyclesAcrossUsername() {
        let red = GradientColor(red: 1, green: 0, blue: 0)
        let blue = GradientColor(red: 0, green: 0, blue: 1)
        XCTAssertEqual(PromptPreviewRenderer.rainbowColor(at: 0, in: [red, blue]), red)
        XCTAssertEqual(PromptPreviewRenderer.rainbowColor(at: 1, in: [red, blue]), blue)
        XCTAssertEqual(PromptPreviewRenderer.rainbowColor(at: 2, in: [red, blue]), red)
    }
}
#endif
