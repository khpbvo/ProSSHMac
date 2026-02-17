import Foundation

@MainActor
protocol HostStoreProtocol {
    func loadHosts() async throws -> [Host]
    func saveHosts(_ hosts: [Host]) async throws
}

@MainActor
final class FileHostStore: HostStoreProtocol {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = Self.defaultFileURL(fileManager: fileManager)
    }

    func loadHosts() async throws -> [Host] {
        if !fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [Host].self,
            from: fileURL,
            fileManager: fileManager,
            decoder: decoder
        ) ?? []
    }

    func saveHosts(_ hosts: [Host]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try EncryptedStorage.saveJSON(
            hosts,
            to: fileURL,
            fileManager: fileManager,
            encoder: encoder
        )
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)

        return baseDirectory
            .appendingPathComponent("ProSSHV2", isDirectory: true)
            .appendingPathComponent("hosts.json")
    }
}
