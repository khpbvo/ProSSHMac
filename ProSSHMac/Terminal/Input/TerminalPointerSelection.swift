// TerminalPointerSelection.swift
// ProSSHMac
//
// Turns left-mouse events into selection changes, the way Terminal.app does: a press clears the
// selection (or selects a word/line on a double/triple click), and a drag only starts selecting
// once the pointer leaves the cell it was pressed in. Trackpad clicks report sub-pixel drags, so
// selecting on the first drag event left a one-cell selection behind every click (Bug 85).

enum TerminalSelectionAction: Equatable {
    case none
    case clear
    case select(start: SelectionPoint, end: SelectionPoint, type: SelectionType)
}

struct TerminalPointerSelection {
    private var anchor: SelectionPoint?
    private var type: SelectionType = .character
    private var isSelecting = false

    mutating func mouseDown(at cell: SelectionPoint?, clickCount: Int) -> TerminalSelectionAction {
        anchor = cell
        switch clickCount {
        case ...1:
            type = .character
            isSelecting = false
            return .clear
        case 2:
            type = .word
        default:
            type = .line
        }
        guard let cell else {
            isSelecting = false
            return .clear
        }
        isSelecting = true
        return .select(start: cell, end: cell, type: type)
    }

    mutating func mouseDragged(to cell: SelectionPoint?) -> TerminalSelectionAction {
        guard let anchor, let cell else { return .none }
        if !isSelecting {
            guard cell != anchor else { return .none }
            isSelecting = true
        }
        return .select(start: anchor, end: cell, type: type)
    }

    mutating func mouseUp() -> TerminalSelectionAction {
        anchor = nil
        isSelecting = false
        return .none
    }
}
