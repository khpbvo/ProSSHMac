// KeyboardToolbarTests.swift
// ProSSHV2
//
// D.3 — Keyboard toolbar state and layout tests.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class KeyboardToolbarTests: XCTestCase {

    @MainActor
    func testLayoutSerializeAndParse() {
        let keys: [KeyboardToolbarKey] = [.tab, .esc, .ctrl, .alt]
        let serialized = KeyboardToolbarLayout.serialize(keys)
        XCTAssertEqual(serialized, "tab,esc,ctrl,alt")

        let parsed = KeyboardToolbarLayout.parse(serialized, fallback: [])
        XCTAssertEqual(parsed, keys)
    }

    @MainActor
    func testLayoutParseFallsBackWhenEmpty() {
        let fallback: [KeyboardToolbarKey] = [.f1, .f2]
        let parsed = KeyboardToolbarLayout.parse(",,invalid", fallback: fallback)
        XCTAssertEqual(parsed, fallback)
    }

    @MainActor
    func testLayoutParseDeduplicates() {
        let parsed = KeyboardToolbarLayout.parse("tab,esc,tab,esc,ctrl", fallback: [])
        XCTAssertEqual(parsed, [.tab, .esc, .ctrl])
    }

    @MainActor
    func testCtrlOneShotAndConsume() {
        var modifiers = KeyboardToolbarModifiers()
        modifiers.toggleCtrl(now: 10.0)
        let afterToggleCtrl = modifiers.ctrl
        let afterToggleActive = modifiers.activeKeyModifiers()
        XCTAssertEqual(afterToggleCtrl, .oneShot)
        XCTAssertEqual(afterToggleActive, [.ctrl])

        modifiers.consumeOneShot()
        let afterConsumeCtrl = modifiers.ctrl
        let afterConsumeActive = modifiers.activeKeyModifiers()
        XCTAssertEqual(afterConsumeCtrl, .off)
        XCTAssertEqual(afterConsumeActive, [])
    }

    @MainActor
    func testCtrlDoubleTapLocksThenTapUnlocks() {
        var modifiers = KeyboardToolbarModifiers()
        modifiers.toggleCtrl(now: 1.0)
        modifiers.toggleCtrl(now: 1.2) // double tap -> lock
        let lockedCtrl = modifiers.ctrl
        let lockedActive = modifiers.activeKeyModifiers()
        XCTAssertEqual(lockedCtrl, .locked)
        XCTAssertEqual(lockedActive, [.ctrl])

        modifiers.toggleCtrl(now: 2.0) // single tap while locked -> off
        let unlockedCtrl = modifiers.ctrl
        let unlockedActive = modifiers.activeKeyModifiers()
        XCTAssertEqual(unlockedCtrl, .off)
        XCTAssertEqual(unlockedActive, [])
    }

    @MainActor
    func testAltDoubleTapLocks() {
        var modifiers = KeyboardToolbarModifiers()
        modifiers.toggleAlt(now: 5.0)
        modifiers.toggleAlt(now: 5.2)
        let lockedAlt = modifiers.alt
        let lockedActive = modifiers.activeKeyModifiers()
        XCTAssertEqual(lockedAlt, .locked)
        XCTAssertEqual(lockedActive, [.alt])
    }
}
#endif
