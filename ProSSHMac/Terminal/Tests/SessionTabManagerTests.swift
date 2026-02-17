// SessionTabManagerTests.swift
// ProSSHV2
//
// E.1 — session tab model, reorder, close behavior, and persistence.

#if canImport(XCTest)
import XCTest

@MainActor
final class SessionTabManagerTests: XCTestCase {

    func testSyncCreatesTabModelAndSelectsFirst() {
        let manager = makeManager(prefix: "sync_first")
        let sessions = [makeSession(label: "A"), makeSession(label: "B")]

        manager.sync(with: sessions)

        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.tabs[0].label, "A")
        XCTAssertEqual(manager.tabs[1].label, "B")
        XCTAssertEqual(manager.selectedSessionID, sessions[0].id)
    }

    func testMoveTabReordersTabs() {
        let manager = makeManager(prefix: "move")
        let sessions = [makeSession(label: "A"), makeSession(label: "B"), makeSession(label: "C")]
        manager.sync(with: sessions)

        manager.moveTab(sessionID: sessions[2].id, by: -1)

        XCTAssertEqual(manager.tabs.map { $0.session.id }, [sessions[0].id, sessions[2].id, sessions[1].id])
    }

    func testRemoveSelectedTabSelectsNeighbor() {
        let manager = makeManager(prefix: "remove")
        let sessions = [makeSession(label: "A"), makeSession(label: "B"), makeSession(label: "C")]
        manager.sync(with: sessions)
        manager.select(sessionID: sessions[1].id)

        manager.removeTab(sessionID: sessions[1].id)

        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedSessionID, sessions[2].id)
    }

    func testSelectionAndOrderPersistAcrossManagerInstances() {
        let defaults = makeDefaults(suffix: "persist")
        let prefix = "persist"

        let sessions = [makeSession(label: "A"), makeSession(label: "B"), makeSession(label: "C")]
        do {
            let manager = SessionTabManager(defaults: defaults, keyPrefix: prefix)
            manager.sync(with: sessions)
            manager.moveTab(sessionID: sessions[2].id, by: -2)
            manager.select(sessionID: sessions[1].id)
        }

        let rehydrated = SessionTabManager(defaults: defaults, keyPrefix: prefix)
        rehydrated.sync(with: sessions)

        XCTAssertEqual(rehydrated.tabs.map { $0.session.id }, [sessions[2].id, sessions[0].id, sessions[1].id])
        XCTAssertEqual(rehydrated.selectedSessionID, sessions[1].id)
    }

    private func makeManager(prefix: String) -> SessionTabManager {
        SessionTabManager(defaults: makeDefaults(suffix: prefix), keyPrefix: prefix)
    }

    private func makeDefaults(suffix: String) -> UserDefaults {
        let suite = "SessionTabManagerTests.\(suffix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSession(label: String) -> Session {
        Session(
            id: UUID(),
            kind: .ssh(hostID: UUID()),
            hostLabel: label,
            username: "user",
            hostname: "example.com",
            port: 22,
            state: .connected,
            negotiatedKEX: nil,
            negotiatedCipher: nil,
            negotiatedHostKeyType: nil,
            negotiatedHostFingerprint: nil,
            usesLegacyCrypto: false,
            usesAgentForwarding: false,
            securityAdvisory: nil,
            transportBackend: nil,
            jumpHostLabel: nil,
            startedAt: .now,
            endedAt: nil,
            errorMessage: nil
        )
    }
}
#endif
