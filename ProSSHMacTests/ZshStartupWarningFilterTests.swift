import XCTest
@testable import ProSSHMac

/// Covers `ZshStartupWarningFilter`, extracted from `LocalPTYProcess.yieldSanitized`.
/// The filter had no test coverage before 2026-09-03, when its unbounded scan was
/// measured at 93% of local-shell wall time.
final class ZshStartupWarningFilterTests: XCTestCase {

    private func collect(
        _ filter: inout ZshStartupWarningFilter,
        _ chunks: [String]
    ) -> String {
        var out = Data()
        for chunk in chunks {
            filter.process(Data(chunk.utf8)) { out.append($0) }
        }
        filter.finish { out.append($0) }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Filtering

    func testRemovesWarningLine() {
        var filter = ZshStartupWarningFilter()
        let output = collect(&filter, ["zsh: can't set tty pgrp: Operation not permitted\nhello\n"])
        XCTAssertEqual(output, "hello\n")
    }

    func testRemovesWarningLineWhenPrecededByOtherOutput() {
        var filter = ZshStartupWarningFilter()
        let output = collect(&filter, ["before\nzsh: can't set tty pgrp: nope\nafter\n"])
        XCTAssertEqual(output, "before\nafter\n")
    }

    func testRemovesWarningSplitAcrossChunks() {
        var filter = ZshStartupWarningFilter()
        let output = collect(&filter, ["zsh: can't set ", "tty pgrp: denied\ntail\n"])
        XCTAssertEqual(output, "tail\n")
    }

    func testPassesThroughOutputWithNoWarning() {
        var filter = ZshStartupWarningFilter()
        let output = collect(&filter, ["one\n", "two\n", "three\n"])
        XCTAssertEqual(output, "one\ntwo\nthree\n")
    }

    // MARK: - No byte loss

    func testPartialMarkerPrefixAtStreamEndIsStillEmitted() {
        // "zsh: can't" is a prefix of the marker, so it is held back as carry.
        // It must still reach the terminal when the stream ends.
        var filter = ZshStartupWarningFilter()
        let output = collect(&filter, ["hello zsh: can't"])
        XCTAssertEqual(output, "hello zsh: can't")
    }

    func testPartialMarkerPrefixIsEmittedWhenItTurnsOutNotToMatch() {
        var filter = ZshStartupWarningFilter()
        let output = collect(&filter, ["hello zsh: can't", " do that\n"])
        XCTAssertEqual(output, "hello zsh: can't do that\n")
    }

    func testCarryIsFlushedInOrderWhenBudgetRunsOut() {
        // Carry buffered, then the very next chunk trips the budget: the carry
        // must be emitted before that chunk, not dropped or reordered.
        var filter = ZshStartupWarningFilter(byteBudget: 8)
        var out = Data()
        filter.process(Data("zsh: c".utf8)) { out.append($0) }
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "", "prefix should be held back")
        filter.process(Data("XYZ".utf8)) { out.append($0) }
        filter.finish { out.append($0) }
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "zsh: cXYZ")
    }

    func testInvalidUTF8ChunkIsPassedThroughWithoutLoss() {
        var filter = ZshStartupWarningFilter()
        var out = Data()
        let invalid = Data([0xE2, 0x82])   // truncated multi-byte sequence
        filter.process(invalid) { out.append($0) }
        filter.finish { out.append($0) }
        XCTAssertEqual(out, invalid)
    }

    // MARK: - Bounded scanning (the performance fix)

    func testStopsScanningAfterFindingTheWarning() {
        var filter = ZshStartupWarningFilter()
        XCTAssertTrue(filter.isScanning)
        filter.process(Data("zsh: can't set tty pgrp: x\n".utf8)) { _ in }
        XCTAssertFalse(filter.isScanning, "filter must switch off once the warning is removed")
    }

    func testStopsScanningOnceByteBudgetIsSpent() {
        var filter = ZshStartupWarningFilter(byteBudget: 16)
        filter.process(Data(String(repeating: "a", count: 8).utf8)) { _ in }
        XCTAssertTrue(filter.isScanning, "still inside the budget")
        filter.process(Data(String(repeating: "a", count: 32).utf8)) { _ in }
        XCTAssertFalse(filter.isScanning, "budget spent — scanning must stop for good")
    }

    func testOutputIsUnchangedAfterScanningStops() {
        var filter = ZshStartupWarningFilter(byteBudget: 4)
        var out = Data()
        filter.process(Data("aaaaaaaa".utf8)) { out.append($0) }
        XCTAssertFalse(filter.isScanning)
        // A warning arriving after the budget is spent is no longer stripped —
        // that is the accepted trade, since zsh only emits it during startup.
        filter.process(Data("zsh: can't set tty pgrp: late\n".utf8)) { out.append($0) }
        filter.finish { out.append($0) }
        XCTAssertEqual(String(decoding: out, as: UTF8.self),
                       "aaaaaaaazsh: can't set tty pgrp: late\n")
    }

    func testDefaultBudgetComfortablyCoversShellStartup() {
        // The warning lands within the first ~100 bytes of a session.
        XCTAssertGreaterThanOrEqual(ZshStartupWarningFilter.defaultByteBudget, 8 * 1024)
    }

    func testWarningIsStrippedAfterSeveralKilobytesOfPrecedingOutput() {
        var filter = ZshStartupWarningFilter()
        let preamble = String(repeating: "motd line\n", count: 200)   // ~2 KB
        let output = collect(&filter, [preamble, "zsh: can't set tty pgrp: x\ndone\n"])
        XCTAssertEqual(output, preamble + "done\n")
    }
}
