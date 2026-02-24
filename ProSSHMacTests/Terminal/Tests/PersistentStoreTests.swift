#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

// Note: PersistentStore uses EncryptedStorage which requires Keychain access
// (AES-GCM key stored in Data Protection Keychain). Tests work in local development
// where Keychain is unlocked. In headless CI without Keychain access these will fail.

@MainActor
final class PersistentStoreTests: XCTestCase {
    private var testFilenames: [String] = []

    override func tearDown() async throws {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ProSSHV2", isDirectory: true)
        for name in testFilenames {
            if let url = base?.appendingPathComponent(name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        testFilenames = []
    }

    // MARK: - Helpers

    private func makeHostStore() -> PersistentStore<ProSSHMac.Host> {
        let name = "test-hosts-\(UUID().uuidString).json"
        testFilenames.append(name)
        return PersistentStore<ProSSHMac.Host>(filename: name)
    }

    private func makeKeyStore() -> PersistentStore<StoredSSHKey> {
        let name = "test-keys-\(UUID().uuidString).json"
        testFilenames.append(name)
        return PersistentStore<StoredSSHKey>(filename: name)
    }

    private func makeTestHost(label: String = "Test Host") -> ProSSHMac.Host {
        ProSSHMac.Host(
            id: UUID(),
            label: label,
            folder: nil,
            hostname: "test.local",
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

    private func makeTestSSHKey() -> StoredSSHKey {
        let keyID = UUID()
        let key = SSHKey(
            id: keyID,
            label: "test-key",
            type: .ed25519,
            bitLength: nil,
            fingerprint: "SHA256:testfingerprint",
            fingerprintMD5: "aa:bb:cc:dd",
            publicKeyAuthorizedFormat: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtest user@host",
            storageLocation: .encryptedStorage,
            format: .openssh,
            isPassphraseProtected: false,
            passphraseCipher: nil,
            comment: nil,
            associatedCertificates: [],
            createdAt: Date(timeIntervalSince1970: 0),
            importedFrom: nil,
            preferredCopyIDHostID: nil
        )
        return StoredSSHKey(metadata: key, privateKey: "mock-private", publicKey: "ssh-ed25519 mock", secureEnclaveTag: nil)
    }

    // MARK: - Host tests

    func testLoadReturnsEmptyArrayWhenFileDoesNotExist() async throws {
        let store = makeHostStore()
        let hosts = try await store.load()
        XCTAssertEqual(hosts, [])
    }

    func testSaveAndLoadRoundTrip() async throws {
        let store = makeHostStore()
        let host = makeTestHost()
        try await store.save([host])
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, host.id)
        XCTAssertEqual(loaded.first?.label, host.label)
    }

    func testSaveOverwritesPreviousData() async throws {
        let store = makeHostStore()
        let hostA = makeTestHost(label: "Host A")
        let hostB = makeTestHost(label: "Host B")
        try await store.save([hostA])
        try await store.save([hostB])
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.label, "Host B")
    }

    func testSaveEmptyArrayClearsStore() async throws {
        let store = makeHostStore()
        let host = makeTestHost()
        try await store.save([host])
        try await store.save([])
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [])
    }

    // MARK: - StoredSSHKey tests (validates generic T, protocol conformance)

    func testKeyStoreRoundTrip() async throws {
        let store = makeKeyStore()
        let key = makeTestSSHKey()
        try await store.save([key])
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, key.id)
    }

    func testKeyStoreProtocolConformance() async throws {
        let store = makeKeyStore()
        let key = makeTestSSHKey()
        // Call via KeyStoreProtocol typed reference
        let protocolStore: any KeyStoreProtocol = store
        try await protocolStore.saveKeys([key])
        let loaded = try await protocolStore.loadKeys()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, key.id)
    }
}

#endif
