import Foundation
import XCTest
@testable import ProSSHMac

final class TerminalPerfTests: XCTestCase {

    /// `nanos`/`calls`/`bytes` are plain arrays indexed by `Stage.rawValue`, so the
    /// raw values must stay contiguous from zero. An explicit raw value on any case
    /// would index out of bounds at runtime.
    func testStageRawValuesAreContiguousFromZero() {
        let rawValues = TerminalPerf.Stage.allCases.map(\.rawValue)

        XCTAssertEqual(rawValues, Array(0..<TerminalPerf.Stage.allCases.count))
    }

    func testStageLabelsAreUniqueAndNonEmpty() {
        let labels = TerminalPerf.Stage.allCases.map(\.label)

        XCTAssertFalse(labels.contains(where: \.isEmpty))
        XCTAssertEqual(Set(labels).count, labels.count, "duplicate labels collide in the stage budget")
    }

    func testDrawLoopStagesArePresent() {
        let labels = Set(TerminalPerf.Stage.allCases.map(\.label))

        XCTAssertTrue(labels.contains("drawable wait"))
        XCTAssertTrue(labels.contains("snapshot apply"))
        XCTAssertTrue(labels.contains("frame encode"))
        XCTAssertTrue(labels.contains("gpu execute"))
        XCTAssertTrue(labels.contains("draw frame"))
    }

    /// The instrumentation must cost nothing when off — that is the whole reason it
    /// is gated. Which branch runs depends on how the test process was launched.
    func testInstrumentationRespectsEnablement() {
        TerminalPerf.reset()
        TerminalPerf.add(.gpuExecute, nanoseconds: 5_000_000)

        if TerminalPerf.isEnabled {
            let report = TerminalPerf.report(title: "test", wallSeconds: 1.0)
            XCTAssertNotNil(report)
            XCTAssertTrue(report?.contains("gpu execute") == true)
        } else {
            XCTAssertEqual(TerminalPerf.now(), 0)
            XCTAssertNil(TerminalPerf.report(title: "test", wallSeconds: 1.0))
        }

        TerminalPerf.reset()
    }

    /// `add` is the entry point for durations that arrive without a start stamp
    /// (GPU time from the command buffer completion handler). A zero duration must
    /// not be counted as a call.
    func testAddIgnoresZeroDuration() throws {
        guard TerminalPerf.isEnabled else {
            throw XCTSkip("stage timers are off in this process")
        }

        TerminalPerf.reset()
        TerminalPerf.add(.gpuExecute, nanoseconds: 0)

        XCTAssertNil(TerminalPerf.report(title: "test", wallSeconds: 1.0))
        TerminalPerf.reset()
    }
}
