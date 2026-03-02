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
    let isLocalSession: Bool
    let activationNonce: Int
    let keyEncoderOptions: () -> KeyEncoderOptions
    var onCommandShortcut: ((HardwareKeyCommandAction) -> Void)?
    let onSendSequence: (UUID, String) -> Void
    var onSendBytes: ((UUID, [UInt8], String) -> Void)?

    func makeNSView(context: Context) -> DirectTerminalInputNSView {
        let view = DirectTerminalInputNSView(frame: .zero)
        view.isEnabled = isEnabled
        view.sessionID = sessionID
        view.isLocalSession = isLocalSession
        view.activationNonce = activationNonce
        view.keyEncoderOptions = keyEncoderOptions
        view.onCommandShortcut = onCommandShortcut
        view.onSendSequence = onSendSequence
        view.onSendBytes = onSendBytes
        view.armForKeyboardInputIfNeeded()
        return view
    }

    func updateNSView(_ nsView: DirectTerminalInputNSView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.sessionID = sessionID
        nsView.isLocalSession = isLocalSession
        nsView.activationNonce = activationNonce
        nsView.keyEncoderOptions = keyEncoderOptions
        nsView.onCommandShortcut = onCommandShortcut
        nsView.onSendSequence = onSendSequence
        nsView.onSendBytes = onSendBytes
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
    var isLocalSession = false
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
    var onSendBytes: ((UUID, [UInt8], String) -> Void)?
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
            guard self.dispatchEncodedEvent(event) else { return event }
            return nil // consume the event
        }
    }

    func shouldMonitorKeyDownEvent(_ event: NSEvent) -> Bool {
        // Rely on terminal activation state instead of exact event.window
        // matching. SwiftUI/AppKit can route keyDown through wrapper views
        // where event.window identity checks are too strict.
        let keyWindowActive = window?.isKeyWindow ?? true
        let textInputFocused = isTextInputFocusedInWindow()
        let commandHeld = event.modifierFlags.intersection([.command]).contains(.command)
        let encodable = encodeEventBytes(event) != nil

        return Self.shouldCaptureLocalKeyEvent(
            isEnabled: isEnabled,
            hasSessionID: sessionID != nil,
            isLocalSession: isLocalSession,
            keyWindowActive: keyWindowActive,
            textInputFocused: textInputFocused,
            commandHeld: commandHeld,
            isEncodable: encodable
        )
    }

    static func shouldCaptureLocalKeyEvent(
        isEnabled: Bool,
        hasSessionID: Bool,
        isLocalSession: Bool,
        keyWindowActive: Bool,
        textInputFocused: Bool,
        commandHeld: Bool,
        isEncodable: Bool
    ) -> Bool {
        guard isEnabled else { return false }
        guard hasSessionID else { return false }
        guard isLocalSession else { return false }
        guard keyWindowActive else { return false }
        guard !textInputFocused else { return false }
        guard !commandHeld else { return false }
        return isEncodable
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
        // Intercept Tab / Shift-Tab before NSWindow uses them for focus
        // navigation.  Tab must reach the shell for tab-completion to work.
        // This applies to BOTH local and remote sessions — without it,
        // AppKit's default Tab handling steals focus to the next responder
        // and all subsequent keys are lost to the terminal.
        if event.keyCode == 48 /* Tab */ {
            if dispatchEncodedEvent(event) {
                return true
            }
        }
        if isLocalSession {
            return super.performKeyEquivalent(with: event)
        }
        if handleCommandShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isLocalSession {
            super.keyDown(with: event)
            return
        }
        if isTextInputFocusedInWindow() {
            super.keyDown(with: event)
            return
        }
        guard dispatchEncodedEvent(event) else {
            super.keyDown(with: event)
            return
        }
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

    private func dispatchEncodedEvent(_ event: NSEvent) -> Bool {
        guard isEnabled, let sessionID else { return false }
        guard let bytes = encodeEventBytes(event) else { return false }

        if isLocalSession {
            guard let onSendBytes else { return false }
            onSendBytes(sessionID, bytes, localInputEventType(for: event))
            return true
        }

        guard let sequence = String(bytes: bytes, encoding: .utf8) else {
            return false
        }
        onSendSequence?(sessionID, sequence)
        return true
    }

    private func localInputEventType(for event: NSEvent) -> String {
        let modifiers = mapModifiers(event.modifierFlags)
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

    private func encodeEventBytes(_ event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])

        // Command-modified keys are handled by SwiftUI shortcut layer.
        if flags.contains(.command) { return nil }

        let modifiers = mapModifiers(event.modifierFlags)
        let options = keyEncoderOptions?() ?? .default
        let encoder = KeyEncoder(options: options)

        // 1. Special keys (arrows, Tab, Enter, Esc, F-keys, editing keys, Backspace, Delete).
        if let keyEvent = specialKeyEvent(keyCode: event.keyCode, modifiers: modifiers) {
            return encoder.encode(keyEvent)
        }

        // 2. Ctrl+character — encode via KeyEncoder for proper control bytes.
        if modifiers.contains(.ctrl),
           let raw = event.charactersIgnoringModifiers, !raw.isEmpty {
            let ch = raw.first!
            if let scalar = ch.unicodeScalars.first,
               scalar.isASCII,
               (scalar.value < 0x20 || scalar.value == 0x7F) {
                return [UInt8(scalar.value)]
            }
            let keyEvent = KeyEvent(key: .character(ch), modifiers: modifiers)
            return encoder.encode(keyEvent)
        }

        // 3. Alt/Option+character — ESC prefix + base character.
        if modifiers.contains(.alt),
           let raw = event.charactersIgnoringModifiers, !raw.isEmpty {
            let ch = raw.first!
            let keyEvent = KeyEvent(key: .character(ch), modifiers: modifiers)
            return encoder.encode(keyEvent)
        }

        // 4. Regular characters (includes Shift effect: Shift+1→"!").
        if let characters = event.characters, !characters.isEmpty {
            return Array(characters.utf8)
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

    private func specialKeyLabel(for keyCode: UInt16) -> String? {
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
