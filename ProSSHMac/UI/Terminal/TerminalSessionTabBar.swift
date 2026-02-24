// Extracted from TerminalView.swift
import SwiftUI

struct TerminalSessionTabBar: View {
    @ObservedObject var tabManager: SessionTabManager
    @ObservedObject var paneManager: PaneManager
    var onRequestClose: (Session) -> Void
    var onOpenLocalTerminal: () -> Void
    var onSplitWithExisting: (UUID, UUID, SplitDirection) -> Void

    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var navigationCoordinator: AppNavigationCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    @State private var hoveredTabID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabManager.tabs) { tab in
                        let session = tab.session
                        let isSelected = tabManager.selectedSessionID == session.id
                        let isTabHovered = hoveredTabID == session.id
                        Button {
                            tabManager.select(sessionID: session.id)
                        } label: {
                            HStack(spacing: 6) {
                                if tab.isPinned {
                                    Image(systemName: "pin.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption2)
                                }
                                Circle()
                                    .fill(tab.statusColor)
                                    .frame(width: 8, height: 8)
                                if session.usesLegacyCrypto {
                                    Image(systemName: "shield.lefthalf.filled")
                                        .foregroundStyle(.orange)
                                        .font(.caption2)
                                }
                                if session.usesAgentForwarding {
                                    Image(systemName: "arrow.triangle.branch")
                                        .foregroundStyle(.teal)
                                        .font(.caption2)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(sessionManager.windowTitleBySessionID[session.id] ?? tab.label)
                                        .font(isSelected ? .caption.weight(.medium) : .caption)
                                        .lineLimit(1)
                                    if session.isLocal, let cwd = sessionManager.workingDirectoryBySessionID[session.id] {
                                        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? ""
                                        let displayCwd = cwd.replacingOccurrences(of: homePath, with: "~")
                                        Text(displayCwd)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                if !tab.isPinned {
                                    Button(role: .destructive) {
                                        onRequestClose(session)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .opacity(isSelected || isTabHovered ? 1 : 0)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                tabBackground(for: session),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .id(session.id)
                        .onHover { hovering in
                            hoveredTabID = hovering ? session.id : nil
                        }
                        .draggable(session.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let sourceIDString = items.first,
                                  let sourceID = UUID(uuidString: sourceIDString) else { return false }
                            tabManager.moveTab(from: sourceID, before: session.id)
                            return true
                        }
                        .contextMenu {
                            Button("Move Left") {
                                tabManager.moveTab(sessionID: session.id, by: -1)
                            }
                            .disabled(!tabManager.canMoveTab(sessionID: session.id, direction: -1))

                            Button("Move Right") {
                                tabManager.moveTab(sessionID: session.id, by: 1)
                            }
                            .disabled(!tabManager.canMoveTab(sessionID: session.id, direction: 1))

                            Divider()

                            Button {
                                Task {
                                    try? await sessionManager.duplicateSession(session.id)
                                }
                            } label: {
                                Label("Duplicate", systemImage: "doc.on.doc")
                            }

                            Button {
                                openWindow(id: ProSSHMacApp.externalTerminalWindowID, value: session.id)
                            } label: {
                                Label("Pop Out to Window", systemImage: "rectangle.portrait.and.arrow.right")
                            }

                            Button {
                                tabManager.togglePin(sessionID: session.id)
                            } label: {
                                Label(tab.isPinned ? "Unpin" : "Pin", systemImage: tab.isPinned ? "pin.slash" : "pin")
                            }

                            if paneManager.canSplit(paneManager.focusedPaneId),
                               session.id != paneManager.focusedSessionID {
                                Divider()

                                Button {
                                    onSplitWithExisting(session.id, paneManager.focusedPaneId, .vertical)
                                } label: {
                                    Label("Split Right", systemImage: "rectangle.split.2x1")
                                }

                                Button {
                                    onSplitWithExisting(session.id, paneManager.focusedPaneId, .horizontal)
                                } label: {
                                    Label("Split Down", systemImage: "rectangle.split.1x2")
                                }
                            }
                        }
                    }

                Menu {
                    Button {
                        navigationCoordinator.navigate(to: .hosts)
                    } label: {
                        Label("New SSH Session", systemImage: "network")
                    }

                    Button {
                        onOpenLocalTerminal()
                    } label: {
                        Label("New Local Terminal", systemImage: "terminal.fill")
                    }
                } label: {
                    Label("New Tab", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            (colorScheme == .dark ? Color.white.opacity(0.1) : Color.secondary.opacity(0.12)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: tabManager.selectedSessionID) { _, newID in
                if let newID {
                    withAnimation {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    private func tabBackground(for session: Session) -> Color {
        if tabManager.selectedSessionID == session.id {
            return colorScheme == .dark ? Color.accentColor.opacity(0.34) : Color.accentColor.opacity(0.2)
        }
        return colorScheme == .dark ? Color.white.opacity(0.1) : Color.secondary.opacity(0.12)
    }
}
