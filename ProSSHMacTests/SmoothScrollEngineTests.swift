import XCTest
@testable import ProSSHMac

final class SmoothScrollEngineTests: XCTestCase {

    private let cellHeight: CGFloat = 20.0

    // MARK: - scrollDelta & row extraction

    func testScrollDeltaFiresCallbackAtRowBoundary() {
        let engine = SmoothScrollEngine()
        var firedDeltas: [Int] = []
        engine.onScrollLineChange = { delta in firedDeltas.append(delta) }

        // Feed enough delta to cross one row boundary (cellHeight = 20, so 20 points = 1 row)
        engine.scrollDelta(20.0, cellHeight: cellHeight)

        XCTAssertEqual(firedDeltas, [1], "Should fire callback with +1 row delta")
        XCTAssertEqual(engine.targetScrollRow, 1)
    }

    func testScrollDeltaNegativeDirection() {
        let engine = SmoothScrollEngine()
        var firedDeltas: [Int] = []
        engine.onScrollLineChange = { delta in firedDeltas.append(delta) }

        engine.scrollDelta(-40.0, cellHeight: cellHeight)

        XCTAssertEqual(firedDeltas, [-2], "Should fire callback with -2 row delta")
        XCTAssertEqual(engine.targetScrollRow, -2)
    }

    func testFractionalRemainderPreserved() {
        let engine = SmoothScrollEngine()
        var callCount = 0
        engine.onScrollLineChange = { _ in callCount += 1 }

        // Feed 15 points = 0.75 rows — should NOT fire callback
        engine.scrollDelta(15.0, cellHeight: cellHeight)
        XCTAssertEqual(callCount, 0, "Should not fire for sub-row delta")
        XCTAssertEqual(engine.targetScrollRow, 0)

        // Feed another 10 points = total 1.25 rows — should fire once, keep 0.25 remainder
        engine.scrollDelta(10.0, cellHeight: cellHeight)
        XCTAssertEqual(callCount, 1, "Should fire once after crossing row boundary")
        XCTAssertEqual(engine.targetScrollRow, 1)
    }

    func testSlowGestureAccumulatesAcrossFramesWithoutBleedingOff() {
        let engine = SmoothScrollEngine()
        var firedDeltas: [Int] = []
        engine.onScrollLineChange = { delta in firedDeltas.append(delta) }

        engine.beginGesture()

        engine.scrollDelta(5.0, cellHeight: cellHeight) // 0.25 rows
        _ = engine.frame(cellHeight: cellHeight, time: 1.0)
        engine.scrollDelta(5.0, cellHeight: cellHeight) // total 0.50 rows
        _ = engine.frame(cellHeight: cellHeight, time: 1.0 + 1.0 / 60.0)
        engine.scrollDelta(10.0, cellHeight: cellHeight) // total 1.0 rows

        XCTAssertEqual(firedDeltas, [1], "Slow gesture input should accumulate across frames")
        XCTAssertEqual(engine.targetScrollRow, 1, "Slow gesture should still advance by one row")
    }

    // MARK: - Momentum decay

    func testMomentumDecayConvergesToZero() {
        let engine = SmoothScrollEngine()

        // Feed some deltas to build velocity
        for _ in 0..<5 {
            engine.scrollDelta(10.0, cellHeight: cellHeight)
        }

        engine.beginMomentum()

        // Run enough frames for momentum to decay
        var lastAnimating = true
        var time = 1.0
        for _ in 0..<500 {
            let frame = engine.frame(cellHeight: cellHeight, time: time)
            time += 1.0 / 60.0
            lastAnimating = frame.isAnimating
            if !lastAnimating { break }
        }

        XCTAssertFalse(lastAnimating, "Momentum should decay and stop animating")
        XCTAssertFalse(engine.requiresContinuousFrames(), "Should not require frames after momentum ends")
    }

    // MARK: - Spring-back

    func testSpringBackConvergesToZero() {
        let engine = SmoothScrollEngine()

        // Feed a sub-row delta to create a fractional offset
        engine.scrollDelta(10.0, cellHeight: cellHeight) // 0.5 rows

        // Run frames without momentum — spring should snap back
        var lastOffset: Float = .greatestFiniteMagnitude
        var time = 1.0
        for _ in 0..<200 {
            let frame = engine.frame(cellHeight: cellHeight, time: time)
            time += 1.0 / 60.0
            lastOffset = frame.offsetPixels
            if !frame.isAnimating { break }
        }

        XCTAssertEqual(lastOffset, 0.0, accuracy: 0.01, "Spring-back should converge to zero")
        XCTAssertFalse(engine.requiresContinuousFrames(), "Should not require frames after spring-back")
    }

