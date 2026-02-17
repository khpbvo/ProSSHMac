// HardwareKeyHandlerTests.swift
// ProSSHV2
//
// D.4 support tests: paste payload encoding.

#if canImport(XCTest)
import XCTest

final class HardwareKeyHandlerTests: XCTestCase {

    func testPastePayloadWithoutBracketedPaste() {
        let input = "line1\nline2"
        let payload = HardwarePasteEncoder.payload(for: input, bracketedPasteEnabled: false)
        XCTAssertEqual(payload, input)
    }

    func testPastePayloadWithBracketedPaste() {
        let input = "line1\nline2"
        let payload = HardwarePasteEncoder.payload(for: input, bracketedPasteEnabled: true)
        XCTAssertEqual(payload, "\u{1B}[200~line1\nline2\u{1B}[201~")
    }
}
#endif
