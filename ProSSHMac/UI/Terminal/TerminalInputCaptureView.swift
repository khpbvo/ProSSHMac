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
            refreshLocalKeyEventMonitor()
        }
    }
    var sessionID: UUID? {
        didSet {
            refreshLocalKeyEventMonitor()
        }
    }
    var isLocalSession = false {
        didSet {
            refreshLocalKeyEventMonitor()
        }
    }
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
    private var localKeyEventMonitor: Any?

    override var acceptsFirstResponder: Bool {
        isEnabled
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        MainActor.assumeIsolated {
            removeActivationObservers()
            removeLocalKeyEventMonitor()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeActivationObservers()
        removeLocalKeyEventMonitor()

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

        refreshLocalKeyEventMonitor()
    }

    static func shouldCaptureLocalKeyEvent(
        isEnabled: Bool,
        hasSessionID: Bool,
        isLocalSession: Bool,
        keyWindowActive: Bool,
        textInputFocused: Bool,
        commandHeld: Bool,
        isEncodable: Bool,
        terminalFocused: Bool = true
    ) -> Bool {
        guard isLocalSession else { return false }
        return LocalTerminalSubsystem.shouldCaptureHardwareKeyEvent(
            isEnabled: isEnabled,
            hasSessionID: hasSessionID,
            keyWindowActive: keyWindowActive,
            terminalFocused: terminalFocused,
            textInputFocused: textInputFocused,
            commandHeld: commandHeld,
            isEncodable: isEncodable
        )
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

    private func refreshLocalKeyEventMonitor() {
        removeLocalKeyEventMonitor()
        guard isLocalSession else { return }
        localKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.shouldMonitorLocalKeyEvent(event) else { return event }
            guard self.dispatchEncodedEvent(event) else { return event }
            return nil
        }
    }

    private func removeLocalKeyEventMonitor() {
        if let localKeyEventMonitor {
            NSEvent.removeMonitor(localKeyEventMonitor)
            self.localKeyEventMonitor = nil
        }
    }

    private func shouldMonitorLocalKeyEvent(_ event: NSEvent) -> Bool {
        guard isLocalSession else { return false }

        let commandHeld = event.modifierFlags.intersection([.command]).contains(.command)
        let keyWindowActive = window?.isKeyWindow ?? true
        let textInputFocused = isTextInputFocusedInWindow()
        guard let payload = localInputPayload(for: event) else { return false }

        return Self.shouldCaptureLocalKeyEvent(
            isEnabled: isEnabled,
            hasSessionID: sessionID != nil,
            isLocalSession: true,
            keyWindowActive: keyWindowActive,
            textInputFocused: textInputFocused,
            commandHeld: commandHeld,
            isEncodable: !payload.bytes.isEmpty,
            terminalFocused: true
        )
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isTextInputFocusedInWindow() {
            return super.performKeyEquivalent(with: event)
        }
        if handleCommandShortcut(event) {
            return true
        }
        if dispatchEncodedEvent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
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

        if isLocalSession {
            guard let payload = localInputPayload(for: event) else { return false }
            guard shouldCaptureLocalEvent(event, payload: payload) else { return false }
            guard let onSendBytes else { return false }
            onSendBytes(sessionID, payload.bytes, payload.eventType)
            return true
        }

        guard let bytes = encodeEventBytes(event) else { return false }
        guard let sequence = String(bytes: bytes, encoding: .utf8) else {
            return false
        }
        onSendSequence?(sessionID, sequence)
        return true
    }

    private func localInputPayload(for event: NSEvent) -> LocalTerminalInputPayload? {
        let options = keyEncoderOptions?() ?? .default
        return LocalTerminalSubsystem.encodeKeyEvent(event, options: options)
    }

    private func shouldCaptureLocalEvent(_ event: NSEvent, payload: LocalTerminalInputPayload) -> Bool {
        let commandHeld = event.modifierFlags.intersection([.command]).contains(.command)
        let keyWindowActive = window?.isKeyWindow ?? true
        let textInputFocused = isTextInputFocusedInWindow()

        // Pass terminalFocused: true here. This method is only called from
        // dispatchEncodedEvent, which is invoked from keyDown and performKeyEquivalent
        // — both of which only reach this view when it is in the active responder
        // chain. The local monitor path already hardcodes terminalFocused: true in
        // shouldMonitorLocalKeyEvent. The armForKeyboardInputIfNeeded() call is
        // deferred async, so isTerminalFocused (firstResponder === self) can be
        // transiently false even when the terminal is the active input context,
        // causing Tab and Ctrl+C (key equivalents) to be silently dropped.
        return Self.shouldCaptureLocalKeyEvent(
            isEnabled: isEnabled,
            hasSessionID: sessionID != nil,
            isLocalSession: isLocalSession,
            keyWindowActive: keyWindowActive,
            textInputFocused: textInputFocused,
            commandHeld: commandHeld,
            isEncodable: !payload.bytes.isEmpty,
            terminalFocused: true
        )
    }

    private func encodeEventBytes(_ event: NSEvent) -> [UInt8]? {
        let options = keyEncoderOptions?() ?? .default
        return LocalTerminalSubsystem.encodeKeyEvent(event, options: options)?.bytes
    }

    private var isTerminalFocused: Bool {
        guard let window else { return false }
        return window.firstResponder === self
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
