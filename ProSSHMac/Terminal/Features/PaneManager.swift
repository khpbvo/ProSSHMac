// PaneManager.swift
// ProSSHV2
//
// Manages the recursive split-pane tree for terminal views.

import Foundation
import Combine

@MainActor
final class PaneManager: ObservableObject {

    // MARK: - Constants

    static let maxDepth = 4
    static let minRatio: CGFloat = 0.15
    static let maxRatio: CGFloat = 0.85

    // MARK: - State

    @Published private(set) var rootNode: SplitNode {
        didSet { layoutStore.saveLastLayout(rootNode) }
    }
    @Published var focusedPaneId: UUID
    @Published var maximizedPaneId: UUID?
    @Published var inputRoutingMode: InputRoutingMode = .singleFocus
    @Published var groupPaneIDs: Set<UUID> = []
    /// When set during broadcast/group mode, input is temporarily routed to only this pane.
    @Published var soloPaneId: UUID?
    private var savedRootNode: SplitNode?
    private var savedInputRoutingMode: InputRoutingMode?
    private var savedGroupPaneIDs: Set<UUID>?
    let layoutStore: PaneLayoutStore

    // MARK: - Init

    init(layoutStore: PaneLayoutStore = PaneLayoutStore()) {
        self.layoutStore = layoutStore
        if let restored = layoutStore.loadLastLayout(),
           let fallbackPane = restored.allPanes.first {
            self.rootNode = restored
            self.focusedPaneId = restored.allPanes.first(where: { $0.isFocused })?.id
                ?? fallbackPane.id
        } else {
            let pane = TerminalPane(isFocused: true)
            self.rootNode = .terminal(pane)
            self.focusedPaneId = pane.id
        }
    }

    init(rootNode: SplitNode, focusedPaneId: UUID, layoutStore: PaneLayoutStore = PaneLayoutStore()) {
        self.layoutStore = layoutStore
        self.rootNode = rootNode
        self.focusedPaneId = focusedPaneId
    }

    nonisolated deinit {}

    // MARK: - Computed

    var focusedPane: TerminalPane? {
        rootNode.findPane(id: focusedPaneId)
    }

    var focusedSessionID: UUID? {
        focusedPane?.sessionID
    }

    var allPanes: [TerminalPane] {
        rootNode.allPanes
    }

    var paneCount: Int {
        rootNode.paneCount
    }

    /// The node to render — if a pane is maximized, render only that pane.
    var displayNode: SplitNode {
        if let maximizedPaneId, let pane = rootNode.findPane(id: maximizedPaneId) {
            return .terminal(pane)
        }
        return rootNode
    }

    /// Session IDs that should receive keyboard input based on the current routing mode.
    /// Deduplicates (same session in two panes → one ID). Skips panes with nil sessionID.
    var targetSessionIDs: [UUID] {
        // Solo override: route input only to the soloed pane.
        if let soloPaneId, inputRoutingMode != .singleFocus,
           let pane = rootNode.findPane(id: soloPaneId) {
            return pane.sessionID.map { [$0] } ?? []
        }
        let sessionIDs: [UUID?]
        switch inputRoutingMode {
        case .singleFocus:
            return focusedSessionID.map { [$0] } ?? []
        case .broadcast:
            sessionIDs = allPanes.map(\.sessionID)
        case .selectGroup:
            sessionIDs = allPanes.filter { groupPaneIDs.contains($0.id) }.map(\.sessionID)
        }
        // Deduplicate while preserving order, skip nil
        var seen = Set<UUID>()
        var result = [UUID]()
        for sid in sessionIDs {
            guard let sid, seen.insert(sid).inserted else { continue }
            result.append(sid)
        }
        return result
    }

    /// Pane IDs that are currently targeted for input (for visual indicators).
    var targetPaneIDs: Set<UUID> {
        if let soloPaneId, inputRoutingMode != .singleFocus {
            return [soloPaneId]
        }
        switch inputRoutingMode {
        case .singleFocus:
            return [focusedPaneId]
        case .broadcast:
            return Set(allPanes.map(\.id))
        case .selectGroup:
            return groupPaneIDs
        }
    }

    // MARK: - Input Routing

    func toggleBroadcast() {
        if soloPaneId != nil {
            // End solo and return to broadcast.
            soloPaneId = nil
        } else {
            inputRoutingMode = inputRoutingMode == .broadcast ? .singleFocus : .broadcast
        }
    }

    /// Temporarily route input to a single pane while in broadcast/group mode.
    /// Option+Click the same pane again to return to broadcast.
    func soloPane(_ paneID: UUID) {
        if soloPaneId == paneID {
            soloPaneId = nil
        } else {
            guard rootNode.findPane(id: paneID) != nil else { return }
            soloPaneId = paneID
            focusPane(paneID)
        }
    }

