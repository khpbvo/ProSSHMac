// InputRoutingTests.swift
// ProSSHMac
//
// Tests for multi-session broadcast/group input routing (Issue #15).

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class InputRoutingTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeManager() -> PaneManager {
        let suite = "InputRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PaneManager(layoutStore: PaneLayoutStore(defaults: defaults, persistenceEnabled: false))
    }

    @MainActor
    private func makeManagerWith2Panes() -> (PaneManager, UUID, UUID) {
        let manager = makeManager()
        let first = manager.focusedPaneId
        let sessionA = UUID()
        manager.assignSession(sessionA, to: first)

        manager.splitPane(first, direction: .vertical)
        let second = manager.focusedPaneId
        let sessionB = UUID()
        manager.assignSession(sessionB, to: second)

        return (manager, first, second)
    }

    // MARK: - Default State

    @MainActor
    func testDefaultModeIsSingleFocus() {
        let manager = makeManager()
        XCTAssertEqual(manager.inputRoutingMode, .singleFocus)
        XCTAssertTrue(manager.groupPaneIDs.isEmpty)
    }

    // MARK: - Toggle Broadcast

    @MainActor
    func testToggleBroadcastCycles() {
        let manager = makeManager()
        XCTAssertEqual(manager.inputRoutingMode, .singleFocus)

        manager.toggleBroadcast()
        XCTAssertEqual(manager.inputRoutingMode, .broadcast)

        manager.toggleBroadcast()
        XCTAssertEqual(manager.inputRoutingMode, .singleFocus)
    }

    // MARK: - Target Session IDs

    @MainActor
    func testTargetSessionIDsInSingleFocus() {
        let (manager, _, second) = makeManagerWith2Panes()
        manager.inputRoutingMode = .singleFocus
        // Focused pane is `second` (splitPane moves focus to new pane)
        let secondSession = manager.rootNode.findPane(id: second)?.sessionID
        XCTAssertNotNil(secondSession)
        XCTAssertEqual(manager.targetSessionIDs, [secondSession!])
    }

    @MainActor
    func testTargetSessionIDsInBroadcast() {
        let (manager, first, second) = makeManagerWith2Panes()
        manager.inputRoutingMode = .broadcast

        let sessionA = manager.rootNode.findPane(id: first)!.sessionID!
        let sessionB = manager.rootNode.findPane(id: second)!.sessionID!

        let targets = manager.targetSessionIDs
        XCTAssertEqual(targets.count, 2)
        XCTAssertTrue(targets.contains(sessionA))
        XCTAssertTrue(targets.contains(sessionB))
    }

    @MainActor
    func testTargetSessionIDsInSelectGroup() {
        let (manager, first, second) = makeManagerWith2Panes()
        manager.setSelectGroupMode(paneIDs: [first])

        let sessionA = manager.rootNode.findPane(id: first)!.sessionID!

        XCTAssertEqual(manager.inputRoutingMode, .selectGroup)
        XCTAssertEqual(manager.targetSessionIDs, [sessionA])

        // second pane's session should not be included
        let sessionB = manager.rootNode.findPane(id: second)!.sessionID!
        XCTAssertFalse(manager.targetSessionIDs.contains(sessionB))
    }

    @MainActor
    func testTargetSessionIDsDeduplicates() {
        let (manager, first, second) = makeManagerWith2Panes()
        // Assign the same session to both panes
        let sharedSession = UUID()
        manager.assignSession(sharedSession, to: first)
        manager.assignSession(sharedSession, to: second)

        manager.inputRoutingMode = .broadcast
        XCTAssertEqual(manager.targetSessionIDs.count, 1)
        XCTAssertEqual(manager.targetSessionIDs.first, sharedSession)
    }

    @MainActor
    func testBroadcastTargetsExcludeNilSessionIDs() {
        let manager = makeManager()
        let first = manager.focusedPaneId
        // Don't assign a session to first
        manager.splitPane(first, direction: .vertical)
        let second = manager.focusedPaneId
        let sessionB = UUID()
        manager.assignSession(sessionB, to: second)

        manager.inputRoutingMode = .broadcast
        // First pane has no session, so only second should be included
        XCTAssertEqual(manager.targetSessionIDs, [sessionB])
    }

    // MARK: - Toggle Pane In Group

    @MainActor
    func testTogglePaneInGroup() {
        let (manager, first, _) = makeManagerWith2Panes()
        manager.inputRoutingMode = .selectGroup

        // Add to group
        manager.togglePaneInGroup(first)
        XCTAssertTrue(manager.groupPaneIDs.contains(first))

        // Remove from group
        manager.togglePaneInGroup(first)
        XCTAssertFalse(manager.groupPaneIDs.contains(first))
    }

    @MainActor
    func testEmptyGroupRevertsToSingleFocus() {
        let (manager, first, _) = makeManagerWith2Panes()
        manager.setSelectGroupMode(paneIDs: [first])
        XCTAssertEqual(manager.inputRoutingMode, .selectGroup)

        // Remove the only pane in group
        manager.togglePaneInGroup(first)
        XCTAssertEqual(manager.inputRoutingMode, .singleFocus)
    }

    // MARK: - Close Pane Removes From Group

    @MainActor
    func testClosePaneRemovesFromGroup() {
        let (manager, first, second) = makeManagerWith2Panes()
        manager.setSelectGroupMode(paneIDs: [first, second])
        XCTAssertEqual(manager.groupPaneIDs.count, 2)

        manager.closePane(second)
        XCTAssertFalse(manager.groupPaneIDs.contains(second))
    }

    // MARK: - Sync Sessions Clears Stale Group Panes

    @MainActor
    func testSyncSessionsClearsStaleGroupPanes() {
        let manager = makeManager()
        let first = manager.focusedPaneId
        let sessionA = UUID()
        manager.assignSession(sessionA, to: first)

        manager.splitPane(first, direction: .vertical)
        let second = manager.focusedPaneId
        let sessionB = UUID()
        manager.assignSession(sessionB, to: second)

        // Split again so we have 3 panes (sync won't drop to 1 pane)
        manager.splitPane(second, direction: .horizontal)
        let third = manager.focusedPaneId
        let sessionC = UUID()
        manager.assignSession(sessionC, to: third)

        manager.setSelectGroupMode(paneIDs: [first, second, third])
        XCTAssertEqual(manager.groupPaneIDs.count, 3)

        // Remove sessionB from active sessions — second pane should be removed
        manager.syncSessions(activeSessionIDs: Set([sessionA, sessionC]))
        XCTAssertFalse(manager.groupPaneIDs.contains(second))
        // Other panes should remain in group
        XCTAssertTrue(manager.groupPaneIDs.contains(first))
        XCTAssertTrue(manager.groupPaneIDs.contains(third))
        XCTAssertEqual(manager.inputRoutingMode, .selectGroup)
    }

    // MARK: - Maximize / Restore Preserves Mode

    @MainActor
    func testMaximizeRestorePreservesMode() {
        let (manager, first, _) = makeManagerWith2Panes()
        manager.inputRoutingMode = .broadcast

        manager.maximizePane(first)
        // Maximize should revert to single focus
        XCTAssertEqual(manager.inputRoutingMode, .singleFocus)

        manager.restoreMaximize()
        // Restore should bring back broadcast mode
        XCTAssertEqual(manager.inputRoutingMode, .broadcast)
    }

    @MainActor
    func testMaximizeRestorePreservesGroupPaneIDs() {
        let (manager, first, second) = makeManagerWith2Panes()
        manager.setSelectGroupMode(paneIDs: [first, second])

        manager.maximizePane(first)
        XCTAssertTrue(manager.groupPaneIDs.isEmpty)

        manager.restoreMaximize()
        XCTAssertEqual(manager.groupPaneIDs, [first, second])
        XCTAssertEqual(manager.inputRoutingMode, .selectGroup)
    }

    // MARK: - Single Pane Force Single Focus

    @MainActor
    func testSinglePaneForceSingleFocus() {
        let (manager, _, second) = makeManagerWith2Panes()
        manager.inputRoutingMode = .broadcast

        // Close one pane to get down to 1
        manager.closePane(second)
        XCTAssertEqual(manager.paneCount, 1)
        XCTAssertEqual(manager.inputRoutingMode, .singleFocus)
    }

    // MARK: - Target Pane IDs

    @MainActor
    func testTargetPaneIDsInBroadcast() {
        let (manager, first, second) = makeManagerWith2Panes()
        manager.inputRoutingMode = .broadcast

        let targets = manager.targetPaneIDs
        XCTAssertTrue(targets.contains(first))
        XCTAssertTrue(targets.contains(second))
    }

    @MainActor
    func testTargetPaneIDsInSelectGroup() {
        let (manager, first, second) = makeManagerWith2Panes()
        manager.setSelectGroupMode(paneIDs: [first])

        XCTAssertTrue(manager.targetPaneIDs.contains(first))
        XCTAssertFalse(manager.targetPaneIDs.contains(second))
    }

    @MainActor
    func testSetSelectGroupModeWithEmptyRevertsToSingleFocus() {
        let manager = makeManager()
        manager.setSelectGroupMode(paneIDs: [])
        XCTAssertEqual(manager.inputRoutingMode, .singleFocus)
    }
}
#endif
