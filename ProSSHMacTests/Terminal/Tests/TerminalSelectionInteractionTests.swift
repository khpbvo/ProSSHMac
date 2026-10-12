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

    /// A resize rebuilds the surface: SwiftUI runs the new surface's onAppear (register) before
    /// the old surface's onDisappear (unregister). The old surface must not remove the new one.
    func testReplacedSurfaceUnregisteringDoesNotRemoveItsReplacement() throws {
        let coordinator = TerminalSelectionCoordinator()
        let sessionID = UUID()
        let oldSurface = MetalTerminalSurfaceModel()
        let newSurface = MetalTerminalSurfaceModel()
        try selectText("hello", in: newSurface)

        coordinator.register(sessionID: sessionID, model: oldSurface)
        coordinator.register(sessionID: sessionID, model: newSurface)
        coordinator.unregister(sessionID: sessionID, model: oldSurface)

        XCTAssertTrue(coordinator.hasSelection(sessionID: sessionID))
        XCTAssertEqual(coordinator.copySelection(sessionID: sessionID), "hello")
        XCTAssertEqual(coordinator.copySelection(preferredSessionID: sessionID), "hello")
    }

    func testCurrentSurfaceUnregisteringRemovesIt() throws {
        let coordinator = TerminalSelectionCoordinator()
        let sessionID = UUID()
        let surface = MetalTerminalSurfaceModel()
        try selectText("hello", in: surface)

        coordinator.register(sessionID: sessionID, model: surface)
        XCTAssertEqual(coordinator.copySelection(sessionID: sessionID), "hello")

        coordinator.unregister(sessionID: sessionID, model: surface)

        XCTAssertFalse(coordinator.hasSelection(sessionID: sessionID))
        XCTAssertNil(coordinator.copySelection(sessionID: sessionID))
    }

    /// Gives the surface's renderer a one-row snapshot containing `text` and selects all of it.
    private func selectText(_ text: String, in model: MetalTerminalSurfaceModel) throws {
        let renderer = try XCTUnwrap(model.renderer)
        let scalars = Array(text.unicodeScalars)
        let cells = scalars.enumerated().map { col, scalar in
            CellInstance(
                row: 0,
                col: UInt16(col),
                glyphIndex: scalar.value,
                fgColor: 0,
                bgColor: 0,
                underlineColor: 0,
                attributes: 0,
                flags: 0,
                underlineStyle: 0
            )
        }
        model.apply(snapshot: GridSnapshot(
            cells: ContiguousArray(cells),
            dirtyRange: 0..<cells.count,
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: true,
            cursorStyle: .block,
            columns: cells.count,
            rows: 1,
            usingAlternateBuffer: false,
            graphemeOverrides: nil
        ))
        renderer.setSelection(
            start: SelectionPoint(row: 0, col: 0),
            end: SelectionPoint(row: 0, col: cells.count - 1),
            type: .character
        )
    }
}
#endif
