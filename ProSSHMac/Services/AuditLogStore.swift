import Foundation

protocol AuditLogStoreProtocol: Sendable {
    func loadEntries(limit: Int?) async throws -> [AuditLogEntry]
    func append(_ entry: AuditLogEntry) async throws
    func clearAll() async throws
}

final class FileAuditLogStore: AuditLogStoreProtocol, @unchecked Sendable {
    private let fileManager: FileManager
    private let fileURL: URL
    private let maxEntries: Int
    private let lock = NSLock()

    init(
        fileManager: FileManager = .default,
        maxEntries: Int = 5_000
    ) {
        self.fileManager = fileManager
        self.fileURL = Self.defaultFileURL(fileManager: fileManager)
        self.maxEntries = maxEntries
    }

    func loadEntries(limit: Int?) async throws -> [AuditLogEntry] {
        try withLock {
            let sorted = try loadEntriesLocked().sorted { $0.timestamp > $1.timestamp }
            guard let limit, limit > 0 else {
                return sorted
            }
            return Array(sorted.prefix(limit))
        }
    }

    func append(_ entry: AuditLogEntry) async throws {
        try withLock {
            var entries = try loadEntriesLocked()
            entries.append(entry)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            try persistLocked(entries)
        }
    }

    func clearAll() async throws {
        try withLock {
            try persistLocked([])
        }
    }

    private func loadEntriesLocked() throws -> [AuditLogEntry] {
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [AuditLogEntry].self,
            from: fileURL,
            fileManager: fileManager,
            decoder: decoder
        ) ?? []
    }

    private func persistLocked(_ entries: [AuditLogEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try EncryptedStorage.saveJSON(
            entries,
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
            .appendingPathComponent("audit_log.json")
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
