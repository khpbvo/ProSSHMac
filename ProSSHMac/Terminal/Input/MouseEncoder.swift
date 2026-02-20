// MouseEncoder.swift
// ProSSHV2
//
// Encodes terminal mouse events and maps platform pointer input.

import Foundation
import CoreGraphics

enum MouseButton: Sendable {
    case left
    case middle
    case right
    case none
}

struct MouseEventModifiers: OptionSet, Sendable, Hashable {
    let rawValue: Int

    static let shift = MouseEventModifiers(rawValue: 1 << 0)
    static let alt = MouseEventModifiers(rawValue: 1 << 1)
    static let ctrl = MouseEventModifiers(rawValue: 1 << 2)
}

enum MouseEventKind: Sendable {
    case press
    case release
    case move
    case scrollUp
    case scrollDown
}

struct MouseEvent: Sendable {
    var kind: MouseEventKind
    var button: MouseButton
    var row: Int
    var column: Int
    var modifiers: MouseEventModifiers

    init(
        kind: MouseEventKind,
        button: MouseButton,
        row: Int,
        column: Int,
        modifiers: MouseEventModifiers = []
    ) {
        self.kind = kind
        self.button = button
        self.row = row
        self.column = column
        self.modifiers = modifiers
    }
}

struct MouseEncoder: Sendable {
    var trackingMode: MouseTrackingMode
    var encoding: MouseEncoding

    init(trackingMode: MouseTrackingMode, encoding: MouseEncoding) {
        self.trackingMode = trackingMode
        self.encoding = encoding
    }

    init(modeSnapshot: InputModeSnapshot) {
        self.init(trackingMode: modeSnapshot.mouseTracking, encoding: modeSnapshot.mouseEncoding)
    }

    func encode(_ event: MouseEvent) -> String? {
        guard shouldSend(event) else { return nil }
        guard let buttonCode = encodedButtonCode(for: event) else { return nil }

        switch encoding {
        case .sgr:
            return encodeSGR(buttonCode: buttonCode, event: event)
        case .x10, .utf8:
            // UTF-8 mouse encoding (1005) is not implemented yet; use X10-compatible bytes.
            return encodeX10(buttonCode: buttonCode, event: event)
        }
    }

    private func shouldSend(_ event: MouseEvent) -> Bool {
        switch trackingMode {
        case .none:
            return false
        case .x10:
            switch event.kind {
            case .press, .scrollUp, .scrollDown:
                return true
            case .release, .move:
                return false
            }
        case .buttonEvent:
            switch event.kind {
            case .press, .release, .scrollUp, .scrollDown:
                return true
            case .move:
                return event.button != .none
            }
        case .anyEvent:
            return true
        }
    }

    private func encodedButtonCode(for event: MouseEvent) -> Int? {
        let baseCode: Int
        switch event.kind {
        case .press:
            switch event.button {
            case .left: baseCode = 0
            case .middle: baseCode = 1
            case .right: baseCode = 2
            case .none: return nil
            }
        case .release:
            baseCode = 3
        case .move:
            switch event.button {
            case .left: baseCode = 32
            case .middle: baseCode = 33
            case .right: baseCode = 34
            case .none: baseCode = 35
            }
        case .scrollUp:
            baseCode = 64
        case .scrollDown:
            baseCode = 65
        }

        var code = baseCode
        if event.modifiers.contains(.shift) { code += 4 }
        if event.modifiers.contains(.alt) { code += 8 }
        if event.modifiers.contains(.ctrl) { code += 16 }
        return code
    }

    private func encodeX10(buttonCode: Int, event: MouseEvent) -> String? {
        let col = max(1, min(223, event.column))
        let row = max(1, min(223, event.row))

        let bytes: [UInt8] = [
            0x1B,
            0x5B,
            0x4D,
            UInt8(clamping: buttonCode + 32),
            UInt8(clamping: col + 32),
            UInt8(clamping: row + 32)
        ]
        // Use .isoLatin1 instead of .utf8 because X10 mouse encoding
        // produces raw bytes 0x20-0xFF which may include invalid UTF-8
        // continuation bytes (0x80-0xBF), causing String(encoding: .utf8)
        // to return nil.
        return String(bytes: bytes, encoding: .isoLatin1)
    }

