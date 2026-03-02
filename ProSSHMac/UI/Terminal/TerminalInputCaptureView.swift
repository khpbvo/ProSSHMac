// Extracted from TerminalView.swift
import SwiftUI
import AppKit

// MetalTerminalSessionSurface and MetalTerminalSurfaceModel moved to MetalTerminalSessionSurface.swift

struct SafeTerminalRenderedLine: Identifiable {
    let id: String
    let lineNumber: Int
    let text: String
}

struct DirectTerminalInputCaptureView: NSViewRepresentable {
    let isEnabled: Bool
    let sessionID: UUID
    let activationNonce: Int
    let keyEncoderOptions: () -> KeyEncoderOptions
    var onCommandShortcut: ((HardwareKeyCommandAction) -> Void)?
    let onSendSequence: (UUID, String) -> Void

    func makeNSView(context: Context) -> DirectTerminalInputNSView {
        let view = DirectTerminalInputNSView(frame: .zero)
        view.isEnabled = isEnabled
        view.sessionID = sessionID
        view.activationNonce = activationNonce
        view.keyEncoderOptions = keyEncoderOptions
        view.onCommandShortcut = onCommandShortcut
        view.onSendSequence = onSendSequence
        view.armForKeyboardInputIfNeeded()
        return view
    }

    func updateNSView(_ nsView: DirectTerminalInputNSView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.sessionID = sessionID
        nsView.activationNonce = activationNonce
        nsView.keyEncoderOptions = keyEncoderOptions
        nsView.onCommandShortcut = onCommandShortcut
        nsView.onSendSequence = onSendSequence
        nsView.armForKeyboardInputIfNeeded()
    }
}

