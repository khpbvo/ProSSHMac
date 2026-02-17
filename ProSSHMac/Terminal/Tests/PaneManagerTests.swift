// PaneManagerTests.swift
// ProSSHV2
//
// Tests for the recursive split-pane tree and PaneManager operations.

#if canImport(XCTest)
import XCTest

@MainActor
final class PaneManagerTests: XCTestCase {

    // MARK: - Initial State

    func testInitialStateIsSinglePane() {
        let manager = PaneManager()
        XCTAssertEqual(manager.paneCount, 1)
        XCTAssertEqual(manager.rootNode.maxDepth, 0)
        XCTAssertNotNil(manager.focusedPane)
    }

    // MARK: - Split

    func testSplitCreatesCorrectTree() {
        let manager = PaneManager()
        let originalPaneID = manager.focusedPaneId

        manager.splitPane(originalPaneID, direction: .vertical)

        XCTAssertEqual(manager.paneCount, 2)
        XCTAssertEqual(manager.rootNode.maxDepth, 1)
        // Focus moves to the new pane.
        XCTAssertNotEqual(manager.focusedPaneId, originalPaneID)
    }

    func testSplitHorizontalCreatesVerticalLayout() {
        let manager = PaneManager()
        let paneID = manager.focusedPaneId

        manager.splitPane(paneID, direction: .horizontal)

        if case .split(let container) = manager.rootNode {
            XCTAssertEqual(container.direction, .horizontal)
            XCTAssertEqual(container.ratio, 0.5)
        } else {
            XCTFail("Expected split container")
        }
    }

    func testSplitRespectsMaxDepth() {
        let manager = PaneManager()

        // Split repeatedly to reach max depth.
        for _ in 0..<PaneManager.maxDepth {
            let focused = manager.focusedPaneId
            manager.splitPane(focused, direction: .vertical)
        }

        let depthBeforeExtraAttempt = manager.rootNode.maxDepth
        let countBefore = manager.paneCount

        // Try to split beyond max depth — should be blocked.
        let focused = manager.focusedPaneId
        manager.splitPane(focused, direction: .vertical)

        XCTAssertEqual(manager.rootNode.maxDepth, depthBeforeExtraAttempt)
        XCTAssertEqual(manager.paneCount, countBefore)
    }

    func testNestedSplitCreatesDeepTree() {
        let manager = PaneManager()
        let first = manager.focusedPaneId

        manager.splitPane(first, direction: .vertical)
        let second = manager.focusedPaneId

        manager.splitPane(second, direction: .horizontal)

        XCTAssertEqual(manager.paneCount, 3)
        XCTAssertEqual(manager.rootNode.maxDepth, 2)
    }

    // MARK: - Close

    func testClosePromotesSibling() {
        let manager = PaneManager()
        let originalPaneID = manager.focusedPaneId

        manager.splitPane(originalPaneID, direction: .vertical)
        let newPaneID = manager.focusedPaneId

        manager.closePane(newPaneID)

        XCTAssertEqual(manager.paneCount, 1)
        XCTAssertEqual(manager.focusedPaneId, originalPaneID)
    }

    func testCloseBlocksOnLastPane() {
        let manager = PaneManager()
        let paneID = manager.focusedPaneId

        manager.closePane(paneID)

        XCTAssertEqual(manager.paneCount, 1)
        XCTAssertEqual(manager.focusedPaneId, paneID)
    }

    func testCloseRestoresMaximizeIfClosingMaximizedPane() {
        let manager = PaneManager()
        let first = manager.focusedPaneId
        manager.splitPane(first, direction: .vertical)
        let second = manager.focusedPaneId

        manager.maximizePane(second)
        XCTAssertNotNil(manager.maximizedPaneId)

        manager.closePane(second)
        XCTAssertNil(manager.maximizedPaneId)
        XCTAssertEqual(manager.paneCount, 1)
    }

    // MARK: - Focus Cycling

    func testFocusCyclingOrder() {
        let manager = PaneManager()
        let first = manager.focusedPaneId

        manager.splitPane(first, direction: .vertical)
        let second = manager.focusedPaneId

        // Focus is on second; go next should wrap to first.
        manager.focusNext()
        XCTAssertEqual(manager.focusedPaneId, first)

        // Go next again should go to second.
        manager.focusNext()
        XCTAssertEqual(manager.focusedPaneId, second)
    }

    func testFocusPreviousCycles() {
        let manager = PaneManager()
        let first = manager.focusedPaneId

        manager.splitPane(first, direction: .vertical)
        let second = manager.focusedPaneId

        // Focus is on second; go previous should go to first.
        manager.focusPrevious()
        XCTAssertEqual(manager.focusedPaneId, first)

        // Go previous again should wrap to second.
        manager.focusPrevious()
        XCTAssertEqual(manager.focusedPaneId, second)
    }

