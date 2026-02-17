// MouseEncoderTests.swift
// ProSSHV2
//
// D.5 — mouse encoding and mode-filtering coverage.

#if canImport(XCTest)
import XCTest

final class MouseEncoderTests: XCTestCase {

    func testX10LeftPressEncoding() {
        let encoder = MouseEncoder(trackingMode: .x10, encoding: .x10)
        let event = MouseEvent(kind: .press, button: .left, row: 2, column: 3)

        let sequence = encoder.encode(event)
        XCTAssertNotNil(sequence)
        if let seq = sequence {
            let bytes = Array(seq.utf8)
            XCTAssertEqual(bytes, [0x1B, 0x5B, 0x4D, 32, 35, 34] as [UInt8])
        }
    }

    func testSGRPressAndReleaseEncoding() {
        let encoder = MouseEncoder(trackingMode: .buttonEvent, encoding: .sgr)

        let press = encoder.encode(MouseEvent(kind: .press, button: .left, row: 12, column: 44))
        XCTAssertEqual(press, "\u{1B}[<0;44;12M")

        let release = encoder.encode(MouseEvent(kind: .release, button: .left, row: 12, column: 44))
        XCTAssertEqual(release, "\u{1B}[<3;44;12m")
    }

    func testButtonAndScrollMapping() {
        let encoder = MouseEncoder(trackingMode: .anyEvent, encoding: .sgr)

        XCTAssertEqual(
            encoder.encode(MouseEvent(kind: .press, button: .middle, row: 1, column: 1)),
            "\u{1B}[<1;1;1M"
        )
        XCTAssertEqual(
            encoder.encode(MouseEvent(kind: .press, button: .right, row: 1, column: 1)),
            "\u{1B}[<2;1;1M"
        )
        XCTAssertEqual(
            encoder.encode(MouseEvent(kind: .scrollUp, button: .none, row: 1, column: 1)),
            "\u{1B}[<64;1;1M"
        )
        XCTAssertEqual(
            encoder.encode(MouseEvent(kind: .scrollDown, button: .none, row: 1, column: 1)),
            "\u{1B}[<65;1;1M"
        )
    }

    func testTrackingModeFiltering() {
        let noMouse = MouseEncoder(trackingMode: .none, encoding: .x10)
        XCTAssertNil(noMouse.encode(MouseEvent(kind: .press, button: .left, row: 1, column: 1)))

        let x10 = MouseEncoder(trackingMode: .x10, encoding: .x10)
        XCTAssertNotNil(x10.encode(MouseEvent(kind: .press, button: .left, row: 1, column: 1)))
        XCTAssertNil(x10.encode(MouseEvent(kind: .release, button: .left, row: 1, column: 1)))
        XCTAssertNil(x10.encode(MouseEvent(kind: .move, button: .left, row: 1, column: 1)))

        let buttonEvent = MouseEncoder(trackingMode: .buttonEvent, encoding: .x10)
        XCTAssertNotNil(buttonEvent.encode(MouseEvent(kind: .move, button: .left, row: 1, column: 1)))
        XCTAssertNil(buttonEvent.encode(MouseEvent(kind: .move, button: .none, row: 1, column: 1)))

        let anyEvent = MouseEncoder(trackingMode: .anyEvent, encoding: .sgr)
        XCTAssertEqual(
            anyEvent.encode(MouseEvent(kind: .move, button: .none, row: 4, column: 5)),
            "\u{1B}[<35;5;4M"
        )
    }

    func testModifierBitsAreApplied() {
        let encoder = MouseEncoder(trackingMode: .anyEvent, encoding: .sgr)
        let event = MouseEvent(
            kind: .press,
            button: .left,
            row: 7,
            column: 11,
            modifiers: [.shift, .alt, .ctrl]
        )

        XCTAssertEqual(encoder.encode(event), "\u{1B}[<28;11;7M")
    }
}
#endif
