// SessionTabManagerTests.swift
// ProSSHV2
//
// E.1 — session tab model, reorder, close behavior, and persistence.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class SessionTabManagerTests: XCTestCase {

    @MainActor
    func testSyncCreatesTabModelAndSelectsFirst() {
        let manager = makeManager(prefix: "sync_first")
        let sessions = [makeSession(label: "A"), makeSession(label: "B")]

        manager.sync(with: sessions)

        let tabs = manager.tabs
        let selectedSessionID = manager.selectedSessionID
        let firstTabLabel = tabs[0].label
        let secondTabLabel = tabs[1].label
        let firstSessionID = sessions[0].id
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(firstTabLabel, "A")
        XCTAssertEqual(secondTabLabel, "B")
        XCTAssertEqual(selectedSessionID, firstSessionID)
    }

    @MainActor
    func testMoveTabReordersTabs() {
        let manager = makeManager(prefix: "move")
        let sessions = [makeSession(label: "A"), makeSession(label: "B"), makeSession(label: "C")]
        manager.sync(with: sessions)

        manager.moveTab(sessionID: sessions[2].id, by: -1)

        let tabs = manager.tabs
        let actualIDs = [tabs[0].session.id, tabs[1].session.id, tabs[2].session.id]
        let expectedIDs = [sessions[0].id, sessions[2].id, sessions[1].id]
        XCTAssertEqual(actualIDs, expectedIDs)
    }

    @MainActor
    func testRemoveSelectedTabSelectsNeighbor() {
        let manager = makeManager(prefix: "remove")
        let sessions = [makeSession(label: "A"), makeSession(label: "B"), makeSession(label: "C")]
        manager.sync(with: sessions)
        manager.select(sessionID: sessions[1].id)

        manager.removeTab(sessionID: sessions[1].id)

        let tabs = manager.tabs
        let selectedSessionID = manager.selectedSessionID
        let thirdSessionID = sessions[2].id
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(selectedSessionID, thirdSessionID)
    }

    @MainActor
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

        let tabs = rehydrated.tabs
        let actualIDs = [tabs[0].session.id, tabs[1].session.id, tabs[2].session.id]
        let expectedIDs = [sessions[2].id, sessions[0].id, sessions[1].id]
        let selectedSessionID = rehydrated.selectedSessionID
        let expectedSelectedID = sessions[1].id
        XCTAssertEqual(actualIDs, expectedIDs)
        XCTAssertEqual(selectedSessionID, expectedSelectedID)
    }

    @MainActor
    private func makeManager(prefix: String) -> SessionTabManager {
        SessionTabManager(defaults: makeDefaults(suffix: prefix), keyPrefix: prefix)
    }

    private func makeDefaults(suffix: String) -> UserDefaults {
        let suite = "SessionTabManagerTests.\(suffix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
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
