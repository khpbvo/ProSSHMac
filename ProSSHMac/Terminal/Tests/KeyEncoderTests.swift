// KeyEncoderTests.swift
// ProSSHV2
//
// D.1 — Unit coverage for terminal key encoding.

#if canImport(XCTest)
import XCTest

final class KeyEncoderTests: XCTestCase {

    func testASCIICharacterEncoding() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("a"))), [0x61])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("A"))), [0x41])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("/"))), [0x2F])
    }

    func testArrowKeysNormalMode() {
        let encoder = KeyEncoder(options: .init(applicationCursorKeys: false))
        XCTAssertEqual(encoder.encode(KeyEvent(key: .arrow(.up))), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .arrow(.down))), [0x1B, 0x5B, 0x42])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .arrow(.right))), [0x1B, 0x5B, 0x43])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .arrow(.left))), [0x1B, 0x5B, 0x44])
    }

    func testArrowKeysApplicationMode() {
        let encoder = KeyEncoder(options: .init(applicationCursorKeys: true))
        XCTAssertEqual(encoder.encode(KeyEvent(key: .arrow(.up))), [0x1B, 0x4F, 0x41])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .arrow(.down))), [0x1B, 0x4F, 0x42])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .arrow(.right))), [0x1B, 0x4F, 0x43])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .arrow(.left))), [0x1B, 0x4F, 0x44])
    }

    func testFunctionKeysF1ToF12() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(KeyEvent(key: .function(1))), [0x1B, 0x4F, 0x50])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .function(2))), [0x1B, 0x4F, 0x51])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .function(3))), [0x1B, 0x4F, 0x52])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .function(4))), [0x1B, 0x4F, 0x53])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .function(5))), [0x1B, 0x5B, 0x31, 0x35, 0x7E])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .function(12))), [0x1B, 0x5B, 0x32, 0x34, 0x7E])
    }

    func testEditingKeys() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(KeyEvent(key: .editing(.insert))), [0x1B, 0x5B, 0x32, 0x7E])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .editing(.delete))), [0x1B, 0x5B, 0x33, 0x7E])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .editing(.home))), [0x1B, 0x5B, 0x48])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .editing(.end))), [0x1B, 0x5B, 0x46])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .editing(.pageUp))), [0x1B, 0x5B, 0x35, 0x7E])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .editing(.pageDown))), [0x1B, 0x5B, 0x36, 0x7E])
    }

    func testXtermModifierEncoding() {
        let encoder = KeyEncoder(options: .init(applicationCursorKeys: true))

        // Shift+Up => CSI 1;2A (not SS3)
        XCTAssertEqual(
            encoder.encode(KeyEvent(key: .arrow(.up), modifiers: [.shift])),
            [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41]
        )

        // Ctrl+Right => CSI 1;5C
        XCTAssertEqual(
            encoder.encode(KeyEvent(key: .arrow(.right), modifiers: [.ctrl])),
            [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x43]
        )

        // Shift+Alt+Ctrl+Up => CSI 1;8A
        XCTAssertEqual(
            encoder.encode(KeyEvent(key: .arrow(.up), modifiers: [.shift, .alt, .ctrl])),
            [0x1B, 0x5B, 0x31, 0x3B, 0x38, 0x41]
        )

        // Ctrl+F5 => CSI 15;5~
        XCTAssertEqual(
            encoder.encode(KeyEvent(key: .function(5), modifiers: [.ctrl])),
            [0x1B, 0x5B, 0x31, 0x35, 0x3B, 0x35, 0x7E]
        )
    }

    func testCtrlAlphabetMappings() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("a"), modifiers: [.ctrl])), [0x01])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("z"), modifiers: [.ctrl])), [0x1A])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("["), modifiers: [.ctrl])), [0x1B])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("\\"), modifiers: [.ctrl])), [0x1C])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("]"), modifiers: [.ctrl])), [0x1D])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("^"), modifiers: [.ctrl])), [0x1E])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("_"), modifiers: [.ctrl])), [0x1F])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .character("?"), modifiers: [.ctrl])), [0x7F])
    }

    func testBackspaceModes() {
        let delEncoder = KeyEncoder(options: .init(backspaceSendsDelete: true))
        XCTAssertEqual(delEncoder.encode(KeyEvent(key: .backspace)), [0x7F])

        let bsEncoder = KeyEncoder(options: .init(backspaceSendsDelete: false))
        XCTAssertEqual(bsEncoder.encode(KeyEvent(key: .backspace)), [0x08])

        // Ctrl+Backspace should always map to DEL.
        XCTAssertEqual(bsEncoder.encode(KeyEvent(key: .backspace, modifiers: [.ctrl])), [0x7F])
    }

    func testEnterModes() {
        let crEncoder = KeyEncoder(options: .init(enterSendsCRLF: false))
        XCTAssertEqual(crEncoder.encode(KeyEvent(key: .enter)), [0x0D])

        let crlfEncoder = KeyEncoder(options: .init(enterSendsCRLF: true))
        XCTAssertEqual(crlfEncoder.encode(KeyEvent(key: .enter)), [0x0D, 0x0A])
    }

    func testTabAndEscape() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(KeyEvent(key: .tab)), [0x09])
        XCTAssertEqual(encoder.encode(KeyEvent(key: .escape)), [0x1B])
    }
}
#endif
