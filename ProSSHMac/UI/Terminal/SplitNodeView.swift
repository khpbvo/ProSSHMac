// SplitNodeView.swift
// ProSSHV2
//
// Recursive view that renders a SplitNode tree of terminal panes.

import SwiftUI

struct SplitNodeView<PaneContent: View>: View {
    let node: SplitNode
    let paneManager: PaneManager
    var onNewSSHSession: ((UUID) -> Void)?
    var onNewLocalTerminal: ((UUID) -> Void)?
    var onMoveToNewTab: ((UUID) -> Void)?
    var onSplitWithNewSession: ((UUID) -> Void)?
    var availableSessions: [(id: UUID, label: String)] = []
    var onSplitWithExistingSession: ((UUID, UUID, SplitDirection) -> Void)?
    @ViewBuilder let paneContent: (TerminalPane) -> PaneContent

    var body: some View {
        switch node {
        case .terminal(let pane):
            let sessionsForPane = availableSessions.filter { $0.id != pane.sessionID }
            TerminalPaneView(
                pane: pane,
                paneManager: paneManager,
                onNewSSHSession: onNewSSHSession,
                onNewLocalTerminal: onNewLocalTerminal,
                onMoveToNewTab: onMoveToNewTab,
                onSplitWithNewSession: onSplitWithNewSession,
                availableSessions: sessionsForPane,
                onSplitWithExistingSession: onSplitWithExistingSession
            ) {
                paneContent(pane)
            }

        case .split(let container):
            GeometryReader { geometry in
                splitLayout(container: container, size: geometry.size)
            }
        }
    }

    @ViewBuilder
    private func splitLayout(container: SplitContainer, size: CGSize) -> some View {
        let isVertical = container.direction == .vertical
        let totalLength = isVertical ? size.width : size.height
        let dividerThickness: CGFloat = 10
        let usable = max(0, totalLength - dividerThickness)
        let firstLength = usable * container.ratio
        let secondLength = usable - firstLength

        if isVertical {
            HStack(spacing: 0) {
                SplitNodeView(
                    node: container.first,
                    paneManager: paneManager,
                    onNewSSHSession: onNewSSHSession,
                    onNewLocalTerminal: onNewLocalTerminal,
                    onMoveToNewTab: onMoveToNewTab,
                    onSplitWithNewSession: onSplitWithNewSession,
                    availableSessions: availableSessions,
                    onSplitWithExistingSession: onSplitWithExistingSession,
                    paneContent: paneContent
                )
                .frame(width: firstLength)

                PaneDividerView(
                    containerID: container.id,
                    direction: container.direction,
                    totalLength: totalLength,
                    currentRatio: container.ratio,
                    onResize: { id, ratio in
                        paneManager.resizeSplit(id, ratio: ratio)
                    }
                )

                SplitNodeView(
                    node: container.second,
                    paneManager: paneManager,
                    onNewSSHSession: onNewSSHSession,
                    onNewLocalTerminal: onNewLocalTerminal,
                    onMoveToNewTab: onMoveToNewTab,
                    onSplitWithNewSession: onSplitWithNewSession,
                    availableSessions: availableSessions,
                    onSplitWithExistingSession: onSplitWithExistingSession,
                    paneContent: paneContent
                )
                .frame(width: secondLength)
            }
        } else {
            VStack(spacing: 0) {
                SplitNodeView(
                    node: container.first,
                    paneManager: paneManager,
                    onNewSSHSession: onNewSSHSession,
                    onNewLocalTerminal: onNewLocalTerminal,
                    onMoveToNewTab: onMoveToNewTab,
                    onSplitWithNewSession: onSplitWithNewSession,
                    availableSessions: availableSessions,
                    onSplitWithExistingSession: onSplitWithExistingSession,
                    paneContent: paneContent
                )
                .frame(height: firstLength)

                PaneDividerView(
                    containerID: container.id,
                    direction: container.direction,
                    totalLength: totalLength,
                    currentRatio: container.ratio,
                    onResize: { id, ratio in
                        paneManager.resizeSplit(id, ratio: ratio)
                    }
                )

                SplitNodeView(
                    node: container.second,
                    paneManager: paneManager,
                    onNewSSHSession: onNewSSHSession,
                    onNewLocalTerminal: onNewLocalTerminal,
                    onMoveToNewTab: onMoveToNewTab,
                    onSplitWithNewSession: onSplitWithNewSession,
                    availableSessions: availableSessions,
                    onSplitWithExistingSession: onSplitWithExistingSession,
                    paneContent: paneContent
                )
                .frame(height: secondLength)
            }
        }
    }
}
