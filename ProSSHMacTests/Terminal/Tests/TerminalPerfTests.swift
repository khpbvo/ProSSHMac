import Foundation
import XCTest
@testable import ProSSHMac

final class TerminalPerfTests: XCTestCase {

    func testSchedulingProbeRunsWorkWhenDisabled() {
        var called = false
        TerminalSchedulingDiagnostics.measureGround(byteCount: 1) { called = true }
        XCTAssertTrue(called)
        if !TerminalSchedulingDiagnostics.isEnabled {
            XCTAssertNil(TerminalSchedulingDiagnostics.report())
        }
    }

    func testSchedulingProbeSeparatesSleepingThreadFromCPUWorkAndResets() throws {
        guard TerminalSchedulingDiagnostics.isEnabled else {
            throw XCTSkip("scheduling diagnostics are off in this process")
        }
        TerminalSchedulingDiagnostics.reset()
        TerminalSchedulingDiagnostics.measureGround(byteCount: 4096) {
            Thread.sleep(forTimeInterval: 0.03)
        }
        TerminalSchedulingDiagnostics.recordBatch(bytes: 4096)
        TerminalSchedulingDiagnostics.event("testEvent")
        let report = try XCTUnwrap(TerminalSchedulingDiagnostics.report())
        XCTAssertTrue(report.contains("calls=1 bytes=4096"))
        XCTAssertTrue(report.contains("batches=1 bytes=4096 mean=4096 max=4096 under4K=0"))
        XCTAssertTrue(report.contains("testEvent=1"))
        let expression = try NSRegularExpression(pattern: "cpu/elapsed=([0-9.]+)%")
        let match = try XCTUnwrap(expression.firstMatch(in: report, range: NSRange(report.startIndex..., in: report)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: report))
        XCTAssertLessThan(try XCTUnwrap(Double(report[range])), 50,
                          "A sleeping synchronous thread should spend most elapsed time off CPU.")
        TerminalSchedulingDiagnostics.reset()
        let reset = try XCTUnwrap(TerminalSchedulingDiagnostics.report())
        XCTAssertFalse(reset.contains("qos="))
        XCTAssertFalse(reset.contains("testEvent"))
        XCTAssertTrue(reset.contains("batches=0 bytes=0"))
    }

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

    /// The reader/parser stages must be present, since the whole point of the
    /// RenderCost work is attributing time outside the draw loop.
    func testReaderPathStagesArePresent() {
        let labels = Set(TerminalPerf.Stage.allCases.map(\.label))

        XCTAssertTrue(labels.contains("chunk record"))
        XCTAssertTrue(labels.contains("history index"))
        XCTAssertTrue(labels.contains("feed call"))
        XCTAssertTrue(labels.contains("batch follow-up"))
        XCTAssertTrue(labels.contains("publish engine wait"))
    }

    /// Summed durations alone cannot separate a blocked stage from an absent one,
    /// so the report carries a span and a busy percentage per stage.
    func testReportCarriesSpanAndBusyColumns() throws {
        guard TerminalPerf.isEnabled else {
            throw XCTSkip("stage timers are off in this process")
        }

        TerminalPerf.reset()
        let start = TerminalPerf.now()
        TerminalPerf.record(.publish, since: start)

        let report = try XCTUnwrap(TerminalPerf.report(title: "test", wallSeconds: 1.0))
        XCTAssertTrue(report.contains("span"))
        XCTAssertTrue(report.contains("busy"))
        XCTAssertTrue(report.contains("publish"))

        TerminalPerf.reset()
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