    private func encodeSGR(buttonCode: Int, event: MouseEvent) -> String {
        // SGR mouse encoding uses 1-based coordinates; grid coordinates are 0-based.
        let col = max(1, event.column + 1)
        let row = max(1, event.row + 1)
        let suffix = event.kind == .release ? "m" : "M"
        return "\u{1B}[<\(buttonCode);\(col);\(row)\(suffix)"
    }
}

import SwiftUI
import AppKit

struct MouseInputHandler: NSViewRepresentable {
    var isEnabled: Bool
    var modeSnapshot: () -> InputModeSnapshot
    var locationToCell: (CGPoint) -> (row: Int, col: Int)?
    var onSendSequence: (String) -> Void

    func makeNSView(context: Context) -> MouseInputCaptureView {
        MouseInputCaptureView()
    }

    func updateNSView(_ nsView: MouseInputCaptureView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.modeSnapshot = modeSnapshot
        nsView.locationToCell = locationToCell
        nsView.onSendSequence = onSendSequence
    }
}

final class MouseInputCaptureView: NSView {
    var isEnabled = false {
        didSet {
            needsDisplay = true
            updateTrackingAreas()
            if !isEnabled {
                activeButton = .none
                scrollAccumulator = 0
            }
        }
    }
    var modeSnapshot: () -> InputModeSnapshot = {
        .default
    }
    var locationToCell: (CGPoint) -> (row: Int, col: Int)? = { _ in nil }
    var onSendSequence: (String) -> Void = { _ in }

    private var trackingAreaRef: NSTrackingArea?
    private var activeButton: MouseButton = .none
    private var scrollAccumulator: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
            self.trackingAreaRef = nil
        }

        guard isEnabled else { return }

        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseDown(with event: NSEvent) {
        activeButton = .left
        send(kind: .press, button: .left, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        send(kind: .release, button: .left, event: event)
        activeButton = .none
    }

    override func rightMouseDown(with event: NSEvent) {
        activeButton = .right
        send(kind: .press, button: .right, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        send(kind: .release, button: .right, event: event)
        activeButton = .none
    }

    override func otherMouseDown(with event: NSEvent) {
        activeButton = .middle
        send(kind: .press, button: .middle, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        send(kind: .release, button: .middle, event: event)
        activeButton = .none
    }

    override func mouseDragged(with event: NSEvent) {
        send(kind: .move, button: .left, event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        send(kind: .move, button: .right, event: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        send(kind: .move, button: .middle, event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let button = activeButton == .none ? MouseButton.none : activeButton
        send(kind: .move, button: button, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else {
            super.scrollWheel(with: event)
            return
        }

        let mode = modeSnapshot()
        guard mode.mouseTracking != .none else {
            super.scrollWheel(with: event)
            return
        }

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 8 : 1
        scrollAccumulator += event.scrollingDeltaY

        while abs(scrollAccumulator) >= threshold {
            if scrollAccumulator > 0 {
                send(kind: .scrollUp, button: .none, event: event)
                scrollAccumulator -= threshold
            } else {
                send(kind: .scrollDown, button: .none, event: event)
                scrollAccumulator += threshold
            }
        }
    }

    private func send(kind: MouseEventKind, button: MouseButton, event: NSEvent) {
        guard isEnabled else { return }

        let location = convert(event.locationInWindow, from: nil)
        guard let cell = locationToCell(location) else { return }

        let snapshot = modeSnapshot()
        let encoder = MouseEncoder(modeSnapshot: snapshot)
        let mouseEvent = MouseEvent(
            kind: kind,
            button: button,
            row: cell.row,
            column: cell.col,
            modifiers: mapModifiers(event.modifierFlags)
        )
        guard let sequence = encoder.encode(mouseEvent) else { return }

        onSendSequence(sequence)
    }

    private func mapModifiers(_ flags: NSEvent.ModifierFlags) -> MouseEventModifiers {
        var modifiers: MouseEventModifiers = []
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.option) {
            modifiers.insert(.alt)
        }
        if flags.contains(.control) {
            modifiers.insert(.ctrl)
        }
        return modifiers
    }
}