    func testFocusPaneUpdatesFocusedState() {
        let manager = PaneManager()
        let first = manager.focusedPaneId

        manager.splitPane(first, direction: .vertical)
        let second = manager.focusedPaneId

        manager.focusPane(first)

        let firstPane = manager.rootNode.findPane(id: first)
        let secondPane = manager.rootNode.findPane(id: second)
        XCTAssertTrue(firstPane?.isFocused ?? false)
        XCTAssertFalse(secondPane?.isFocused ?? true)
    }

    // MARK: - Resize

    func testResizeClamping() {
        let manager = PaneManager()
        let paneID = manager.focusedPaneId

        manager.splitPane(paneID, direction: .vertical)

        guard case .split(let container) = manager.rootNode else {
            XCTFail("Expected split")
            return
        }

        manager.resizeSplit(container.id, ratio: 0.05)
        if case .split(let updated) = manager.rootNode {
            XCTAssertEqual(updated.ratio, PaneManager.minRatio)
        }

        manager.resizeSplit(container.id, ratio: 0.99)
        if case .split(let updated) = manager.rootNode {
            XCTAssertEqual(updated.ratio, PaneManager.maxRatio)
        }

        manager.resizeSplit(container.id, ratio: 0.4)
        if case .split(let updated) = manager.rootNode {
            XCTAssertEqual(updated.ratio, 0.4, accuracy: 0.001)
        }
    }

    // MARK: - Swap

    func testSwapReversesPaneOrder() {
        let manager = PaneManager()
        let first = manager.focusedPaneId
        manager.splitPane(first, direction: .vertical)

        guard case .split(let containerBefore) = manager.rootNode else {
            XCTFail("Expected split")
            return
        }
        let firstChildBefore = containerBefore.first
        let secondChildBefore = containerBefore.second

        manager.swapPanes(containerBefore.id)

        guard case .split(let containerAfter) = manager.rootNode else {
            XCTFail("Expected split after swap")
            return
        }
        XCTAssertEqual(containerAfter.first, secondChildBefore)
        XCTAssertEqual(containerAfter.second, firstChildBefore)
    }

    // MARK: - Maximize / Restore

    func testMaximizeRestoreRoundTrip() {
        let manager = PaneManager()
        let first = manager.focusedPaneId
        manager.splitPane(first, direction: .vertical)

        let rootBefore = manager.rootNode

        manager.maximizePane(first)
        XCTAssertEqual(manager.maximizedPaneId, first)

        // Display node should be a single pane.
        if case .terminal(let pane) = manager.displayNode {
            XCTAssertEqual(pane.id, first)
        } else {
            XCTFail("Maximized display should be a single terminal")
        }

        manager.restoreMaximize()
        XCTAssertNil(manager.maximizedPaneId)
        XCTAssertEqual(manager.rootNode, rootBefore)
    }

    func testToggleMaximize() {
        let manager = PaneManager()
        let first = manager.focusedPaneId
        manager.splitPane(first, direction: .vertical)

        manager.toggleMaximize(first)
        XCTAssertEqual(manager.maximizedPaneId, first)

        manager.toggleMaximize(first)
        XCTAssertNil(manager.maximizedPaneId)
    }

    func testMaximizeSinglePaneIsNoOp() {
        let manager = PaneManager()
        let paneID = manager.focusedPaneId

        manager.maximizePane(paneID)
        XCTAssertNil(manager.maximizedPaneId)
    }

    // MARK: - Session Assignment

    func testAssignSession() {
        let manager = PaneManager()
        let paneID = manager.focusedPaneId
        let sessionID = UUID()

        manager.assignSession(sessionID, to: paneID, sessionType: .ssh(hostID: UUID(), hostLabel: "test-host"))

        let pane = manager.rootNode.findPane(id: paneID)
        XCTAssertEqual(pane?.sessionID, sessionID)
        XCTAssertEqual(manager.focusedSessionID, sessionID)
    }

    // MARK: - Session Sync

    func testSyncRemovesPanesWithStaleSession() {
        let manager = PaneManager()
        let first = manager.focusedPaneId
        let sessionA = UUID()
        let sessionB = UUID()

        manager.assignSession(sessionA, to: first)
        manager.splitPane(first, direction: .vertical)
        let second = manager.focusedPaneId
        manager.assignSession(sessionB, to: second)

        XCTAssertEqual(manager.paneCount, 2)

        // Remove sessionB from active set.
        manager.syncSessions(activeSessionIDs: Set([sessionA]))

        XCTAssertEqual(manager.paneCount, 1)
        XCTAssertEqual(manager.focusedSessionID, sessionA)
    }

