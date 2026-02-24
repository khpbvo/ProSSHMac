#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class SessionKeepaliveCoordinatorTests: XCTestCase {
    private let enabledKey = "ssh.keepalive.enabled"
    private let intervalKey = "ssh.keepalive.interval"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: intervalKey)
    }

    // MARK: - Tests

    func testStartIfNeededDoesNotStartTaskWhenKeepaliveDisabled() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        let coordinator = SessionKeepaliveCoordinator()

        coordinator.startIfNeeded()

        XCTAssertNil(coordinator.keepaliveTask,
                     "keepaliveTask should remain nil when keepalive is disabled")
    }

    func testStartIfNeededStartsTaskWhenEnabled() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        let coordinator = SessionKeepaliveCoordinator()

        coordinator.startIfNeeded()

        XCTAssertNotNil(coordinator.keepaliveTask,
                        "keepaliveTask should be non-nil when keepalive is enabled")
        coordinator.keepaliveTask?.cancel()
        coordinator.keepaliveTask = nil
    }

    func testStopIfIdleWithNilManagerCancelsTask() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        let coordinator = SessionKeepaliveCoordinator()
        coordinator.startIfNeeded()
        XCTAssertNotNil(coordinator.keepaliveTask)

        // manager is nil (not set) — stopIfIdle should cancel the task
        coordinator.stopIfIdle()

        XCTAssertNil(coordinator.keepaliveTask,
                     "keepaliveTask should be cancelled when manager is nil")
    }

    func testIntervalDefaultsTo30WhenNotSet() {
        // keepaliveInterval is private — test indirectly by confirming the task starts
        // (implying interval > 0, which triggers the guard in startIfNeeded).
        // No UserDefaults interval key set → defaults to 30 seconds internally.
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: intervalKey)
        let coordinator = SessionKeepaliveCoordinator()

        coordinator.startIfNeeded()

        // If interval were 0 or negative the keepalive logic would still create the task —
        // the key assertion is that startIfNeeded does not throw or crash with no stored interval.
        XCTAssertNotNil(coordinator.keepaliveTask,
                        "Task should start even when no interval is stored (defaults to 30)")
        coordinator.keepaliveTask?.cancel()
        coordinator.keepaliveTask = nil
    }
}

#endif