final class DirectTerminalInputNSView: NSView {
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            guard let window else { return }
            if !isEnabled, window.firstResponder === self {
                window.makeFirstResponder(nil)
            }
        }
    }
    var sessionID: UUID?
    var activationNonce: Int = 0 {
        didSet {
            if activationNonce != oldValue {
                armForKeyboardInputIfNeeded()
            }
        }
    }
    var keyEncoderOptions: (() -> KeyEncoderOptions)?
    var onCommandShortcut: ((HardwareKeyCommandAction) -> Void)?
    var onSendSequence: ((UUID, String) -> Void)?
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var keyEventMonitor: Any?

    override var acceptsFirstResponder: Bool {
        isEnabled
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        MainActor.assumeIsolated {
            removeActivationObservers()
            removeKeyEventMonitor()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeActivationObservers()
        removeKeyEventMonitor()

        guard let window else { return }
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.armForKeyboardInputIfNeeded()
            }
        }
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.armForKeyboardInputIfNeeded()
            }
        }

        // Intercept terminal-bound keyDown events before SwiftUI/AppKit
        // consume them for focus navigation or default controls.
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.shouldMonitorKeyDownEvent(event) else { return event }
            guard let sessionID = self.sessionID,
                  let sequence = self.encodeEvent(event) else {
                return event
            }
            self.onSendSequence?(sessionID, sequence)
            return nil // consume the event
        }
    }

    private func shouldMonitorKeyDownEvent(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        guard sessionID != nil else { return false }
        // Rely on terminal activation state instead of exact event.window
        // matching. SwiftUI/AppKit can route keyDown through wrapper views
        // where event.window identity checks are too strict.
        if window?.isKeyWindow == false { return false }
        if isTextInputFocusedInWindow() { return false }

        // Preserve AppKit/SwiftUI Command shortcuts.
        let commandHeld = event.modifierFlags.intersection([.command]).contains(.command)
        guard !commandHeld else { return false }

        // Only consume events we can encode for terminal delivery.
        return encodeEvent(event) != nil
    }

    func armForKeyboardInputIfNeeded() {
        guard isEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled, let window = self.window else { return }
            if self.isTextInputFocused(in: window) { return }
            if window.firstResponder === self { return }
            _ = window.makeFirstResponder(self)
        }
    }

    private func removeActivationObservers() {
        if let windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
            self.windowDidBecomeKeyObserver = nil
        }
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            self.appDidBecomeActiveObserver = nil
        }
    }

    private func removeKeyEventMonitor() {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isTextInputFocusedInWindow() {
            return super.performKeyEquivalent(with: event)
        }
        if handleCommandShortcut(event) {
            return true
        }
        // Intercept Tab / Shift-Tab before NSWindow uses them for focus
        // navigation.  Tab must reach the shell for tab-completion to work.
        if event.keyCode == 48 /* Tab */ {
            if isEnabled, let sessionID, let sequence = encodeEvent(event) {
                onSendSequence?(sessionID, sequence)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isTextInputFocusedInWindow() {
            super.keyDown(with: event)
            return
        }
        guard isEnabled,
              let sessionID,
              let sequence = encodeEvent(event) else {
            super.keyDown(with: event)
            return
        }
        onSendSequence?(sessionID, sequence)
    }

    @objc func copy(_ sender: Any?) {
        guard isEnabled else { return }
        onCommandShortcut?(.copy)
    }

    @objc func paste(_ sender: Any?) {
        guard isEnabled else { return }
        onCommandShortcut?(.paste)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(paste(_:)):
            return isEnabled
        default:
            return true
        }
    }

    // MARK: - Unified Encoding

    private func encodeEvent(_ event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])

        // Command-modified keys are handled by SwiftUI shortcut layer.
        if flags.contains(.command) { return nil }

        let modifiers = mapModifiers(event.modifierFlags)
        let options = keyEncoderOptions?() ?? .default
        let encoder = KeyEncoder(options: options)

        // 1. Special keys (arrows, Tab, Enter, Esc, F-keys, editing keys, Backspace, Delete).
        if let keyEvent = specialKeyEvent(keyCode: event.keyCode, modifiers: modifiers) {
            if let bytes = encoder.encode(keyEvent) {
                return String(bytes: bytes, encoding: .utf8) ?? String(bytes.map { Character(UnicodeScalar($0)) })
            }
            return nil
        }

        // 2. Ctrl+character — encode via KeyEncoder for proper control bytes.
        if modifiers.contains(.ctrl),
           let raw = event.charactersIgnoringModifiers, !raw.isEmpty {
            let ch = raw.first!
            if let scalar = ch.unicodeScalars.first,
               scalar.isASCII,
               (scalar.value < 0x20 || scalar.value == 0x7F) {
                return String(ch)
            }
            let keyEvent = KeyEvent(key: .character(ch), modifiers: modifiers)
            if let bytes = encoder.encode(keyEvent) {
                return String(bytes: bytes, encoding: .utf8) ?? String(bytes.map { Character(UnicodeScalar($0)) })
            }
            return nil
        }

        // 3. Alt/Option+character — ESC prefix + base character.
        if modifiers.contains(.alt),
           let raw = event.charactersIgnoringModifiers, !raw.isEmpty {
            let ch = raw.first!
            let keyEvent = KeyEvent(key: .character(ch), modifiers: modifiers)
            if let bytes = encoder.encode(keyEvent) {
                return String(bytes: bytes, encoding: .utf8) ?? String(bytes.map { Character(UnicodeScalar($0)) })
            }
            return nil
        }

        // 4. Regular characters (includes Shift effect: Shift+1→"!").
        if let characters = event.characters, !characters.isEmpty {
            return characters
        }

        return nil
    }

    // MARK: - Special Key Mapping

    private func specialKeyEvent(keyCode: UInt16, modifiers: KeyModifiers) -> KeyEvent? {
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

    // MARK: - Modifier Mapping

    private func mapModifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.alt) }
        if flags.contains(.control) { result.insert(.ctrl) }
        return result
    }

    // MARK: - Command Shortcuts

    private func handleCommandShortcut(_ event: NSEvent) -> Bool {
        if isTextInputFocusedInWindow() {
            return false
        }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return false
        }
        guard let onCommandShortcut else {
            return false
        }

        // First handle common edit shortcuts to keep copy/paste/select behavior
        // working even when this NSView is first responder.
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if !flags.contains(.shift) {
            switch key {
            case "c":
                onCommandShortcut(.copy)
                return true
            case "v":
                onCommandShortcut(.paste)
                return true
            case "k":
                onCommandShortcut(.clearScrollback)
                return true
            default:
                break
            }
        }

        // Common keycodes:
        // 24 = '=' / '+', 27 = '-' / '_', 29 = '0'
        switch event.keyCode {
        case 24:
            onCommandShortcut(.increaseFontSize)
            return true
        case 27:
            onCommandShortcut(.decreaseFontSize)
            return true
        case 29:
            onCommandShortcut(.resetFontSize)
            return true
        case 69: // keypad '+'
            onCommandShortcut(.increaseFontSize)
            return true
        case 78: // keypad '-'
            onCommandShortcut(.decreaseFontSize)
            return true
        default:
            break
        }

        // Fallback for non-US layouts.
        if key == "=" || key == "+" {
            onCommandShortcut(.increaseFontSize)
            return true
        }
        if key == "-" || key == "_" {
            onCommandShortcut(.decreaseFontSize)
            return true
        }
        if key == "0" {
            onCommandShortcut(.resetFontSize)
            return true
        }

        return false
    }

    private func isTextInputFocusedInWindow() -> Bool {
        guard let window else { return false }
        return isTextInputFocused(in: window)
    }

    private func isTextInputFocused(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder === self { return false }
        if responder is NSTextView { return true }
        return responder.responds(to: #selector(NSTextInputClient.insertText(_:replacementRange:)))
    }
}

// MARK: - iOS Fullscreen Terminal Keyboard Input (removed for macOS)

extension View {
    @ViewBuilder
    func terminalInputBehavior() -> some View {
        self
    }
}

struct TerminalScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct TerminalScrollContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
