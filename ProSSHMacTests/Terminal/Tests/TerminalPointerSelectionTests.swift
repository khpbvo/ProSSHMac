// TerminalPointerSelectionTests.swift
// ProSSHMac
//
// A click must never leave a selection behind, however little the pointer wobbles while it is
// pressed; only a drag that leaves its start cell selects. See Docs/bugs.md Bug 85.

#if canImport(XCTest)
import XCTest
import AppKit
import MetalKit
@testable import ProSSHMac

private let cell = SelectionPoint(row: 2, col: 25)
private let otherCell = SelectionPoint(row: 2, col: 31)

final class TerminalPointerSelectionTests: XCTestCase {

    // MARK: - Tracker

    @MainActor
    func testSingleClickClearsSelection() {
        var tracker = TerminalPointerSelection()
        XCTAssertEqual(tracker.mouseDown(at: cell, clickCount: 1), .clear)
        XCTAssertEqual(tracker.mouseUp(), .none)
    }

    /// Bug 85: a trackpad click reports sub-pixel drags that stay in the clicked cell.
    @MainActor
    func testClickThatWobblesInsideItsCellSelectsNothing() {
        var tracker = TerminalPointerSelection()
        XCTAssertEqual(tracker.mouseDown(at: cell, clickCount: 1), .clear)
        XCTAssertEqual(tracker.mouseDragged(to: cell), .none)
        XCTAssertEqual(tracker.mouseDragged(to: cell), .none)
        XCTAssertEqual(tracker.mouseUp(), .none)
    }

    @MainActor
    func testDragThatLeavesItsStartCellSelectsTheRange() {
        var tracker = TerminalPointerSelection()
        _ = tracker.mouseDown(at: cell, clickCount: 1)
        XCTAssertEqual(
            tracker.mouseDragged(to: otherCell),
            .select(start: cell, end: otherCell, type: .character)
        )
        // Once a drag has started, coming back to the start cell keeps selecting.
        XCTAssertEqual(
            tracker.mouseDragged(to: cell),
            .select(start: cell, end: cell, type: .character)
        )
        XCTAssertEqual(tracker.mouseUp(), .none)
    }

    @MainActor
    func testDoubleClickSelectsWordAndDragExtendsByWord() {
        var tracker = TerminalPointerSelection()
        _ = tracker.mouseDown(at: cell, clickCount: 1)
        _ = tracker.mouseUp()
        XCTAssertEqual(
            tracker.mouseDown(at: cell, clickCount: 2),
            .select(start: cell, end: cell, type: .word)
        )
        XCTAssertEqual(
            tracker.mouseDragged(to: otherCell),
            .select(start: cell, end: otherCell, type: .word)
        )
    }

    @MainActor
    func testTripleClickSelectsLine() {
        var tracker = TerminalPointerSelection()
        XCTAssertEqual(
            tracker.mouseDown(at: cell, clickCount: 3),
            .select(start: cell, end: cell, type: .line)
        )
        XCTAssertEqual(
            tracker.mouseDragged(to: otherCell),
            .select(start: cell, end: otherCell, type: .line)
        )
    }

    @MainActor
    func testDragAfterMouseUpIsIgnored() {
        var tracker = TerminalPointerSelection()
        _ = tracker.mouseDown(at: cell, clickCount: 1)
        _ = tracker.mouseUp()
        XCTAssertEqual(tracker.mouseDragged(to: otherCell), .none)
    }

    @MainActor
    func testMouseDownOutsideTheGridStillClearsButStartsNoDrag() {
        var tracker = TerminalPointerSelection()
        XCTAssertEqual(tracker.mouseDown(at: nil, clickCount: 1), .clear)
        XCTAssertEqual(tracker.mouseDragged(to: otherCell), .none)
    }

    // MARK: - Model

    @MainActor
    func testClickWithSubCellMovementLeavesNoSelectionOnTheRenderer() throws {
        let model = MetalTerminalSurfaceModel()
        let renderer = try XCTUnwrap(model.renderer)
        renderer.setSelection(start: cell, end: otherCell, type: .character)

        model.handleMouseDown(at: cell, clickCount: 1)
        model.handleMouseDragged(to: cell)
        model.handleMouseUp()

        XCTAssertFalse(model.hasSelection)
    }

    @MainActor
    func testDragAcrossCellsSelectsOnTheRenderer() throws {
        let model = MetalTerminalSurfaceModel()

        model.handleMouseDown(at: cell, clickCount: 1)
        model.handleMouseDragged(to: otherCell)
        model.handleMouseUp()

        XCTAssertTrue(model.hasSelection)
    }

    // MARK: - View

    /// The view forwards AppKit's click count rather than running its own click recognizers.
    @MainActor
    func testMetalViewForwardsMouseEventsWithClickCount() throws {
        let view = TerminalMTKView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view

        var events: [String] = []
        view.onMouseDown = { point, clickCount in events.append("down \(Int(point.x)),\(Int(point.y)) x\(clickCount)") }
        view.onMouseDragged = { point in events.append("drag \(Int(point.x)),\(Int(point.y))") }
        view.onMouseUp = { events.append("up") }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 50), clickCount: 2, in: window))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 140, y: 50), clickCount: 2, in: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 140, y: 50), clickCount: 2, in: window))

        XCTAssertEqual(events, ["down 100,50 x2", "drag 140,50", "up"])
        XCTAssertTrue(view.gestureRecognizers.isEmpty, "Gesture recognizers would compete with clicks again")
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        clickCount: Int,
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}
#endif
