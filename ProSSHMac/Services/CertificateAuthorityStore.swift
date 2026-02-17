import Foundation

@MainActor
protocol CertificateAuthorityStoreProtocol {
    func loadAuthorities() async throws -> [CertificateAuthorityModel]
    func saveAuthorities(_ authorities: [CertificateAuthorityModel]) async throws
}

@MainActor
final class FileCertificateAuthorityStore: CertificateAuthorityStoreProtocol {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = Self.defaultFileURL(fileManager: fileManager)
    }

    func loadAuthorities() async throws -> [CertificateAuthorityModel] {
        if !fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [CertificateAuthorityModel].self,
            from: fileURL,
            fileManager: fileManager,
            decoder: decoder
        ) ?? []
    }

    func saveAuthorities(_ authorities: [CertificateAuthorityModel]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try EncryptedStorage.saveJSON(
            authorities,
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
            .appendingPathComponent("certificate_authorities.json")
    }
}
