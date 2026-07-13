#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class TerminalSelectionInteractionTests: XCTestCase {

    func testPlainTapClearsActiveMetalSelection() throws {
        let model = MetalTerminalSurfaceModel()
        let renderer = try XCTUnwrap(model.renderer)

        renderer.setSelection(
            start: SelectionPoint(row: 1, col: 2),
            end: SelectionPoint(row: 1, col: 5),
            type: .character
        )
        XCTAssertTrue(model.hasSelection)

        model.handleTap()

        XCTAssertFalse(model.hasSelection)
    }
}
#endif
