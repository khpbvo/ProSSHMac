// TerminalPaneView.swift
// ProSSHV2
//
// Renders a single terminal pane with focus border, dim overlay, and context menu.

import SwiftUI

struct TerminalPaneView<Content: View>: View {
    let pane: TerminalPane
    let paneManager: PaneManager
    var onNewSSHSession: ((UUID) -> Void)?
    var onNewLocalTerminal: ((UUID) -> Void)?
    var onMoveToNewTab: ((UUID) -> Void)?
    /// Called after a context menu split. The UUID is the **source session** to duplicate.
    var onSplitWithNewSession: ((UUID) -> Void)?
    /// Sessions available to arrange in a split (excludes the pane's own session).
    var availableSessions: [(id: UUID, label: String)] = []
    /// Called to split this pane with an existing session. Parameters: (sessionID, paneID, direction).
    var onSplitWithExistingSession: ((UUID, UUID, SplitDirection) -> Void)?
    @ViewBuilder let content: () -> Content

    private var isFocused: Bool {
        pane.id == paneManager.focusedPaneId
    }

    private var isMaximized: Bool {
        paneManager.maximizedPaneId == pane.id
    }

    private var parentContainer: SplitContainer? {
        paneManager.rootNode.findParentContainer(of: pane.id)
    }

    var body: some View {
        content()
            .overlay {
                if !isFocused && paneManager.paneCount > 1 {
                    Color.black.opacity(0.05)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if isFocused && paneManager.paneCount > 1 {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                paneManager.focusPane(pane.id)
            }
            .contextMenu {
                paneContextMenu
            }
    }

    @ViewBuilder
    private var paneContextMenu: some View {
        if paneManager.canSplit(pane.id) && !availableSessions.isEmpty {
            Menu {
                ForEach(availableSessions, id: \.id) { session in
                    Button(session.label) {
                        onSplitWithExistingSession?(session.id, pane.id, .vertical)
                    }
                }
            } label: {
                Label("Split Right With...", systemImage: "rectangle.split.2x1")
            }

            Menu {
                ForEach(availableSessions, id: \.id) { session in
                    Button(session.label) {
                        onSplitWithExistingSession?(session.id, pane.id, .horizontal)
                    }
                }
            } label: {
                Label("Split Down With...", systemImage: "rectangle.split.1x2")
            }

            Divider()

            Button {
                onNewSSHSession?(pane.id)
            } label: {
                Label("New SSH Session...", systemImage: "network")
            }

            Button {
                onNewLocalTerminal?(pane.id)
            } label: {
                Label("New Local Terminal", systemImage: "terminal.fill")
            }
        }

        if paneManager.paneCount > 1 {
            Divider()

            Button {
                paneManager.toggleMaximize(pane.id)
            } label: {
                if isMaximized {
                    Label("Restore", systemImage: "arrow.down.right.and.arrow.up.left")
                } else {
                    Label("Maximize", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }

            if let container = parentContainer {
                Button {
                    paneManager.swapPanes(container.id)
                } label: {
                    Label("Swap Panes", systemImage: "arrow.left.arrow.right")
                }
            }

            Button {
                onMoveToNewTab?(pane.id)
            } label: {
                Label("Move to New Tab", systemImage: "rectangle.portrait.on.rectangle.portrait")
            }
        }

        if paneManager.canClose(pane.id) {
            Divider()

            Button(role: .destructive) {
                paneManager.closePane(pane.id)
            } label: {
                Label("Close Pane", systemImage: "xmark.rectangle")
            }
        }
    }
}
