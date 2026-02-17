// InputModeState.swift
// ProSSHV2
//
// Tracks terminal input encoding modes that affect key/paste behavior.

import Foundation

struct InputModeSnapshot: Sendable, Equatable {
    var applicationCursorKeys: Bool
    var applicationKeypad: Bool
    var bracketedPasteMode: Bool
    var mouseTracking: MouseTrackingMode
    var mouseEncoding: MouseEncoding

    static let `default` = InputModeSnapshot(
        applicationCursorKeys: false,
        applicationKeypad: false,
        bracketedPasteMode: false,
        mouseTracking: .none,
        mouseEncoding: .x10
    )
}

actor InputModeState {
    private(set) var applicationCursorKeys: Bool = false
    private(set) var applicationKeypad: Bool = false
    private(set) var bracketedPasteMode: Bool = false
    private(set) var mouseTracking: MouseTrackingMode = .none
    private(set) var mouseEncoding: MouseEncoding = .x10

    func snapshot() -> InputModeSnapshot {
        InputModeSnapshot(
            applicationCursorKeys: applicationCursorKeys,
            applicationKeypad: applicationKeypad,
            bracketedPasteMode: bracketedPasteMode,
            mouseTracking: mouseTracking,
            mouseEncoding: mouseEncoding
        )
    }

    func setApplicationCursorKeys(_ enabled: Bool) {
        applicationCursorKeys = enabled
    }

    func setApplicationKeypad(_ enabled: Bool) {
        applicationKeypad = enabled
    }

    func setBracketedPasteMode(_ enabled: Bool) {
        bracketedPasteMode = enabled
    }

    func setMouseTracking(_ mode: MouseTrackingMode) {
        mouseTracking = mode
    }

    func setMouseEncoding(_ encoding: MouseEncoding) {
        mouseEncoding = encoding
    }

    /// DECSTR (soft reset): reset cursor/keypad input modes; bracketed paste remains unchanged.
    func applySoftReset() {
        applicationCursorKeys = false
        applicationKeypad = false
        mouseTracking = .none
        mouseEncoding = .x10
    }

    /// RIS (full reset): reset all tracked input modes.
    func applyFullReset() {
        applicationCursorKeys = false
        applicationKeypad = false
        bracketedPasteMode = false
        mouseTracking = .none
        mouseEncoding = .x10
    }

    /// Initialize state from current grid flags.
    func syncFromGrid(_ grid: TerminalGrid) async {
        applicationCursorKeys = await grid.applicationCursorKeys
        applicationKeypad = await grid.applicationKeypad
        bracketedPasteMode = await grid.bracketedPasteMode
        mouseTracking = await grid.mouseTracking
        mouseEncoding = await grid.mouseEncoding
    }
}
