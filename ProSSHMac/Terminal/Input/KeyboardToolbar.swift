// KeyboardToolbar.swift
// ProSSHMac
//
// Data model types for keyboard toolbar (iOS View removed for macOS).

import Foundation

enum ToolbarModifierState: Sendable, Equatable {
    case off
    case oneShot
    case locked
}

enum KeyboardToolbarKey: String, CaseIterable, Hashable, Sendable {
    case tab
    case esc
    case ctrl
    case alt
    case up
    case down
    case left
    case right
    case pipe
    case tilde
    case slash
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12

    var label: String {
        switch self {
        case .tab: return "Tab"
        case .esc: return "Esc"
        case .ctrl: return "Ctrl"
        case .alt: return "Alt"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .pipe: return "|"
        case .tilde: return "~"
        case .slash: return "/"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }

    var isModifierToggle: Bool {
        self == .ctrl || self == .alt
    }

    var encodableKey: EncodableKey? {
        switch self {
        case .tab:
            return .tab
        case .esc:
            return .escape
        case .up:
            return .arrow(.up)
        case .down:
            return .arrow(.down)
        case .left:
            return .arrow(.left)
        case .right:
            return .arrow(.right)
        case .pipe:
            return .character("|")
        case .tilde:
            return .character("~")
        case .slash:
            return .character("/")
        case .f1:
            return .function(1)
        case .f2:
            return .function(2)
        case .f3:
            return .function(3)
        case .f4:
            return .function(4)
        case .f5:
            return .function(5)
        case .f6:
            return .function(6)
        case .f7:
            return .function(7)
        case .f8:
            return .function(8)
        case .f9:
            return .function(9)
        case .f10:
            return .function(10)
        case .f11:
            return .function(11)
        case .f12:
            return .function(12)
        case .ctrl, .alt:
            return nil
        }
    }
}

enum KeyboardToolbarLayoutStore {
    static let primaryKey = "terminal.input.toolbar.primaryLayout"
    static let secondaryKey = "terminal.input.toolbar.secondaryLayout"
}

enum KeyboardToolbarLayout {
    static let defaultPrimary: [KeyboardToolbarKey] = [
        .tab, .esc, .ctrl, .alt, .up, .down, .left, .right, .pipe, .tilde, .slash
    ]

    static let defaultSecondary: [KeyboardToolbarKey] = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12
    ]

    static func serialize(_ keys: [KeyboardToolbarKey]) -> String {
        keys.map(\.rawValue).joined(separator: ",")
    }

    static func parse(_ raw: String, fallback: [KeyboardToolbarKey]) -> [KeyboardToolbarKey] {
        let parsed = raw
            .split(separator: ",")
            .compactMap { KeyboardToolbarKey(rawValue: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }

        var result: [KeyboardToolbarKey] = []
        var seen = Set<KeyboardToolbarKey>()
        for key in parsed where !seen.contains(key) {
            seen.insert(key)
            result.append(key)
        }

        return result.isEmpty ? fallback : result
    }
}

struct KeyboardToolbarModifiers: Sendable, Equatable {
    var ctrl: ToolbarModifierState = .off
    var alt: ToolbarModifierState = .off
    private var lastCtrlTapTime: TimeInterval = -.infinity
    private var lastAltTapTime: TimeInterval = -.infinity

    mutating func toggleCtrl(now: TimeInterval) {
        ctrl = nextState(current: ctrl, lastTap: lastCtrlTapTime, now: now)
        lastCtrlTapTime = now
    }

    mutating func toggleAlt(now: TimeInterval) {
        alt = nextState(current: alt, lastTap: lastAltTapTime, now: now)
        lastAltTapTime = now
    }

    mutating func consumeOneShot() {
        if ctrl == .oneShot { ctrl = .off }
        if alt == .oneShot { alt = .off }
    }

    func activeKeyModifiers() -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if ctrl != .off { modifiers.insert(.ctrl) }
        if alt != .off { modifiers.insert(.alt) }
        return modifiers
    }

    private func nextState(
        current: ToolbarModifierState,
        lastTap: TimeInterval,
        now: TimeInterval
    ) -> ToolbarModifierState {
        let isDoubleTap = (now - lastTap) <= 0.3
        if isDoubleTap {
            return current == .locked ? .off : .locked
        }

        switch current {
        case .off:
            return .oneShot
        case .oneShot, .locked:
            return .off
        }
    }
}