    func testSyncClearsSessionOnLastPane() {
        let manager = PaneManager()
        let paneID = manager.focusedPaneId
        let sessionID = UUID()

        manager.assignSession(sessionID, to: paneID)

        // Sync with empty active set — should clear session but keep pane.
        manager.syncSessions(activeSessionIDs: Set())

        XCTAssertEqual(manager.paneCount, 1)
        XCTAssertNil(manager.focusedSessionID)
    }

    // MARK: - Codable Round-Trip

    func testSplitNodeCodableRoundTrip() throws {
        let pane1 = TerminalPane(sessionType: .ssh(hostID: UUID(), hostLabel: "host-1"), title: "SSH")
        let pane2 = TerminalPane(sessionType: .local, title: "Local")
        let container = SplitContainer(
            direction: .vertical,
            ratio: 0.6,
            first: .terminal(pane1),
            second: .terminal(pane2)
        )
        let node: SplitNode = .split(container)

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(SplitNode.self, from: data)

        XCTAssertEqual(node, decoded)
    }

    func testNestedSplitNodeCodableRoundTrip() throws {
        let pane1 = TerminalPane(title: "P1")
        let pane2 = TerminalPane(title: "P2")
        let pane3 = TerminalPane(title: "P3")
        let inner = SplitContainer(
            direction: .horizontal,
            ratio: 0.3,
            first: .terminal(pane2),
            second: .terminal(pane3)
        )
        let outer = SplitContainer(
            direction: .vertical,
            ratio: 0.5,
            first: .terminal(pane1),
            second: .split(inner)
        )
        let node: SplitNode = .split(outer)

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(SplitNode.self, from: data)

        XCTAssertEqual(node, decoded)
        XCTAssertEqual(decoded.paneCount, 3)
        XCTAssertEqual(decoded.maxDepth, 2)
    }

    // MARK: - Persistence

    func testLayoutPersistsAcrossManagerInstances() {
        let defaults = UserDefaults(suiteName: "PaneManagerTests.\(UUID().uuidString)")!
        let store = PaneLayoutStore(defaults: defaults)

        // Create a manager, split a pane so it saves the layout.
        let manager1 = PaneManager(layoutStore: store)
        let firstPane = manager1.focusedPaneId
        manager1.splitPane(firstPane, direction: .vertical)

        XCTAssertEqual(manager1.paneCount, 2)

        // Create a second manager with the same store — should restore.
        let manager2 = PaneManager(layoutStore: store)
        XCTAssertEqual(manager2.paneCount, 2)
        XCTAssertEqual(manager2.rootNode.maxDepth, 1)

        defaults.removePersistentDomain(forName: defaults.suiteName)
    }

    func testNamedLayoutSaveAndLoad() {
        let defaults = UserDefaults(suiteName: "PaneManagerTests.\(UUID().uuidString)")!
        let store = PaneLayoutStore(defaults: defaults)
        let manager = PaneManager(layoutStore: store)
        let firstPane = manager.focusedPaneId

        manager.splitPane(firstPane, direction: .horizontal)
        manager.saveNamedLayout("My Layout")

        XCTAssertTrue(store.namedLayoutNames().contains("My Layout"))

        // Load into a fresh manager.
        let manager2 = PaneManager(layoutStore: store)
        let loaded = manager2.loadNamedLayout("My Layout")

        XCTAssertTrue(loaded)
        XCTAssertEqual(manager2.paneCount, 2)

        defaults.removePersistentDomain(forName: defaults.suiteName)
    }

    // MARK: - Presets

    func testPresetsProduceCorrectPaneCounts() {
        XCTAssertEqual(PaneLayoutStore.Preset.sideBySide.node.paneCount, 2)
        XCTAssertEqual(PaneLayoutStore.Preset.threeColumn.node.paneCount, 3)
        XCTAssertEqual(PaneLayoutStore.Preset.quadGrid.node.paneCount, 4)
        XCTAssertEqual(PaneLayoutStore.Preset.mainPlusSidebar.node.paneCount, 3)
    }

    func testApplyPresetUpdatesManager() {
        let manager = PaneManager()
        XCTAssertEqual(manager.paneCount, 1)

        manager.applyPreset(.quadGrid)
        XCTAssertEqual(manager.paneCount, 4)
        XCTAssertEqual(manager.rootNode.maxDepth, 2)
    }
}
#endif
