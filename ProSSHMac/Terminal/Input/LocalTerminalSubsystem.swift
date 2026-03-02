// LocalTerminalSubsystem.swift
// ProSSHMac
//
// Local terminal input policy + key-event encoding.
// Defines a single byte-first local input route:
// capture -> encode -> send bytes to local PTY.

import Foundation
import AppKit

struct LocalTerminalInputPayload: Sendable {
    let bytes: [UInt8]
    let eventType: String
}

enum LocalTerminalSubsystem {
    static func shouldCaptureHardwareKeyEvent(
        isEnabled: Bool,
        hasSessionID: Bool,
        keyWindowActive: Bool,
        terminalFocused: Bool,
        textInputFocused: Bool,
        commandHeld: Bool,
        isEncodable: Bool
    ) -> Bool {
        guard isEnabled else { return false }
        guard hasSessionID else { return false }
        guard keyWindowActive else { return false }
        guard terminalFocused else { return false }
        guard !textInputFocused else { return false }
        guard !commandHeld else { return false }
        return isEncodable
    }

    static func encodeKeyEvent(_ event: NSEvent, options: KeyEncoderOptions) -> LocalTerminalInputPayload? {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if flags.contains(.command) {
            return nil
        }

        let modifiers = mapModifiers(event.modifierFlags)
        let encoder = KeyEncoder(options: options)

        if let keyEvent = specialKeyEvent(keyCode: event.keyCode, modifiers: modifiers),
           let bytes = encoder.encode(keyEvent) {
            return LocalTerminalInputPayload(
                bytes: bytes,
                eventType: localInputEventType(for: event, modifiers: modifiers)
            )
        }

        if modifiers.contains(.ctrl),
           let raw = event.charactersIgnoringModifiers,
           !raw.isEmpty {
            let ch = raw.first!
            if let scalar = ch.unicodeScalars.first,
               scalar.isASCII,
               (scalar.value < 0x20 || scalar.value == 0x7F) {
                return LocalTerminalInputPayload(
                    bytes: [UInt8(scalar.value)],
                    eventType: localInputEventType(for: event, modifiers: modifiers)
                )
            }
            let keyEvent = KeyEvent(key: .character(ch), modifiers: modifiers)
            if let bytes = encoder.encode(keyEvent) {
                return LocalTerminalInputPayload(
                    bytes: bytes,
                    eventType: localInputEventType(for: event, modifiers: modifiers)
                )
            }
            return nil
        }

        if modifiers.contains(.alt),
           let raw = event.charactersIgnoringModifiers,
           !raw.isEmpty {
            let ch = raw.first!
            let keyEvent = KeyEvent(key: .character(ch), modifiers: modifiers)
            if let bytes = encoder.encode(keyEvent) {
                return LocalTerminalInputPayload(
                    bytes: bytes,
                    eventType: localInputEventType(for: event, modifiers: modifiers)
                )
            }
            return nil
        }

        if let characters = event.characters, !characters.isEmpty {
            return LocalTerminalInputPayload(
                bytes: Array(characters.utf8),
                eventType: localInputEventType(for: event, modifiers: modifiers)
            )
        }

        return nil
    }

    private static func localInputEventType(for event: NSEvent, modifiers: KeyModifiers) -> String {
        if let label = specialKeyLabel(for: event.keyCode) {
            return label
        }
        if modifiers.contains(.ctrl) { return "ctrl_character" }
        if modifiers.contains(.alt) { return "alt_character" }
        if let characters = event.characters, !characters.isEmpty {
            return characters.count == 1 ? "character" : "text_sequence"
        }
        return "unknown"
    }

    private static func mapModifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.alt) }
        if flags.contains(.control) { result.insert(.ctrl) }
        return result
    }

    private static func specialKeyEvent(keyCode: UInt16, modifiers: KeyModifiers) -> KeyEvent? {
        let key: EncodableKey
        switch keyCode {
        case 126: key = .arrow(.up)
        case 125: key = .arrow(.down)
        case 124: key = .arrow(.right)
        case 123: key = .arrow(.left)
        case 36, 76: key = .enter
        case 48: key = .tab
        case 53: key = .escape
        case 51: key = .backspace
        case 117: key = .editing(.delete)
        case 115: key = .editing(.home)
        case 119: key = .editing(.end)
        case 116: key = .editing(.pageUp)
        case 121: key = .editing(.pageDown)
        case 114: key = .editing(.insert)
        case 122: key = .function(1)
        case 120: key = .function(2)
        case 99:  key = .function(3)
        case 118: key = .function(4)
        case 96:  key = .function(5)
        case 97:  key = .function(6)
        case 98:  key = .function(7)
        case 100: key = .function(8)
        case 101: key = .function(9)
        case 109: key = .function(10)
        case 103: key = .function(11)
        case 111: key = .function(12)
        default: return nil
        }
        return KeyEvent(key: key, modifiers: modifiers)
    }

    private static func specialKeyLabel(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 126: return "arrow_up"
        case 125: return "arrow_down"
        case 124: return "arrow_right"
        case 123: return "arrow_left"
        case 36, 76: return "enter"
        case 48: return "tab"
        case 53: return "escape"
        case 51: return "backspace"
        case 117: return "delete"
        case 115: return "home"
        case 119: return "end"
        case 116: return "page_up"
        case 121: return "page_down"
        case 114: return "insert"
        case 122: return "function_f1"
        case 120: return "function_f2"
        case 99:  return "function_f3"
        case 118: return "function_f4"
        case 96:  return "function_f5"
        case 97:  return "function_f6"
        case 98:  return "function_f7"
        case 100: return "function_f8"
        case 101: return "function_f9"
        case 109: return "function_f10"
        case 103: return "function_f11"
        case 111: return "function_f12"
        default: return nil
        }
    }
}
