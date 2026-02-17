import Foundation

@MainActor
protocol CertificateStoreProtocol {
    func loadCertificates() async throws -> [SSHCertificate]
    func saveCertificates(_ certificates: [SSHCertificate]) async throws
}

@MainActor
final class FileCertificateStore: CertificateStoreProtocol {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = Self.defaultFileURL(fileManager: fileManager)
    }

    func loadCertificates() async throws -> [SSHCertificate] {
        if !fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [SSHCertificate].self,
            from: fileURL,
            fileManager: fileManager,
            decoder: decoder
        ) ?? []
    }

    func saveCertificates(_ certificates: [SSHCertificate]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try EncryptedStorage.saveJSON(
            certificates,
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
            .appendingPathComponent("certificates.json")
    }
}
