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
        for _ in 0..<500 {
            let frame = engine.frame(cellHeight: cellHeight)
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
        for _ in 0..<200 {
            let frame = engine.frame(cellHeight: cellHeight)
            lastOffset = frame.offsetPixels
            if !frame.isAnimating { break }
        }

        XCTAssertEqual(lastOffset, 0.0, accuracy: 0.01, "Spring-back should converge to zero")
        XCTAssertFalse(engine.requiresContinuousFrames(), "Should not require frames after spring-back")
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
        let frame = engine.frame(cellHeight: cellHeight)

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
        for _ in 0..<200 {
            let frame = engine.frame(cellHeight: cellHeight)
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
        let frame = engine.frame(cellHeight: 0.0)
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
        _ = engine.frame(cellHeight: cellHeight)

        // After enough spring-back frames, should stop
        var stopped = false
        for _ in 0..<200 {
            let frame = engine.frame(cellHeight: cellHeight)
            if !frame.isAnimating {
                stopped = true
                break
            }
        }
        XCTAssertTrue(stopped, "Should eventually stop after endMomentum and spring-back")
    }
}