    func testGestureEndRestoresSpringBack() {
        let engine = SmoothScrollEngine()

        engine.beginGesture()
        engine.scrollDelta(10.0, cellHeight: cellHeight) // 0.5 rows

        let activeFrame = engine.frame(cellHeight: cellHeight, time: 1.0)
        XCTAssertGreaterThan(abs(activeFrame.offsetPixels), 0.01, "Active gesture should preserve fractional offset")

        engine.endGesture()

        var lastOffset = activeFrame.offsetPixels
        var time = 1.0
        for _ in 0..<200 {
            time += 1.0 / 60.0
            let frame = engine.frame(cellHeight: cellHeight, time: time)
            lastOffset = frame.offsetPixels
            if !frame.isAnimating { break }
        }

        XCTAssertEqual(lastOffset, 0.0, accuracy: 0.01, "Offset should spring back after gesture ends")
    }

    // MARK: - Velocity clamping

    func testVelocityClampedToMaxVelocity() {
        let engine = SmoothScrollEngine()
        // Set a low max velocity config
        var config = SmoothScrollConfiguration.default
        config.maxVelocity = 2.0
        engine.reloadConfiguration(config)

        // Feed a huge delta
        engine.scrollDelta(10000.0, cellHeight: cellHeight)

        // Start momentum and check that velocity is bounded
        engine.beginMomentum()
        let frame = engine.frame(cellHeight: cellHeight, time: 1.0)

        // The offset per frame should be bounded — offset can't exceed 1.5 * cellHeight due to clamp
        XCTAssertLessThanOrEqual(abs(frame.offsetPixels), 1.5 * Float(cellHeight) + 1.0,
                                 "Offset should be clamped")
    }

    // MARK: - requiresContinuousFrames

    func testRequiresContinuousFramesReturnsFalseWhenIdle() {
        let engine = SmoothScrollEngine()
        XCTAssertFalse(engine.requiresContinuousFrames(), "Idle engine should not need continuous frames")
    }

    func testRequiresContinuousFramesDuringMomentum() {
        let engine = SmoothScrollEngine()
        engine.scrollDelta(10.0, cellHeight: cellHeight)
        engine.beginMomentum()
        XCTAssertTrue(engine.requiresContinuousFrames(), "Should require frames during momentum")
    }

    func testRequiresContinuousFramesDuringSpringBack() {
        let engine = SmoothScrollEngine()
        engine.scrollDelta(10.0, cellHeight: cellHeight) // 0.5 rows fractional
        // Not in momentum, but has fractional offset
        XCTAssertTrue(engine.requiresContinuousFrames(), "Should require frames during spring-back")
    }

    // MARK: - Configuration reload

    func testReloadConfigurationUpdatesPhysics() {
        let engine = SmoothScrollEngine()

        var config = SmoothScrollConfiguration.default
        config.momentumEnabled = false
        engine.reloadConfiguration(config)

        engine.scrollDelta(10.0, cellHeight: cellHeight)
        engine.beginMomentum()

        // With momentum disabled, beginMomentum should have no effect
        // The engine should only spring-back, not carry momentum
        // After spring-back, it should stop
        var stopped = false
        var time = 1.0
        for _ in 0..<200 {
            let frame = engine.frame(cellHeight: cellHeight, time: time)
            time += 1.0 / 60.0
            if !frame.isAnimating {
                stopped = true
                break
            }
        }

        XCTAssertTrue(stopped, "With momentum disabled, animation should stop after spring-back")
    }

    // MARK: - Zero cell height guard

    func testZeroCellHeightDoesNotCrash() {
        let engine = SmoothScrollEngine()
        engine.scrollDelta(10.0, cellHeight: 0.0)
        let frame = engine.frame(cellHeight: 0.0, time: 1.0)
        XCTAssertEqual(frame.offsetPixels, 0.0, "Zero cell height should produce zero offset")
    }

    // MARK: - endMomentum

