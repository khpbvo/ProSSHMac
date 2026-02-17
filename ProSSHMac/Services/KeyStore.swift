import Foundation

struct StoredSSHKey: Identifiable, Codable, Hashable {
    var metadata: SSHKey
    var privateKey: String
    var publicKey: String
    var secureEnclaveTag: String?

    nonisolated var id: UUID {
        metadata.id
    }
}

@MainActor
protocol KeyStoreProtocol {
    func loadKeys() async throws -> [StoredSSHKey]
    func saveKeys(_ keys: [StoredSSHKey]) async throws
}

@MainActor
final class FileKeyStore: KeyStoreProtocol {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = Self.defaultFileURL(fileManager: fileManager)
    }

    func loadKeys() async throws -> [StoredSSHKey] {
        if !fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [StoredSSHKey].self,
            from: fileURL,
            fileManager: fileManager,
            decoder: decoder
        ) ?? []
    }

    func saveKeys(_ keys: [StoredSSHKey]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try EncryptedStorage.saveJSON(
            keys,
            to: fileURL,
            fileManager: fileManager,
            encoder: encoder
        )
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return baseDirectory
            .appendingPathComponent("ProSSHV2", isDirectory: true)
            .appendingPathComponent("keys.json")
    }
}
