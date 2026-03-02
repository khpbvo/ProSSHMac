import XCTest
@testable import ProSSHMac

final class TerminalInputCaptureViewTests: XCTestCase {
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
}