    func testEndMomentumStopsAnimation() {
        let engine = SmoothScrollEngine()
        engine.scrollDelta(10.0, cellHeight: cellHeight)
        engine.beginMomentum()
        XCTAssertTrue(engine.requiresContinuousFrames())

        engine.endMomentum()
        // Run one frame to trigger spring-back (fractional offset remains)
        // But momentum flag should be cleared
        var time = 1.0
        _ = engine.frame(cellHeight: cellHeight, time: time)
        time += 1.0 / 60.0

        // After enough spring-back frames, should stop
        var stopped = false
        for _ in 0..<200 {
            let frame = engine.frame(cellHeight: cellHeight, time: time)
            time += 1.0 / 60.0
            if !frame.isAnimating {
                stopped = true
                break
            }
        }
        XCTAssertTrue(stopped, "Should eventually stop after endMomentum and spring-back")
    }

    // MARK: - Phase 4: Bounds clamping

    func testBoundsClampingAtMax() {
        let engine = SmoothScrollEngine()
        engine.setBounds(maxRow: 5)
        var firedDeltas: [Int] = []
        engine.onScrollLineChange = { delta in firedDeltas.append(delta) }

        // Scroll to row 5 (the max)
        engine.scrollDelta(100.0, cellHeight: cellHeight) // 5 rows

        XCTAssertEqual(engine.targetScrollRow, 5, "Should clamp at maxRow")

        // Try to scroll further past max
        firedDeltas.removeAll()
        engine.scrollDelta(100.0, cellHeight: cellHeight) // 5 more rows

        // Should NOT fire any callbacks past bounds
        XCTAssertEqual(engine.targetScrollRow, 5, "Should stay clamped at maxRow")
        XCTAssertTrue(firedDeltas.isEmpty, "Should not fire callbacks past maxRow")
    }

    func testBoundsClampingAtMin() {
        let engine = SmoothScrollEngine()
        engine.setBounds(maxRow: 100)
        var firedDeltas: [Int] = []
        engine.onScrollLineChange = { delta in firedDeltas.append(delta) }

        // Scroll negative (past min = 0)
        engine.scrollDelta(-100.0, cellHeight: cellHeight) // -5 rows

        // Should NOT go below 0
        XCTAssertEqual(engine.targetScrollRow, 0, "Should clamp at minRow (0)")
        XCTAssertTrue(firedDeltas.isEmpty, "Should not fire callbacks below minRow")
    }

    // MARK: - Phase 4: Rubber band at bounds

    func testRubberBandAtBounds() {
        let engine = SmoothScrollEngine()
        engine.setBounds(maxRow: 3)

        // Scroll to max
        engine.scrollDelta(60.0, cellHeight: cellHeight) // 3 rows
        XCTAssertEqual(engine.targetScrollRow, 3)

        // Push past max — should create rubber-band offset
        engine.scrollDelta(5.0, cellHeight: cellHeight) // 0.25 rows past max
        XCTAssertEqual(engine.targetScrollRow, 3, "Target should stay at max")

        // Frame should show a non-zero offset (rubber-band)
        let frame = engine.frame(cellHeight: cellHeight, time: 1.0)
        // The offset should be positive but capped at rubberBandLimit (0.3 rows)
        XCTAssertGreaterThan(frame.offsetPixels, 0, "Should show rubber-band offset past max")
        XCTAssertLessThanOrEqual(frame.offsetPixels, 0.3 * Float(cellHeight) + 0.01,
                                  "Rubber-band should be capped")

        // Run frames — rubber-band should spring back to zero
        var time = 1.0
        var lastOffset: Float = frame.offsetPixels
        for _ in 0..<200 {
            time += 1.0 / 60.0
            let f = engine.frame(cellHeight: cellHeight, time: time)
            lastOffset = f.offsetPixels
            if !f.isAnimating { break }
        }
        XCTAssertEqual(lastOffset, 0.0, accuracy: 0.1, "Rubber-band should spring back to zero")
    }

    // MARK: - Phase 4: jumpTo

    func testJumpToResetsState() {
        let engine = SmoothScrollEngine()
        engine.setBounds(maxRow: 100)

        // Build up some scroll state
        engine.scrollDelta(50.0, cellHeight: cellHeight)
        engine.beginMomentum()
        XCTAssertTrue(engine.requiresContinuousFrames())

        // Jump to row 10
        engine.jumpTo(row: 10)

        XCTAssertEqual(engine.targetScrollRow, 10, "jumpTo should set target row")
        XCTAssertFalse(engine.requiresContinuousFrames(), "jumpTo should clear animation state")

        // Frame should produce zero offset
        let frame = engine.frame(cellHeight: cellHeight, time: 1.0)
        XCTAssertEqual(frame.offsetPixels, 0.0, accuracy: 0.01, "jumpTo should zero render offset")
        XCTAssertFalse(frame.isAnimating, "jumpTo should not be animating")
    }

