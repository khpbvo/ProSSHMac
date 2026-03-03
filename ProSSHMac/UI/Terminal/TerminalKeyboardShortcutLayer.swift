// Extracted from TerminalView.swift
import SwiftUI

struct TerminalKeyboardShortcutLayer: View {
    var onSendCommand:          () -> Void
    var onSendCtrlC:            () -> Void
    var onSendCtrlD:            () -> Void
    var onShowSearch:           () -> Void
    var onToggleQuickCommands:  () -> Void
    var onToggleFileBrowser:    () -> Void
    var onToggleAIAssistant:    () -> Void
    var onClearBuffer:          () -> Void
    var onPreviousSession:      () -> Void
    var onNextSession:          () -> Void
    var onDisconnectOrClose:    () -> Void
    var onSplitRight:           () -> Void
    var onSplitDown:            () -> Void
    var onFocusNextPane:        () -> Void
    var onFocusPreviousPane:    () -> Void
    var onMaximizePane:         () -> Void
    var onNewLocalTerminal:     () -> Void
    var onZoomIn:               () -> Void
    var onZoomOut:              () -> Void
    var onCopy:                 () -> Void
    var onPaste:                () -> Void
    var onSelectAll:            () -> Void
    var onToggleBroadcast:      () -> Void
    var onToggleMaximize:       () -> Void

    var body: some View {
        Group {
            Button("Send Command")             { onSendCommand() }
                .keyboardShortcut(.return, modifiers: [.command])
            Button("Send Ctrl-C")              { onSendCtrlC() }
                .keyboardShortcut("c", modifiers: [.control])
            Button("Send Ctrl-D")              { onSendCtrlD() }
                .keyboardShortcut("d", modifiers: [.control])
            Button("Find in Terminal")         { onShowSearch() }
                .keyboardShortcut("f", modifiers: [.command])
            Button("Toggle Quick Commands")    { onToggleQuickCommands() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Toggle File Browser")      { onToggleFileBrowser() }
                .keyboardShortcut("b", modifiers: [.command])
            Button("Toggle AI Copilot")        { onToggleAIAssistant() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Clear Buffer")             { onClearBuffer() }
                .keyboardShortcut("k", modifiers: [.command])
            Button("Previous Session")         { onPreviousSession() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Session")             { onNextSession() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Disconnect or Close Session") { onDisconnectOrClose() }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Split Right")              { onSplitRight() }
                .keyboardShortcut("d", modifiers: [.command])
            Button("Split Down")               { onSplitDown() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Focus Next Pane")          { onFocusNextPane() }
                .keyboardShortcut("]", modifiers: [.command])
            Button("Focus Previous Pane")      { onFocusPreviousPane() }
                .keyboardShortcut("[", modifiers: [.command])
            Button("Maximize/Restore Pane")    { onMaximizePane() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("New Local Terminal")       { onNewLocalTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Tab (Local)")          { onNewLocalTerminal() }
                .keyboardShortcut("t", modifiers: [.command])
            Button("Zoom In")                  { onZoomIn() }
                .keyboardShortcut("+", modifiers: [.command])
            Button("Zoom In (Alt Binding)")    { onZoomIn() }
                .keyboardShortcut("=", modifiers: [.command])
            Button("Zoom Out")                 { onZoomOut() }
                .keyboardShortcut("-", modifiers: [.command])
            Button("Copy")                     { onCopy() }
                .keyboardShortcut("c", modifiers: [.command])
            Button("Paste")                    { onPaste() }
                .keyboardShortcut("v", modifiers: [.command])
            Button("Select All")               { onSelectAll() }
                .keyboardShortcut("a", modifiers: [.command])
            Button("Toggle Broadcast Input")   { onToggleBroadcast() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Toggle Maximize")          { onToggleMaximize() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}