    func endSolo() {
        soloPaneId = nil
    }

    func togglePaneInGroup(_ paneID: UUID) {
        if groupPaneIDs.contains(paneID) {
            groupPaneIDs.remove(paneID)
            if groupPaneIDs.isEmpty {
                inputRoutingMode = .singleFocus
            }
        } else {
            groupPaneIDs.insert(paneID)
        }
    }

    func setSelectGroupMode(paneIDs: Set<UUID>) {
        groupPaneIDs = paneIDs
        inputRoutingMode = paneIDs.isEmpty ? .singleFocus : .selectGroup
    }

    // MARK: - Validation

    func canSplit(_ paneID: UUID) -> Bool {
        guard let depth = rootNode.depthOf(paneID: paneID) else { return false }
        return depth < Self.maxDepth
    }

    func canClose(_ paneID: UUID) -> Bool {
        paneCount > 1
    }

    // MARK: - Split

    func splitPane(
        _ paneID: UUID,
        direction: SplitDirection,
        sessionType: PaneSessionType = .local
    ) {
        guard canSplit(paneID) else { return }
        guard let existingPane = rootNode.findPane(id: paneID) else { return }

        let newPane = TerminalPane(sessionType: sessionType, title: "Terminal")
        let container = SplitContainer(
            direction: direction,
            first: .terminal(existingPane),
            second: .terminal(newPane)
        )

        rootNode = rootNode.replacePane(paneID, with: .split(container))
        focusPane(newPane.id)
    }

    // MARK: - Close

    func closePane(_ paneID: UUID) {
        guard canClose(paneID) else { return }

        // If we're closing the maximized pane, restore first.
        if maximizedPaneId == paneID {
            restoreMaximize()
        }

        let wasFocused = paneID == focusedPaneId
        rootNode = rootNode.removePane(paneID)

        // Clean up solo state if the soloed pane was closed.
        if soloPaneId == paneID { soloPaneId = nil }

        // Clean up input routing state for the closed pane.
        groupPaneIDs.remove(paneID)
        if inputRoutingMode == .selectGroup && groupPaneIDs.isEmpty {
            inputRoutingMode = .singleFocus
        }
        // Auto-revert to single focus when only one pane remains.
        if paneCount <= 1 {
            inputRoutingMode = .singleFocus
            groupPaneIDs.removeAll()
        }

        if wasFocused {
            // Focus the first available pane.
            if let first = rootNode.allPanes.first {
                focusPane(first.id)
            }
        }
    }

    // MARK: - Focus

    func focusPane(_ paneID: UUID) {
        guard rootNode.findPane(id: paneID) != nil else { return }

        // Unfocus old pane.
        rootNode = rootNode.updatePane(focusedPaneId) { $0.isFocused = false }
        // Focus new pane.
        rootNode = rootNode.updatePane(paneID) { $0.isFocused = true }
        focusedPaneId = paneID
    }

    func focusNext() {
        let panes = rootNode.allPanes
        guard let currentIndex = panes.firstIndex(where: { $0.id == focusedPaneId }) else { return }
        let nextIndex = (currentIndex + 1) % panes.count
        focusPane(panes[nextIndex].id)
    }

    func focusPrevious() {
        let panes = rootNode.allPanes
        guard let currentIndex = panes.firstIndex(where: { $0.id == focusedPaneId }) else { return }
        let prevIndex = (currentIndex - 1 + panes.count) % panes.count
        focusPane(panes[prevIndex].id)
    }

    // MARK: - Resize

    func resizeSplit(_ containerID: UUID, ratio: CGFloat) {
        let clamped = max(Self.minRatio, min(Self.maxRatio, ratio))
        rootNode = rootNode.updateContainerRatio(containerID, ratio: clamped)
    }

    // MARK: - Swap

    func swapPanes(_ containerID: UUID) {
        guard case .split(var container) = findSubtree(containerID) else { return }
        let temp = container.first
        container.first = container.second
        container.second = temp
        rootNode = replaceSubtree(containerID, with: .split(container))
    }

    // MARK: - Maximize / Restore

    func maximizePane(_ paneID: UUID) {
        guard rootNode.findPane(id: paneID) != nil else { return }
        guard paneCount > 1 else { return }
        savedRootNode = rootNode
        savedInputRoutingMode = inputRoutingMode
        savedGroupPaneIDs = groupPaneIDs
        maximizedPaneId = paneID
        soloPaneId = nil
        inputRoutingMode = .singleFocus
        groupPaneIDs.removeAll()
        focusPane(paneID)
    }

