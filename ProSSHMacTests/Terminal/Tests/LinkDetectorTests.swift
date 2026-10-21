#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class LinkDetectorTests: XCTestCase {
    func testBalancedParenthesesStayInURLButSentencePunctuationDoesNot() {
        let links = LinkDetector().detectLinks(in: "Read https://en.wikipedia.org/wiki/Foo_(bar).")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.kind, .url)
        XCTAssertEqual(links.first?.text, "https://en.wikipedia.org/wiki/Foo_(bar)")
        XCTAssertEqual(links.first?.destinationURL.absoluteString, "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    func testRelativeVersionTextIsNotDetectedAsFilePath() {
        let links = LinkDetector().detectLinks(in: "See v1.2.3/changelog and usr/bin/env")
        XCTAssertTrue(links.isEmpty)
    }

    func testAbsolutePathStillDetected() {
        let links = LinkDetector().detectLinks(in: "Open /usr/bin/env")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.kind, .filePath)
        XCTAssertEqual(links.first?.text, "/usr/bin/env")
    }
}
#endif
