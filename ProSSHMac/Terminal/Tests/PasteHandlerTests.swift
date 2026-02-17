// PasteHandlerTests.swift
// ProSSHV2
//
// D.6 — clipboard paste handling tests.

#if canImport(XCTest)
import XCTest

final class PasteHandlerTests: XCTestCase {

    func testNormalizeCRLFToCR() {
        let input = "line1\r\nline2\r\nline3"
        let normalized = PasteHandler.normalizeNewlines(in: input)
        XCTAssertEqual(normalized, "line1\rline2\rline3")
    }

    func testPayloadWithoutBracketedPaste() {
        let input = "line1\r\nline2"
        let payload = PasteHandler.payload(for: input, bracketedPasteEnabled: false)
        XCTAssertEqual(payload, "line1\rline2")
    }

    func testPayloadWithBracketedPaste() {
        let input = "line1\nline2"
        let payload = PasteHandler.payload(for: input, bracketedPasteEnabled: true)
        XCTAssertEqual(payload, "\u{1B}[200~line1\nline2\u{1B}[201~")
    }

    func testChunkingWithoutBracketedPaste() {
        let chunks = PasteHandler.payloadChunks(
            for: "abcdef",
            bracketedPasteEnabled: false,
            options: .init(chunkByteLimit: 2)
        )

        XCTAssertEqual(chunks, ["ab", "cd", "ef"])
    }

    func testChunkingWithBracketedPasteWrapsFirstAndLastChunk() {
        let chunks = PasteHandler.payloadChunks(
            for: "abcdef",
            bracketedPasteEnabled: true,
            options: .init(chunkByteLimit: 2)
        )

        XCTAssertEqual(chunks, ["\u{1B}[200~ab", "cd", "ef\u{1B}[201~"])
    }

    func testClipboardSequenceBuilderReturnsEmptyForNilOrEmptyClipboard() {
        XCTAssertTrue(
            PasteHandler.sequences(forClipboardText: nil, bracketedPasteEnabled: false).isEmpty
        )
        XCTAssertTrue(
            PasteHandler.sequences(forClipboardText: "", bracketedPasteEnabled: true).isEmpty
        )
    }
}
#endif
