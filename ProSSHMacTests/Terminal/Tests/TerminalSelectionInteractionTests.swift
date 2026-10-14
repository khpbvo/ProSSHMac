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

        model.handleMouseDown(at: SelectionPoint(row: 0, col: 0), clickCount: 1)

        XCTAssertFalse(model.hasSelection)
    }

    /// A layout change rebuilds the surface view: SwiftUI attaches the new view before the old one
    /// disappears. The old view's detach must leave the selection reachable for copy (Bug 81).
    func testReplacedSurfaceDetachingKeepsTheSelectionReachable() throws {
        let store = TerminalSurfaceModelStore()
        let sessionID = UUID()
        let model = store.model(for: sessionID)
        try selectText("hello", in: model)

        let (oldSurface, newSurface) = (UUID(), UUID())
        model.attach(surface: oldSurface)
        model.attach(surface: newSurface)
        XCTAssertFalse(model.detach(surface: oldSurface))

        let found = try XCTUnwrap(store.existingModel(for: sessionID))
        XCTAssertTrue(found === model)
        XCTAssertTrue(found.hasSelection)
        XCTAssertEqual(found.copySelection(), "hello")
    }

    func testReleasedSessionHasNoSelectionToCopy() throws {
        let store = TerminalSurfaceModelStore()
        let sessionID = UUID()
        try selectText("hello", in: store.model(for: sessionID))
        XCTAssertEqual(store.existingModel(for: sessionID)?.copySelection(), "hello")

        store.release(sessionID: sessionID)

        XCTAssertNil(store.existingModel(for: sessionID))
    }

    /// A session shown in two panes has a model per pane; copy must read the targeted pane's.
    func testDuplicatePaneCopiesItsOwnSelection() throws {
        let store = TerminalSurfaceModelStore()
        let (sessionID, laterPane) = (UUID(), UUID())
        try selectText("aaa", in: store.model(for: sessionID))
        try selectText("bbb", in: store.model(for: sessionID, duplicateInPane: laterPane))

        XCTAssertEqual(store.existingModel(for: sessionID)?.copySelection(), "aaa")
        XCTAssertEqual(store.existingModel(for: sessionID, duplicateInPane: laterPane)?.copySelection(), "bbb")
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
