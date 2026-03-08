#if canImport(XCTest)
import XCTest
import AppKit
@testable import ProSSHMac

final class MouseInputCaptureViewTests: XCTestCase {

    func testViewportScrollAccumulatorBatchesPreciseWheelDeltasIntoLines() {
        let view = MouseInputCaptureView(frame: .zero)

        XCTAssertEqual(
            view.consumeViewportScrollDelta(4, hasPreciseScrollingDeltas: true),
            0
        )
        XCTAssertEqual(
            view.consumeViewportScrollDelta(4, hasPreciseScrollingDeltas: true),
            1
        )
        XCTAssertEqual(
            view.consumeViewportScrollDelta(-16, hasPreciseScrollingDeltas: true),
            -2
        )
    }

    func testViewportScrollAccumulatorResetsWhenGestureEnds() {
        let view = MouseInputCaptureView(frame: .zero)

        XCTAssertEqual(
            view.consumeViewportScrollDelta(6, hasPreciseScrollingDeltas: true),
            0
        )
        XCTAssertEqual(
            view.consumeViewportScrollDelta(
                0,
                hasPreciseScrollingDeltas: true,
                phase: .ended
            ),
            0
        )
        XCTAssertEqual(
            view.consumeViewportScrollDelta(4, hasPreciseScrollingDeltas: true),
            0
        )
    }
}
#endif
