// Extracted from HostStore.swift, KeyStore.swift, CertificateStore.swift, CertificateAuthorityStore.swift
import Foundation

@MainActor
final class PersistentStore<T: Codable> {
    private let fileManager: FileManager
    private let fileURL: URL

    init(filename: String, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.fileURL = base
            .appendingPathComponent("ProSSHV2", isDirectory: true)
            .appendingPathComponent(filename)
    }

    func load() async throws -> [T] {
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [T].self,
            from: fileURL,
            fileManager: fileManager,
            decoder: decoder
        ) ?? []
    }

    func save(_ items: [T]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try EncryptedStorage.saveJSON(
            items,
            to: fileURL,
            fileManager: fileManager,
            encoder: encoder
        )
    }
}

extension PersistentStore: HostStoreProtocol where T == Host {
    func loadHosts() async throws -> [Host] { try await load() }
    func saveHosts(_ hosts: [Host]) async throws { try await save(hosts) }
}

extension PersistentStore: KeyStoreProtocol where T == StoredSSHKey {
    func loadKeys() async throws -> [StoredSSHKey] { try await load() }
    func saveKeys(_ keys: [StoredSSHKey]) async throws { try await save(keys) }
}

extension PersistentStore: CertificateStoreProtocol where T == SSHCertificate {
    func loadCertificates() async throws -> [SSHCertificate] { try await load() }
    func saveCertificates(_ certificates: [SSHCertificate]) async throws { try await save(certificates) }
}

extension PersistentStore: CertificateAuthorityStoreProtocol where T == CertificateAuthorityModel {
    func loadAuthorities() async throws -> [CertificateAuthorityModel] { try await load() }
    func saveAuthorities(_ authorities: [CertificateAuthorityModel]) async throws { try await save(authorities) }
}
