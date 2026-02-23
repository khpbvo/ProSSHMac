#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class SessionManagerSFTPSidebarTests: XCTestCase {
    func testListRemoteDirectoryRequiresConnectedSession() async {
        let manager = SessionManager(
            transport: SidebarSFTPTransportStub(),
            knownHostsStore: SidebarKnownHostsStore()
        )

        do {
            _ = try await manager.listRemoteDirectory(sessionID: UUID(), path: "/")
            XCTFail("Expected sessionNotFound")
        } catch let error as SSHTransportError {
            XCTAssertEqual(error.errorDescription, SSHTransportError.sessionNotFound.errorDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testListRemoteDirectoryReturnsSFTPEntriesForConnectedSession() async throws {
        let entries: [SFTPDirectoryEntry] = [
            .init(path: "/var/log", name: "log", isDirectory: true, size: 0, permissions: 0o755, modifiedAt: nil),
            .init(path: "/var/motd", name: "motd", isDirectory: false, size: 12, permissions: 0o644, modifiedAt: nil),
        ]
        let transport = SidebarSFTPTransportStub(
            listResponsesByPath: ["/var": entries]
        )
        let manager = SessionManager(
            transport: transport,
            knownHostsStore: SidebarKnownHostsStore()
        )

        let session = try await manager.connect(to: makeHost())
        defer {
            Task { @MainActor in
                await manager.disconnect(sessionID: session.id)
            }
        }

        let listed = try await manager.listRemoteDirectory(sessionID: session.id, path: "/var")
        XCTAssertEqual(listed, entries)

        let calls = await transport.capturedListCalls()
        XCTAssertEqual(calls, ["/var"])
    }

    func testListRemoteDirectoryPropagatesTransportFailure() async throws {
        let transport = SidebarSFTPTransportStub(
            listResponsesByPath: [:],
            listErrorsByPath: ["/restricted": .transportFailure(message: "Permission denied.")]
        )
        let manager = SessionManager(
            transport: transport,
            knownHostsStore: SidebarKnownHostsStore()
        )

        let session = try await manager.connect(to: makeHost())
        defer {
            Task { @MainActor in
                await manager.disconnect(sessionID: session.id)
            }
        }

        do {
            _ = try await manager.listRemoteDirectory(sessionID: session.id, path: "/restricted")
            XCTFail("Expected transport failure")
        } catch let error as SSHTransportError {
            XCTAssertEqual(error.errorDescription, SSHTransportError.transportFailure(message: "Permission denied.").errorDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeHost() -> ProSSHMac.Host {
        ProSSHMac.Host(
            id: UUID(),
            label: "Sidebar Test Host",
            folder: nil,
            hostname: "sidebar.test.local",
            port: 22,
            username: "ops",
            authMethod: .password,
            keyReference: nil,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: nil,
            algorithmPreferences: nil,
            pinnedHostKeyAlgorithms: [],
            agentForwardingEnabled: false,
            legacyModeEnabled: false,
            tags: [],
            notes: nil,
            lastConnected: nil,
            createdAt: .now
        )
    }
}

private actor SidebarKnownHostsStore: KnownHostsStoreProtocol {
    func allEntries() async throws -> [KnownHostEntry] { [] }

    func evaluate(
        hostname: String,
        port: UInt16,
        hostKeyType: String,
        presentedFingerprint: String
    ) async throws -> KnownHostVerificationResult {
        .trusted
    }

    func trust(challenge: KnownHostVerificationChallenge) async throws {}

    func clearAll() async throws {}
}

private actor SidebarSFTPTransportStub: SSHTransporting {
    private var connectedSessionIDs: Set<UUID> = []
    private var authenticatedSessionIDs: Set<UUID> = []
    private var listResponsesByPath: [String: [SFTPDirectoryEntry]]
    private var listErrorsByPath: [String: SSHTransportError]
    private var listCalls: [String] = []

    init(
        listResponsesByPath: [String: [SFTPDirectoryEntry]] = [:],
        listErrorsByPath: [String: SSHTransportError] = [:]
    ) {
        self.listResponsesByPath = listResponsesByPath
        self.listErrorsByPath = listErrorsByPath
    }

    func connect(sessionID: UUID, to host: ProSSHMac.Host, jumpHostConfig: JumpHostConfig?) async throws -> SSHConnectionDetails {
        connectedSessionIDs.insert(sessionID)
        return SSHConnectionDetails(
            negotiatedKEX: "curve25519-sha256",
            negotiatedCipher: "chacha20-poly1305@openssh.com",
            negotiatedHostKeyType: "ssh-ed25519",
            negotiatedHostFingerprint: "SHA256:sidebar-test",
            usedLegacyAlgorithms: false,
            securityAdvisory: nil,
            backend: .mock
        )
    }

    func authenticate(sessionID: UUID, to host: ProSSHMac.Host, passwordOverride: String?, keyPassphraseOverride: String?) async throws {
        guard connectedSessionIDs.contains(sessionID) else {
            throw SSHTransportError.sessionNotFound
        }
        authenticatedSessionIDs.insert(sessionID)
    }

    func openShell(sessionID: UUID, pty: PTYConfiguration, enableAgentForwarding: Bool) async throws -> any SSHShellChannel {
        guard authenticatedSessionIDs.contains(sessionID) else {
            throw SSHTransportError.authenticationFailed
        }
        return SidebarSFTPShellChannel()
    }

    func listDirectory(sessionID: UUID, path: String) async throws -> [SFTPDirectoryEntry] {
        guard authenticatedSessionIDs.contains(sessionID) else {
            throw SSHTransportError.sessionNotFound
        }
        listCalls.append(path)
        if let error = listErrorsByPath[path] {
            throw error
        }
        return listResponsesByPath[path] ?? []
    }

    func uploadFile(sessionID: UUID, localPath: String, remotePath: String) async throws -> SFTPTransferResult {
        guard authenticatedSessionIDs.contains(sessionID) else {
            throw SSHTransportError.sessionNotFound
        }
        return SFTPTransferResult(bytesTransferred: 0, totalBytes: 0)
    }

    func downloadFile(sessionID: UUID, remotePath: String, localPath: String) async throws -> SFTPTransferResult {
        guard authenticatedSessionIDs.contains(sessionID) else {
            throw SSHTransportError.sessionNotFound
        }
        return SFTPTransferResult(bytesTransferred: 0, totalBytes: 0)
    }

    func openForwardChannel(sessionID: UUID, remoteHost: String, remotePort: UInt16, sourceHost: String, sourcePort: UInt16) async throws -> any SSHForwardChannel {
        guard authenticatedSessionIDs.contains(sessionID) else {
            throw SSHTransportError.sessionNotFound
        }
        return SidebarSFTPForwardChannel()
    }

    func sendKeepalive(sessionID: UUID) async -> Bool {
        connectedSessionIDs.contains(sessionID)
    }

    func disconnect(sessionID: UUID) async {
        connectedSessionIDs.remove(sessionID)
        authenticatedSessionIDs.remove(sessionID)
    }

    func capturedListCalls() -> [String] {
        listCalls
    }
}

private final class SidebarSFTPShellChannel: SSHShellChannel, @unchecked Sendable {
    nonisolated let rawOutput: AsyncStream<Data>

    init() {
        rawOutput = AsyncStream<Data> { _ in }
    }

    func send(_ input: String) async throws {}

    func resizePTY(columns: Int, rows: Int) async throws {}

    func close() async {}
}

private actor SidebarSFTPForwardChannel: SSHForwardChannel {
    func read() async throws -> Data? { nil }

    func write(_ data: Data) async throws {}

    var isOpen: Bool { true }

    func close() async {}
}
#endif
