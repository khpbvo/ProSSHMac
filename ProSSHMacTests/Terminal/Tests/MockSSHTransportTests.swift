#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

#if DEBUG

final class MockSSHTransportTests: XCTestCase {

    // MARK: - Helpers

    private func makeHost(
        hostname: String = "test.local",
        username: String = "user",
        legacyModeEnabled: Bool = false
    ) -> ProSSHMac.Host {
        ProSSHMac.Host(
            id: UUID(),
            label: "Test Host",
            folder: nil,
            hostname: hostname,
            port: 22,
            username: username,
            authMethod: .password,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            legacyModeEnabled: legacyModeEnabled,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Tests

    func testConnectReturnsMockConnectionDetails() async throws {
        let transport = MockSSHTransport()
        let host = makeHost()
        let sessionID = UUID()

        let details = try await transport.connect(sessionID: sessionID, to: host, jumpHostConfig: nil)

        XCTAssertEqual(details.backend, SSHBackendKind.mock)
        XCTAssertFalse(details.negotiatedKEX.isEmpty)
        XCTAssertFalse(details.negotiatedCipher.isEmpty)
    }

    func testAuthenticateAfterConnect() async throws {
        let transport = MockSSHTransport()
        let host = makeHost()
        let sessionID = UUID()

        _ = try await transport.connect(sessionID: sessionID, to: host, jumpHostConfig: nil)
        // authenticate should not throw
        try await transport.authenticate(sessionID: sessionID, to: host, passwordOverride: nil, keyPassphraseOverride: nil)
    }

    func testDisconnectAfterConnect() async throws {
        let transport = MockSSHTransport()
        let host = makeHost()
        let sessionID = UUID()

        _ = try await transport.connect(sessionID: sessionID, to: host, jumpHostConfig: nil)
        await transport.disconnect(sessionID: sessionID)

        // After disconnect, keepalive should return false (session gone)
        let alive = await transport.sendKeepalive(sessionID: sessionID)
        XCTAssertFalse(alive)
    }

    func testSessionNotFoundErrorIfNotConnected() async throws {
        let transport = MockSSHTransport()
        let host = makeHost()
        let sessionID = UUID()

        do {
            try await transport.authenticate(sessionID: sessionID, to: host, passwordOverride: nil, keyPassphraseOverride: nil)
            XCTFail("Expected sessionNotFound error")
        } catch SSHTransportError.sessionNotFound {
            // expected
        }
    }

    func testListDirectoryReturnsEntries() async throws {
        let transport = MockSSHTransport()
        let host = makeHost()
        let sessionID = UUID()

        _ = try await transport.connect(sessionID: sessionID, to: host, jumpHostConfig: nil)
        try await transport.authenticate(sessionID: sessionID, to: host, passwordOverride: nil, keyPassphraseOverride: nil)

        let entries = try await transport.listDirectory(sessionID: sessionID, path: "/")
        XCTAssertFalse(entries.isEmpty, "Root directory should have entries in mock filesystem")
    }
}

#endif // DEBUG

#endif // canImport(XCTest)
