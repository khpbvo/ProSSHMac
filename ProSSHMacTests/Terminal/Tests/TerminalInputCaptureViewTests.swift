import XCTest
import AppKit
@testable import ProSSHMac

final class TerminalInputCaptureViewTests: XCTestCase {
    func testShiftReturnAndKeypadEnterReachLocalAndSSHInputRoutes() throws {
        for isLocal in [true, false] {
            for keyCode: UInt16 in [36, 76] {
                for crlf in [false, true] {
                    let view = DirectTerminalInputNSView(frame: .zero)
                    let sessionID = UUID()
                    view.isEnabled = true
                    view.sessionID = sessionID
                    view.isLocalSession = isLocal
                    view.keyEncoderOptions = { .init(enterSendsCRLF: crlf) }
                    var deliveries: [[UInt8]] = []
                    view.onSendBytes = { id, bytes, _ in
                        XCTAssertEqual(id, sessionID)
                        XCTAssertTrue(isLocal)
                        deliveries.append(bytes)
                    }
                    view.onSendSequence = { id, sequence in
                        XCTAssertEqual(id, sessionID)
                        XCTAssertFalse(isLocal)
                        deliveries.append(Array(sequence.utf8))
                    }
                    let event = try enterEvent(keyCode: keyCode, modifiers: [.shift, .capsLock])
                    view.keyDown(with: event)
                    XCTAssertEqual(deliveries, [Array("\u{1B}[13;2u".utf8)])
                    deliveries.removeAll()
                    XCTAssertTrue(view.performKeyEquivalent(with: event))
                    XCTAssertEqual(deliveries, [Array("\u{1B}[13;2u".utf8)])

                    deliveries.removeAll()
                    view.keyDown(with: try enterEvent(keyCode: keyCode, modifiers: []))
                    XCTAssertEqual(deliveries, [crlf ? [0x0D, 0x0A] : [0x0D]])
                }
            }
        }
    }

    func testShiftEnterDoesNotCaptureInputFromTextEditor() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let view = DirectTerminalInputNSView(frame: .zero)
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(view)
        view.sessionID = UUID()
        view.isEnabled = true
        XCTAssertTrue(window.makeFirstResponder(editor))
        view.onSendBytes = { _, _, _ in XCTFail("Text editor input must not reach the terminal") }
        view.onSendSequence = { _, _ in XCTFail("Text editor input must not reach the terminal") }
        let event = try enterEvent(keyCode: 36, modifiers: .shift)
        for isLocal in [true, false] {
            view.isLocalSession = isLocal
            view.keyDown(with: event)
            XCTAssertFalse(view.performKeyEquivalent(with: event))
        }
    }

    private func enterEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: keyCode
        ))
    }

    func testLocalInputCaptureIsBlockedWhileAIComposerIsFocused() {
        let shouldCapture = DirectTerminalInputNSView.shouldCaptureLocalKeyEvent(
            isEnabled: true,
            hasSessionID: true,
            isLocalSession: true,
            keyWindowActive: true,
            textInputFocused: true,
            commandHeld: false,
            isEncodable: true
        )

        XCTAssertFalse(shouldCapture)
    }

    func testLocalInputCaptureIsBlockedWhileSearchFieldIsFocused() {
        let shouldCapture = DirectTerminalInputNSView.shouldCaptureLocalKeyEvent(
            isEnabled: true,
            hasSessionID: true,
            isLocalSession: true,
            keyWindowActive: true,
            textInputFocused: true,
            commandHeld: false,
            isEncodable: true
        )

        XCTAssertFalse(shouldCapture)
    }

    func testLocalInputCaptureResumesAfterTextInputFocusClears() {
        let blocked = DirectTerminalInputNSView.shouldCaptureLocalKeyEvent(
            isEnabled: true,
            hasSessionID: true,
            isLocalSession: true,
            keyWindowActive: true,
            textInputFocused: true,
            commandHeld: false,
            isEncodable: true
        )
        let resumed = DirectTerminalInputNSView.shouldCaptureLocalKeyEvent(
            isEnabled: true,
            hasSessionID: true,
            isLocalSession: true,
            keyWindowActive: true,
            textInputFocused: false,
            commandHeld: false,
            isEncodable: true
        )

        XCTAssertFalse(blocked)
        XCTAssertTrue(resumed)
    }

    func testLocalInputCaptureRequiresTerminalFocus() {
        let unfocused = DirectTerminalInputNSView.shouldCaptureLocalKeyEvent(
            isEnabled: true,
            hasSessionID: true,
            isLocalSession: true,
            keyWindowActive: true,
            textInputFocused: false,
            commandHeld: false,
            isEncodable: true,
            terminalFocused: false
        )
        let focused = DirectTerminalInputNSView.shouldCaptureLocalKeyEvent(
            isEnabled: true,
            hasSessionID: true,
            isLocalSession: true,
            keyWindowActive: true,
            textInputFocused: false,
            commandHeld: false,
            isEncodable: true,
            terminalFocused: true
        )

        XCTAssertFalse(unfocused)
        XCTAssertTrue(focused)
    }
}
