// TerminalSearchTests.swift
// ProSSHV2
//
// E.2 — Unit coverage for terminal search (plain text, regex, toggles, navigation).

#if canImport(XCTest)
import XCTest

@MainActor
final class TerminalSearchTests: XCTestCase {

    func testDefaultSearchFindsMatchesAcrossLinesCaseInsensitive() {
        let search = TerminalSearch()
        search.updateLines([
            "Alpha beta",
            "BETA gamma",
            "no match"
        ])

        search.query = "beta"

        XCTAssertEqual(search.matches.count, 2)
        XCTAssertEqual(search.resultSummary, "1/2")
        XCTAssertEqual(search.matches(forLineIndex: 0).count, 1)
        XCTAssertEqual(search.matches(forLineIndex: 1).count, 1)
    }

    func testCaseSensitiveToggleRestrictsMatches() {
        let search = TerminalSearch()
        search.updateLines(["Beta beta BETA"])

        search.query = "beta"
        XCTAssertEqual(search.matches.count, 3)

        search.isCaseSensitive = true
        XCTAssertEqual(search.matches.count, 1)

        let match = try XCTUnwrap(search.matches.first)
        XCTAssertEqual(match.location, 5)
    }

    func testRegexSearchAndInvalidPattern() {
        let search = TerminalSearch()
        search.updateLines(["eth0 up", "wlan1 down", "lo up"])
        search.isRegexEnabled = true

        search.query = "[a-z]+\\d"
        XCTAssertEqual(search.matches.count, 2)
        XCTAssertNil(search.validationError)

        search.query = "(["
        XCTAssertEqual(search.matches.count, 0)
        XCTAssertNotNil(search.validationError)
    }

    func testNavigationWrapsForwardAndBackward() {
        let search = TerminalSearch()
        search.updateLines(["x x x"])
        search.query = "x"

        XCTAssertEqual(search.resultSummary, "1/3")

        search.selectNextMatch()
        XCTAssertEqual(search.resultSummary, "2/3")

        search.selectNextMatch()
        XCTAssertEqual(search.resultSummary, "3/3")

        search.selectNextMatch()
        XCTAssertEqual(search.resultSummary, "1/3")

        search.selectPreviousMatch()
        XCTAssertEqual(search.resultSummary, "3/3")
    }

    func testSelectionIsRestoredWhenLinesUpdate() {
        let search = TerminalSearch()
        search.updateLines(["foo one", "foo two"])
        search.query = "foo"

        search.selectNextMatch()
        let selected = try XCTUnwrap(search.selectedMatch)
        XCTAssertEqual(selected.lineIndex, 1)

        search.updateLines(["foo one", "foo two", "foo three"])
        XCTAssertEqual(search.selectedMatch?.lineIndex, 1)
        XCTAssertEqual(search.matches.count, 3)
    }
}
#endif
