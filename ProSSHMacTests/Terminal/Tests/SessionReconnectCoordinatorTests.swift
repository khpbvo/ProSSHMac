#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

// Tests use nil manager throughout — all guard let manager else { return } branches
// exit early, allowing pure state manipulation without a real SessionManager.
// Do NOT call start() in tests — it starts NWPathMonitor on a background queue.

@MainActor
final class SessionReconnectCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> SessionReconnectCoordinator {
        SessionReconnectCoordinator()
    }

    private func makeHost(hostname: String = "test.local") -> ProSSHMac.Host {
        ProSSHMac.Host(
            id: UUID(),
            label: "Test",
            folder: nil,
            hostname: hostname,
            port: 22,
            username: "user",
            authMethod: .password,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Tests

    func testInitialPendingHostsIsEmpty() {
        let coordinator = makeCoordinator()
        XCTAssertTrue(coordinator.pendingReconnectHosts.isEmpty)
    }

    func testInitialNetworkReachabilityIsTrue() {
        let coordinator = makeCoordinator()
        XCTAssertTrue(coordinator.isNetworkReachable)
    }

    func testScheduleReconnectAddsToPendingHosts() {
        let coordinator = makeCoordinator()
        let sessionID = UUID()
        let host = makeHost()

        coordinator.scheduleReconnect(for: sessionID, host: host, jumpHost: nil)

        XCTAssertNotNil(coordinator.pendingReconnectHosts[sessionID])
        XCTAssertEqual(coordinator.pendingReconnectHosts[sessionID]?.host.id, host.id)
        coordinator.reconnectTask?.cancel()
    }

    func testCancelPendingRemovesEntry() {
        let coordinator = makeCoordinator()
        let sessionID = UUID()
        let host = makeHost()

        coordinator.scheduleReconnect(for: sessionID, host: host, jumpHost: nil)
        coordinator.cancelPending(sessionID: sessionID)

        XCTAssertNil(coordinator.pendingReconnectHosts[sessionID])
        coordinator.reconnectTask?.cancel()
    }

    func testRemovePendingForHostRemovesAllSessionsForHost() {
        let coordinator = makeCoordinator()
        let host = makeHost()
        let sessionID1 = UUID()
        let sessionID2 = UUID()

        coordinator.scheduleReconnect(for: sessionID1, host: host, jumpHost: nil)
        // Cancel so we don't accumulate tasks for the second schedule
        coordinator.reconnectTask?.cancel()
        coordinator.reconnectTask = nil
        coordinator.scheduleReconnect(for: sessionID2, host: host, jumpHost: nil)
        coordinator.reconnectTask?.cancel()

        coordinator.removePendingForHost(host.id)

        XCTAssertNil(coordinator.pendingReconnectHosts[sessionID1])
        XCTAssertNil(coordinator.pendingReconnectHosts[sessionID2])
    }
}

#endif
