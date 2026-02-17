// HardwareKeyHandler.swift
// ProSSHMac
//
// Hardware key command action enum (used by pane shortcuts on macOS).

import Foundation

enum HardwareKeyCommandAction: Equatable, Sendable {
    case copy
    case paste
    case clearScrollback
    case newSession
    case newTab
    case closeSession
    case switchTab(Int) // 1-based
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize
    // Split pane actions
    case splitVertical
    case splitHorizontal
    case closePane
    case focusNextPane
    case focusPrevPane
    case maximizeToggle
    case newLocalTerminal
}

enum HardwarePasteEncoder {
    static func payload(for text: String, bracketedPasteEnabled: Bool) -> String {
        PasteHandler.payload(for: text, bracketedPasteEnabled: bracketedPasteEnabled)
    }
}
