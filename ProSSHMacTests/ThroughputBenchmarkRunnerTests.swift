import Foundation
import XCTest
@testable import ProSSHMac

final class ThroughputBenchmarkRunnerTests: XCTestCase {
    func testPTYCommandDoesNotContainLiteralSentinel() {
        let sentinel = "---PROSSH_BENCH_DONE_TEST---"

        let command = ThroughputBenchmarkRunner.makePTYBenchmarkCommand(
            kilobytes: 2048,
            sentinel: sentinel
        )

        XCTAssertFalse(command.contains(sentinel))
        XCTAssertTrue(command.contains("count=2048"))
    }

    func testSentinelMatcherFindsMarkerInSingleChunk() {
        var matcher = BenchmarkSentinelMatcher(sentinel: "BENCH_DONE")

        XCTAssertTrue(matcher.consume(Data("payload BENCH_DONE prompt".utf8)))
    }

    func testSentinelMatcherFindsMarkerAcrossChunkBoundary() {
        var matcher = BenchmarkSentinelMatcher(sentinel: "BENCH_DONE")

        XCTAssertFalse(matcher.consume(Data("payload BENCH_".utf8)))
        XCTAssertTrue(matcher.consume(Data("DONE prompt".utf8)))
    }

    func testSentinelMatcherRejectsEchoedSplitCommand() {
        let sentinel = "---PROSSH_BENCH_DONE_TEST---"
        let command = ThroughputBenchmarkRunner.makePTYBenchmarkCommand(
            kilobytes: 1,
            sentinel: sentinel
        )
        var matcher = BenchmarkSentinelMatcher(sentinel: sentinel)

        XCTAssertFalse(matcher.consume(Data(command.utf8)))
    }

    // MARK: - Rendered benchmark mode

    /// The render modes must not be folded into `isEnabled`: that flag makes
    /// AppDependencies bail out before the UI is wired, which would leave the
    /// rendered benchmark with no window to render into.
    @MainActor
    func testRenderModesAreOffWithoutTheirFlags() {
        XCTAssertFalse(ThroughputBenchmarkRunner.isRenderBenchmarkEnabled)
        XCTAssertFalse(ThroughputBenchmarkRunner.isRenderDetached)
        XCTAssertFalse(ThroughputBenchmarkRunner.isEnabled)
    }

    /// The sentinel tap sits on the real reader path, so it runs for every PTY
    /// chunk in a normal session. Unarmed it must do nothing at all.
    @MainActor
    func testChunkObserverIsInertWhenNotArmed() {
        ThroughputBenchmarkRunner.observeBenchmarkChunk(Data("---PROSSH_BENCH_DONE_x---".utf8))
    }

}
