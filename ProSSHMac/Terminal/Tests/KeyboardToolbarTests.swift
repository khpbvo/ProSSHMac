// KeyboardToolbarTests.swift
// ProSSHV2
//
// D.3 — Keyboard toolbar state and layout tests.

#if canImport(XCTest)
import XCTest

final class KeyboardToolbarTests: XCTestCase {

    func testLayoutSerializeAndParse() {
        let keys: [KeyboardToolbarKey] = [.tab, .esc, .ctrl, .alt]
        let serialized = KeyboardToolbarLayout.serialize(keys)
        XCTAssertEqual(serialized, "tab,esc,ctrl,alt")

        let parsed = KeyboardToolbarLayout.parse(serialized, fallback: [])
        XCTAssertEqual(parsed, keys)
    }

    func testLayoutParseFallsBackWhenEmpty() {
        let fallback: [KeyboardToolbarKey] = [.f1, .f2]
        let parsed = KeyboardToolbarLayout.parse(",,invalid", fallback: fallback)
        XCTAssertEqual(parsed, fallback)
    }

    func testLayoutParseDeduplicates() {
        let parsed = KeyboardToolbarLayout.parse("tab,esc,tab,esc,ctrl", fallback: [])
        XCTAssertEqual(parsed, [.tab, .esc, .ctrl])
    }

    func testCtrlOneShotAndConsume() {
        var modifiers = KeyboardToolbarModifiers()
        modifiers.toggleCtrl(now: 10.0)
        XCTAssertEqual(modifiers.ctrl, .oneShot)
        XCTAssertEqual(modifiers.activeKeyModifiers(), [.ctrl])

        modifiers.consumeOneShot()
        XCTAssertEqual(modifiers.ctrl, .off)
        XCTAssertEqual(modifiers.activeKeyModifiers(), [])
    }

    func testCtrlDoubleTapLocksThenTapUnlocks() {
        var modifiers = KeyboardToolbarModifiers()
        modifiers.toggleCtrl(now: 1.0)
        modifiers.toggleCtrl(now: 1.2) // double tap -> lock
        XCTAssertEqual(modifiers.ctrl, .locked)
        XCTAssertEqual(modifiers.activeKeyModifiers(), [.ctrl])

        modifiers.toggleCtrl(now: 2.0) // single tap while locked -> off
        XCTAssertEqual(modifiers.ctrl, .off)
        XCTAssertEqual(modifiers.activeKeyModifiers(), [])
    }

    func testAltDoubleTapLocks() {
        var modifiers = KeyboardToolbarModifiers()
        modifiers.toggleAlt(now: 5.0)
        modifiers.toggleAlt(now: 5.2)
        XCTAssertEqual(modifiers.alt, .locked)
        XCTAssertEqual(modifiers.activeKeyModifiers(), [.alt])
    }
}
#endif
