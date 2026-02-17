// KeyEncoder.swift
// ProSSHV2
//
// Encodes key events into terminal byte sequences.

import Foundation

struct KeyModifiers: OptionSet, Sendable, Hashable {
    let rawValue: Int

    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let alt = KeyModifiers(rawValue: 1 << 1)
    static let ctrl = KeyModifiers(rawValue: 1 << 2)
}

enum ArrowKey: Sendable {
    case up
    case down
    case right
    case left
}

enum EditingKey: Sendable {
    case insert
    case delete
    case home
    case end
    case pageUp
    case pageDown
}

enum EncodableKey: Sendable {
    case character(Character)
    case arrow(ArrowKey)
    case function(Int)
    case editing(EditingKey)
    case backspace
    case enter
    case tab
    case escape
}

struct KeyEvent: Sendable {
    var key: EncodableKey
    var modifiers: KeyModifiers

    init(key: EncodableKey, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

struct KeyEncoderOptions: Sendable {
    var applicationCursorKeys: Bool = false
    var backspaceSendsDelete: Bool = true // DEL (0x7F). If false, sends BS (0x08).
    var enterSendsCRLF: Bool = false

    static let `default` = KeyEncoderOptions()
}

struct KeyEncoder: Sendable {
    var options: KeyEncoderOptions

    init(options: KeyEncoderOptions = .default) {
        self.options = options
    }

    func encode(_ event: KeyEvent) -> [UInt8]? {
        switch event.key {
        case let .character(character):
            return encodeCharacter(character, modifiers: event.modifiers)
        case let .arrow(arrow):
            return encodeArrow(arrow, modifiers: event.modifiers)
        case let .function(index):
            return encodeFunction(index, modifiers: event.modifiers)
        case let .editing(key):
            return encodeEditing(key, modifiers: event.modifiers)
        case .backspace:
            return encodeBackspace(modifiers: event.modifiers)
        case .enter:
            return encodeEnter(modifiers: event.modifiers)
        case .tab:
            return encodeTab(modifiers: event.modifiers)
        case .escape:
            return encodeEscape(modifiers: event.modifiers)
        }
    }

    // MARK: - Character Encoding

    private func encodeCharacter(_ character: Character, modifiers: KeyModifiers) -> [UInt8]? {
        if modifiers.contains(.ctrl) {
            guard let byte = controlByte(for: character) else {
                return nil
            }
            return maybePrefixEscape([byte], modifiers: modifiers)
        }

        let bytes = bytesForCharacter(character)
        guard !bytes.isEmpty else { return nil }
        return maybePrefixEscape(bytes, modifiers: modifiers)
    }

    private func controlByte(for character: Character) -> UInt8? {
        let value = String(character).uppercased()

        if value.count == 1, let scalar = value.unicodeScalars.first {
            switch scalar.value {
            case 0x41...0x5A: // A-Z
                return UInt8(scalar.value - 0x40)
            case 0x40: // @
                return 0x00
            case 0x5B: // [
                return 0x1B
            case 0x5C: // \
                return 0x1C
            case 0x5D: // ]
                return 0x1D
            case 0x5E: // ^
                return 0x1E
            case 0x5F: // _
                return 0x1F
            case 0x3F: // ?
                return 0x7F
            default:
                return nil
            }
        }

        return nil
    }

    // MARK: - Special Key Encoding

    private func encodeArrow(_ key: ArrowKey, modifiers: KeyModifiers) -> [UInt8] {
        let final: Character
        switch key {
        case .up: final = "A"
        case .down: final = "B"
        case .right: final = "C"
        case .left: final = "D"
        }

        if let mod = xtermModifierParameter(from: modifiers) {
            return csi("1;\(mod)\(final)")
        }

        if options.applicationCursorKeys {
            return escO(final)
        }

        return csi("\(final)")
    }

    private func encodeFunction(_ index: Int, modifiers: KeyModifiers) -> [UInt8]? {
        guard (1...12).contains(index) else { return nil }

        // F1-F4 are SS3 in unmodified mode.
        if (1...4).contains(index) {
            let finals: [Character] = ["P", "Q", "R", "S"]
            let final = finals[index - 1]
            if let mod = xtermModifierParameter(from: modifiers) {
                return csi("1;\(mod)\(final)")
            }
            return escO(final)
        }

        let tildeCodes: [Int: Int] = [
            5: 15,
            6: 17,
            7: 18,
            8: 19,
            9: 20,
            10: 21,
            11: 23,
            12: 24
        ]
        guard let code = tildeCodes[index] else { return nil }

        if let mod = xtermModifierParameter(from: modifiers) {
            return csi("\(code);\(mod)~")
        }

        return csi("\(code)~")
    }

    private func encodeEditing(_ key: EditingKey, modifiers: KeyModifiers) -> [UInt8] {
        switch key {
        case .insert:
            return encodeTildeEditing(code: 2, modifiers: modifiers)
        case .delete:
            return encodeTildeEditing(code: 3, modifiers: modifiers)
        case .pageUp:
            return encodeTildeEditing(code: 5, modifiers: modifiers)
        case .pageDown:
            return encodeTildeEditing(code: 6, modifiers: modifiers)
        case .home:
            if let mod = xtermModifierParameter(from: modifiers) {
                return csi("1;\(mod)H")
            }
            return csi("H")
        case .end:
            if let mod = xtermModifierParameter(from: modifiers) {
                return csi("1;\(mod)F")
            }
            return csi("F")
        }
    }

    private func encodeTildeEditing(code: Int, modifiers: KeyModifiers) -> [UInt8] {
        if let mod = xtermModifierParameter(from: modifiers) {
            return csi("\(code);\(mod)~")
        }
        return csi("\(code)~")
    }

    private func encodeBackspace(modifiers: KeyModifiers) -> [UInt8] {
        // Ctrl+Backspace conventionally maps to DEL.
        if modifiers.contains(.ctrl) {
            return maybePrefixEscape([0x7F], modifiers: modifiers)
        }

        let base: UInt8 = options.backspaceSendsDelete ? 0x7F : 0x08
        return maybePrefixEscape([base], modifiers: modifiers)
    }

    private func encodeEnter(modifiers: KeyModifiers) -> [UInt8] {
        let base: [UInt8] = options.enterSendsCRLF ? [0x0D, 0x0A] : [0x0D]
        return maybePrefixEscape(base, modifiers: modifiers)
    }

    private func encodeTab(modifiers: KeyModifiers) -> [UInt8] {
        if modifiers == .shift {
            return csi("Z") // Back-tab
        }

        return maybePrefixEscape([0x09], modifiers: modifiers)
    }

    private func encodeEscape(modifiers: KeyModifiers) -> [UInt8] {
        maybePrefixEscape([0x1B], modifiers: modifiers)
    }

    // MARK: - Helpers

    private func xtermModifierParameter(from modifiers: KeyModifiers) -> Int? {
        let relevant = modifiers.intersection([.shift, .alt, .ctrl])
        guard !relevant.isEmpty else { return nil }

        var value = 1
        if relevant.contains(.shift) { value += 1 }
        if relevant.contains(.alt) { value += 2 }
        if relevant.contains(.ctrl) { value += 4 }
        return value
    }

    private func bytesForCharacter(_ character: Character) -> [UInt8] {
        let string = String(character)
        guard !string.isEmpty else { return [] }

        if let scalar = string.unicodeScalars.first,
           string.unicodeScalars.count == 1,
           scalar.isASCII {
            return [UInt8(scalar.value)]
        }

        // Keep non-ASCII usable for modern shells while remaining ASCII-correct.
        return [UInt8](string.utf8)
    }

    private func maybePrefixEscape(_ bytes: [UInt8], modifiers: KeyModifiers) -> [UInt8] {
        guard modifiers.contains(.alt) else {
            return bytes
        }
        return [0x1B] + bytes
    }

    private func csi(_ payload: String) -> [UInt8] {
        [0x1B, 0x5B] + payload.utf8
    }

    private func escO(_ final: Character) -> [UInt8] {
        [0x1B, 0x4F, UInt8(final.asciiValue ?? 0)]
    }
}
