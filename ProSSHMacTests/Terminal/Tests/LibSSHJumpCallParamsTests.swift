#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

// LibSSHTargetParams and LibSSHJumpCallParams were widened from private → internal
// in Step 8.2 to enable these tests. LibSSHAuthenticationMaterial was also widened.

final class LibSSHJumpCallParamsTests: XCTestCase {

    // MARK: - Helpers

    private func makeHost(
        hostname: String = "target.local",
        port: UInt16 = 22,
        username: String = "ops"
    ) -> ProSSHMac.Host {
        ProSSHMac.Host(
            id: UUID(),
            label: "Test",
            folder: nil,
            hostname: hostname,
            port: port,
            username: username,
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

    // MARK: - LibSSHTargetParams tests

    func testTargetParamsHostnameAndPort() {
        let host = makeHost(hostname: "server.example.com", port: 2222)
        let params = LibSSHTargetParams(host: host, policy: .modern)

        XCTAssertEqual(params.hostname, "server.example.com")
        XCTAssertEqual(params.port, 2222)
    }

    func testTargetParamsUsernameFromHost() {
        let host = makeHost(username: "deployer")
        let params = LibSSHTargetParams(host: host, policy: .modern)

        XCTAssertEqual(params.username, "deployer")
    }

    func testTargetParamsAlgorithmStringsAreNonEmpty() {
        let host = makeHost()
        let params = LibSSHTargetParams(host: host, policy: .modern)

        XCTAssertFalse(params.kex.isEmpty, "KEX algorithms should be non-empty")
        XCTAssertFalse(params.ciphers.isEmpty, "Ciphers should be non-empty")
        XCTAssertFalse(params.hostKeys.isEmpty, "Host keys should be non-empty")
        XCTAssertFalse(params.macs.isEmpty, "MACs should be non-empty")
    }

    // MARK: - LibSSHJumpCallParams tests

    func testJumpCallParamsConstruction() {
        let jumpHost = makeHost(hostname: "jump.example.com", port: 22, username: "jumpuser")
        let material = LibSSHAuthenticationMaterial(
            password: "secret",
            privateKey: nil,
            certificate: nil,
            keyPassphrase: nil
        )

        let params = LibSSHJumpCallParams(
            jumpHost: jumpHost,
            policy: .modern,
            material: material,
            expectedFingerprint: "SHA256:mockfingerprint"
        )

        XCTAssertEqual(params.jumpHostname, "jump.example.com")
        XCTAssertEqual(params.jumpPort, 22)
        XCTAssertEqual(params.jumpUsername, "jumpuser")
    }

    func testJumpCallParamsExpectedFingerprintStored() {
        let jumpHost = makeHost()
        let material = LibSSHAuthenticationMaterial()
        let fingerprint = "SHA256:abc123def456"

        let params = LibSSHJumpCallParams(
            jumpHost: jumpHost,
            policy: .modern,
            material: material,
            expectedFingerprint: fingerprint
        )

        XCTAssertEqual(params.expectedFingerprint, fingerprint)
    }
}

#endif
