// KeyEncoderTests.swift
// ProSSHV2
//
// D.1 — Unit coverage for terminal key encoding.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class KeyEncoderTests: XCTestCase {

    @MainActor
    func testASCIICharacterEncoding() {
        let encoder = KeyEncoder()
        assertEncoded(encoder, event: KeyEvent(key: .character("a")), expected: [0x61])
        assertEncoded(encoder, event: KeyEvent(key: .character("A")), expected: [0x41])
        assertEncoded(encoder, event: KeyEvent(key: .character("/")), expected: [0x2F])
    }

    @MainActor
    func testArrowKeysNormalMode() {
        let encoder = KeyEncoder(options: .init(applicationCursorKeys: false))
        assertEncoded(encoder, event: KeyEvent(key: .arrow(.up)), expected: [0x1B, 0x5B, 0x41])
        assertEncoded(encoder, event: KeyEvent(key: .arrow(.down)), expected: [0x1B, 0x5B, 0x42])
        assertEncoded(encoder, event: KeyEvent(key: .arrow(.right)), expected: [0x1B, 0x5B, 0x43])
        assertEncoded(encoder, event: KeyEvent(key: .arrow(.left)), expected: [0x1B, 0x5B, 0x44])
    }

    @MainActor
    func testArrowKeysApplicationMode() {
        let encoder = KeyEncoder(options: .init(applicationCursorKeys: true))
        assertEncoded(encoder, event: KeyEvent(key: .arrow(.up)), expected: [0x1B, 0x4F, 0x41])
        assertEncoded(encoder, event: KeyEvent(key: .arrow(.down)), expected: [0x1B, 0x4F, 0x42])
        assertEncoded(encoder, event: KeyEvent(key: .arrow(.right)), expected: [0x1B, 0x4F, 0x43])
        assertEncoded(encoder, event: KeyEvent(key: .arrow(.left)), expected: [0x1B, 0x4F, 0x44])
    }

    @MainActor
    func testFunctionKeysF1ToF12() {
        let encoder = KeyEncoder()
        assertEncoded(encoder, event: KeyEvent(key: .function(1)), expected: [0x1B, 0x4F, 0x50])
        assertEncoded(encoder, event: KeyEvent(key: .function(2)), expected: [0x1B, 0x4F, 0x51])
        assertEncoded(encoder, event: KeyEvent(key: .function(3)), expected: [0x1B, 0x4F, 0x52])
        assertEncoded(encoder, event: KeyEvent(key: .function(4)), expected: [0x1B, 0x4F, 0x53])
        assertEncoded(encoder, event: KeyEvent(key: .function(5)), expected: [0x1B, 0x5B, 0x31, 0x35, 0x7E])
        assertEncoded(encoder, event: KeyEvent(key: .function(12)), expected: [0x1B, 0x5B, 0x32, 0x34, 0x7E])
    }

    @MainActor
    func testEditingKeys() {
        let encoder = KeyEncoder()
        assertEncoded(encoder, event: KeyEvent(key: .editing(.insert)), expected: [0x1B, 0x5B, 0x32, 0x7E])
        assertEncoded(encoder, event: KeyEvent(key: .editing(.delete)), expected: [0x1B, 0x5B, 0x33, 0x7E])
        assertEncoded(encoder, event: KeyEvent(key: .editing(.home)), expected: [0x1B, 0x5B, 0x48])
        assertEncoded(encoder, event: KeyEvent(key: .editing(.end)), expected: [0x1B, 0x5B, 0x46])
        assertEncoded(encoder, event: KeyEvent(key: .editing(.pageUp)), expected: [0x1B, 0x5B, 0x35, 0x7E])
        assertEncoded(encoder, event: KeyEvent(key: .editing(.pageDown)), expected: [0x1B, 0x5B, 0x36, 0x7E])
    }

    @MainActor
    func testXtermModifierEncoding() {
        let encoder = KeyEncoder(options: .init(applicationCursorKeys: true))

        // Shift+Up => CSI 1;2A (not SS3)
        assertEncoded(
            encoder,
            event: KeyEvent(key: .arrow(.up), modifiers: [.shift]),
            expected: [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41]
        )

        // Ctrl+Right => CSI 1;5C
        assertEncoded(
            encoder,
            event: KeyEvent(key: .arrow(.right), modifiers: [.ctrl]),
            expected: [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x43]
        )

        // Shift+Alt+Ctrl+Up => CSI 1;8A
        assertEncoded(
            encoder,
            event: KeyEvent(key: .arrow(.up), modifiers: [.shift, .alt, .ctrl]),
            expected: [0x1B, 0x5B, 0x31, 0x3B, 0x38, 0x41]
        )

        // Ctrl+F5 => CSI 15;5~
        assertEncoded(
            encoder,
            event: KeyEvent(key: .function(5), modifiers: [.ctrl]),
            expected: [0x1B, 0x5B, 0x31, 0x35, 0x3B, 0x35, 0x7E]
        )
    }

    @MainActor
    func testCtrlAlphabetMappings() {
        let encoder = KeyEncoder()
        assertEncoded(encoder, event: KeyEvent(key: .character("a"), modifiers: [.ctrl]), expected: [0x01])
        assertEncoded(encoder, event: KeyEvent(key: .character("z"), modifiers: [.ctrl]), expected: [0x1A])
        assertEncoded(encoder, event: KeyEvent(key: .character("["), modifiers: [.ctrl]), expected: [0x1B])
        assertEncoded(encoder, event: KeyEvent(key: .character("\\"), modifiers: [.ctrl]), expected: [0x1C])
        assertEncoded(encoder, event: KeyEvent(key: .character("]"), modifiers: [.ctrl]), expected: [0x1D])
        assertEncoded(encoder, event: KeyEvent(key: .character("^"), modifiers: [.ctrl]), expected: [0x1E])
        assertEncoded(encoder, event: KeyEvent(key: .character("_"), modifiers: [.ctrl]), expected: [0x1F])
        assertEncoded(encoder, event: KeyEvent(key: .character("?"), modifiers: [.ctrl]), expected: [0x7F])
    }

    @MainActor
    func testBackspaceModes() {
        let delEncoder = KeyEncoder(options: .init(backspaceSendsDelete: true))
        assertEncoded(delEncoder, event: KeyEvent(key: .backspace), expected: [0x7F])

        let bsEncoder = KeyEncoder(options: .init(backspaceSendsDelete: false))
        assertEncoded(bsEncoder, event: KeyEvent(key: .backspace), expected: [0x08])

        // Ctrl+Backspace should always map to DEL.
        assertEncoded(bsEncoder, event: KeyEvent(key: .backspace, modifiers: [.ctrl]), expected: [0x7F])
    }

    @MainActor
    func testEnterModes() {
        let crEncoder = KeyEncoder(options: .init(enterSendsCRLF: false))
        assertEncoded(crEncoder, event: KeyEvent(key: .enter), expected: [0x0D])

        let crlfEncoder = KeyEncoder(options: .init(enterSendsCRLF: true))
        assertEncoded(crlfEncoder, event: KeyEvent(key: .enter), expected: [0x0D, 0x0A])
    }

    @MainActor
    func testTabAndEscape() {
        let encoder = KeyEncoder()
        assertEncoded(encoder, event: KeyEvent(key: .tab), expected: [0x09])
        assertEncoded(encoder, event: KeyEvent(key: .escape), expected: [0x1B])
    }

    @MainActor
    private func assertEncoded(
        _ encoder: KeyEncoder,
        event: KeyEvent,
        expected: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let encoded = encoder.encode(event)
        XCTAssertEqual(encoded, expected, file: file, line: line)
    }
}
#endif
