// TerminalSearchTests.swift
// ProSSHV2
//
// E.2 — Unit coverage for terminal search (plain text, regex, toggles, navigation).

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class TerminalSearchTests: XCTestCase {

    @MainActor
    func testDefaultSearchFindsMatchesAcrossLinesCaseInsensitive() {
        let search = TerminalSearch()
        search.updateLines([
            "Alpha beta",
            "BETA gamma",
            "no match"
        ])

        search.query = "beta"

        let count = search.matches.count
        let summary = search.resultSummary
        let firstLineCount = search.matches(forLineIndex: 0).count
        let secondLineCount = search.matches(forLineIndex: 1).count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(summary, "1/2")
        XCTAssertEqual(firstLineCount, 1)
        XCTAssertEqual(secondLineCount, 1)
    }

    @MainActor
    func testCaseSensitiveToggleRestrictsMatches() throws {
        let search = TerminalSearch()
        search.updateLines(["Beta beta BETA"])

        search.query = "beta"
        let initialCount = search.matches.count
        XCTAssertEqual(initialCount, 3)

        search.isCaseSensitive = true
        let caseSensitiveCount = search.matches.count
        XCTAssertEqual(caseSensitiveCount, 1)

        let match = try XCTUnwrap(search.matches.first)
        let location = match.location
        XCTAssertEqual(location, 5)
    }

    @MainActor
    func testRegexSearchAndInvalidPattern() {
        let search = TerminalSearch()
        search.updateLines(["eth0 up", "wlan1 down", "lo up"])
        search.isRegexEnabled = true

        search.query = "[a-z]+\\d"
        let validCount = search.matches.count
        let validError = search.validationError
        XCTAssertEqual(validCount, 2)
        XCTAssertNil(validError)

        search.query = "(["
        let invalidCount = search.matches.count
        let invalidError = search.validationError
        XCTAssertEqual(invalidCount, 0)
        XCTAssertNotNil(invalidError)
    }

    @MainActor
    func testNavigationWrapsForwardAndBackward() {
        let search = TerminalSearch()
        search.updateLines(["x x x"])
        search.query = "x"

        let initialSummary = search.resultSummary
        XCTAssertEqual(initialSummary, "1/3")

        search.selectNextMatch()
        let secondSummary = search.resultSummary
        XCTAssertEqual(secondSummary, "2/3")

        search.selectNextMatch()
        let thirdSummary = search.resultSummary
        XCTAssertEqual(thirdSummary, "3/3")

        search.selectNextMatch()
        let wrappedSummary = search.resultSummary
        XCTAssertEqual(wrappedSummary, "1/3")

        search.selectPreviousMatch()
        let previousSummary = search.resultSummary
        XCTAssertEqual(previousSummary, "3/3")
    }

    @MainActor
    func testSelectionIsRestoredWhenLinesUpdate() throws {
        let search = TerminalSearch()
        search.updateLines(["foo one", "foo two"])
        search.query = "foo"

        search.selectNextMatch()
        let selected = try XCTUnwrap(search.selectedMatch)
        let selectedLine = selected.lineIndex
        XCTAssertEqual(selectedLine, 1)

        search.updateLines(["foo one", "foo two", "foo three"])
        let updatedSelectedLine = search.selectedMatch?.lineIndex
        let updatedCount = search.matches.count
        XCTAssertEqual(updatedSelectedLine, 1)
        XCTAssertEqual(updatedCount, 3)
    }
}
#endif