    func restoreMaximize() {
        guard maximizedPaneId != nil else { return }
        if let saved = savedRootNode {
            // Merge: keep any panes that were added while maximized and
            // remove saved panes that were closed while maximized.
            let currentPaneIDs = Set(rootNode.allPanes.map(\.id))
            let savedPaneIDs = Set(saved.allPanes.map(\.id))

            // Panes added while maximized that are not in the saved layout.
            let addedPanes = rootNode.allPanes.filter { !savedPaneIDs.contains($0.id) }

            // Start from the saved layout, but prune panes that were removed while maximized.
            var merged = saved
            let removedPaneIDs = savedPaneIDs.subtracting(currentPaneIDs)
            for removedID in removedPaneIDs {
                if merged.paneCount > 1 {
                    merged = merged.removePane(removedID)
                }
            }

            // Append panes that were added while maximized.
            for pane in addedPanes {
                if let firstPaneID = merged.allPanes.first?.id {
                    let container = SplitContainer(
                        direction: .horizontal,
                        first: merged,
                        second: .terminal(pane)
                    )
                    _ = firstPaneID // suppress unused warning
                    merged = .split(container)
                }
            }

            rootNode = merged
            savedRootNode = nil
        }
        maximizedPaneId = nil
        if let savedMode = savedInputRoutingMode {
            inputRoutingMode = savedMode
            savedInputRoutingMode = nil
        }
        if let savedGroup = savedGroupPaneIDs {
            groupPaneIDs = savedGroup
            savedGroupPaneIDs = nil
        }
    }

    func toggleMaximize(_ paneID: UUID) {
        if maximizedPaneId == paneID {
            restoreMaximize()
        } else {
            maximizePane(paneID)
        }
    }

    // MARK: - Session Management

    func assignSession(_ sessionID: UUID, to paneID: UUID, sessionType: PaneSessionType? = nil) {
        rootNode = rootNode.updatePane(paneID) { pane in
            pane.sessionID = sessionID
            if let sessionType { pane.sessionType = sessionType }
        }
    }

    /// Removes panes whose sessions are no longer active.
    /// Keeps panes that have no session assigned (e.g., newly split panes awaiting assignment).
    func syncSessions(activeSessionIDs: Set<UUID>) {
        // Collect dead panes first to avoid mutating the tree during iteration.
        let deadPanes = rootNode.allPanes.filter { pane in
            guard let sessionID = pane.sessionID else { return false }
            return !activeSessionIDs.contains(sessionID)
        }

        for pane in deadPanes {
            if paneCount > 1 {
                closePane(pane.id)
            } else {
                // Last pane — just clear the session.
                rootNode = rootNode.updatePane(pane.id) { p in
                    p.sessionID = nil
                    p.title = "Terminal"
                }
            }
        }

        // Clean stale pane IDs from group selection.
        let currentPaneIDs = Set(allPanes.map(\.id))
        groupPaneIDs = groupPaneIDs.intersection(currentPaneIDs)
        if inputRoutingMode == .selectGroup && groupPaneIDs.isEmpty {
            inputRoutingMode = .singleFocus
        }
    }

    // MARK: - Layout Persistence

    func applyLayout(_ node: SplitNode) {
        restoreMaximize()
        rootNode = node
        focusedPaneId = node.allPanes.first?.id ?? focusedPaneId
        if let first = rootNode.allPanes.first {
            focusPane(first.id)
        }
    }

    func applyPreset(_ preset: PaneLayoutStore.Preset) {
        applyLayout(preset.node)
    }

    func saveNamedLayout(_ name: String) {
        layoutStore.saveNamedLayout(name, node: rootNode)
    }

    func loadNamedLayout(_ name: String) -> Bool {
        guard let node = layoutStore.loadNamedLayout(name) else { return false }
        applyLayout(node)
        return true
    }

    // MARK: - Private Helpers

    private func findSubtree(_ containerID: UUID) -> SplitNode? {
        findSubtreeIn(rootNode, id: containerID)
    }

    private func findSubtreeIn(_ node: SplitNode, id: UUID) -> SplitNode? {
        switch node {
        case .terminal:
            return nil
        case .split(let container):
            if container.id == id { return node }
            return findSubtreeIn(container.first, id: id)
                ?? findSubtreeIn(container.second, id: id)
        }
    }

    private func replaceSubtree(_ containerID: UUID, with newNode: SplitNode) -> SplitNode {
        replaceSubtreeIn(rootNode, containerID: containerID, newNode: newNode)
    }

    private func replaceSubtreeIn(_ node: SplitNode, containerID: UUID, newNode: SplitNode) -> SplitNode {
        switch node {
        case .terminal:
            return node
        case .split(var container):
            if container.id == containerID { return newNode }
            container.first = replaceSubtreeIn(container.first, containerID: containerID, newNode: newNode)
            container.second = replaceSubtreeIn(container.second, containerID: containerID, newNode: newNode)
            return .split(container)
        }
    }
}