    func testJumpToClampsToMaxBounds() {
        let engine = SmoothScrollEngine()
        engine.setBounds(maxRow: 50)

        engine.jumpTo(row: 100)
        XCTAssertEqual(engine.targetScrollRow, 50, "jumpTo should clamp to maxRow")
    }

    func testJumpToClampsToMinBounds() {
        let engine = SmoothScrollEngine()
        engine.setBounds(maxRow: 50)

        engine.jumpTo(row: -10)
        XCTAssertEqual(engine.targetScrollRow, 0, "jumpTo should clamp to minRow")
    }

    func testJumpToSameRowPreservesAnimationState() {
        let engine = SmoothScrollEngine()
        engine.setBounds(maxRow: 50)

        engine.scrollDelta(10.0, cellHeight: cellHeight) // 0.5 rows
        XCTAssertTrue(engine.requiresContinuousFrames(), "Fractional scroll should animate")

        engine.jumpTo(row: 0)

        let frame = engine.frame(cellHeight: cellHeight, time: 1.0)
        XCTAssertGreaterThan(abs(frame.offsetPixels), 0.01,
                             "Same-row sync should preserve fractional offset")
        XCTAssertTrue(frame.isAnimating, "Same-row sync should keep smooth scrolling alive")
    }

    func testJumpToDifferentRowStillResetsAnimationState() {
        let engine = SmoothScrollEngine()
        engine.setBounds(maxRow: 50)

        engine.scrollDelta(10.0, cellHeight: cellHeight) // 0.5 rows
        XCTAssertTrue(engine.requiresContinuousFrames(), "Fractional scroll should animate")

        engine.jumpTo(row: 5)

        let frame = engine.frame(cellHeight: cellHeight, time: 1.0)
        XCTAssertEqual(engine.targetScrollRow, 5, "Different-row sync should update target row")
        XCTAssertEqual(frame.offsetPixels, 0.0, accuracy: 0.01,
                       "Different-row sync should clear fractional offset")
        XCTAssertFalse(frame.isAnimating, "Different-row sync should stop animation")
    }

    // MARK: - Phase 4: handleResize

    func testHandleResizeResetsState() {
        let engine = SmoothScrollEngine()

        // Build up scroll state
        engine.scrollDelta(30.0, cellHeight: cellHeight)
        engine.beginMomentum()
        XCTAssertTrue(engine.requiresContinuousFrames())

        engine.handleResize()

        XCTAssertFalse(engine.requiresContinuousFrames(), "handleResize should clear animation state")

        let frame = engine.frame(cellHeight: cellHeight, time: 1.0)
        XCTAssertEqual(frame.offsetPixels, 0.0, accuracy: 0.01, "handleResize should zero render offset")
        XCTAssertFalse(frame.isAnimating, "handleResize should not be animating")
    }

    // MARK: - Phase 4: Frame-rate independence

    func testFrameRateIndependence() {
        // Run same physics at 60Hz and 120Hz — final state should be similar

        // --- 60 Hz ---
        let engine60 = SmoothScrollEngine()
        engine60.scrollDelta(15.0, cellHeight: cellHeight) // 0.75 rows fractional
        var time60 = 1.0
        var offset60: Float = 0
        for _ in 0..<120 { // 2 seconds at 60Hz
            let frame = engine60.frame(cellHeight: cellHeight, time: time60)
            time60 += 1.0 / 60.0
            offset60 = frame.offsetPixels
        }

        // --- 120 Hz ---
        let engine120 = SmoothScrollEngine()
        engine120.scrollDelta(15.0, cellHeight: cellHeight) // 0.75 rows fractional
        var time120 = 1.0
        var offset120: Float = 0
        for _ in 0..<240 { // 2 seconds at 120Hz
            let frame = engine120.frame(cellHeight: cellHeight, time: time120)
            time120 += 1.0 / 120.0
            offset120 = frame.offsetPixels
        }

        // Both should have converged to zero (spring-back)
        XCTAssertEqual(offset60, 0.0, accuracy: 0.5, "60Hz should converge to near-zero")
        XCTAssertEqual(offset120, 0.0, accuracy: 0.5, "120Hz should converge to near-zero")
        // And they should be close to each other
        XCTAssertEqual(offset60, offset120, accuracy: 1.0,
                       "60Hz and 120Hz should produce similar results")
    }
}
