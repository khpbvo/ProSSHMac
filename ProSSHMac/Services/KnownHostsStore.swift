import Foundation

struct KnownHostEntry: Identifiable, Codable, Hashable, Sendable {
    var hostname: String
    var port: UInt16
    var hostKeyType: String
    var fingerprint: String
    var firstTrustedAt: Date
    var lastVerifiedAt: Date

    var id: String {
        "\(hostname.lowercased()):\(port):\(hostKeyType)"
    }
}

struct KnownHostVerificationChallenge: Identifiable, Equatable, Sendable {
    var hostname: String
    var port: UInt16
    var hostKeyType: String
    var presentedFingerprint: String
    var expectedFingerprint: String?

    var id: String {
        "\(hostname.lowercased()):\(port):\(hostKeyType)"
    }

    var isMismatch: Bool {
        guard let expectedFingerprint else { return false }
        return expectedFingerprint != presentedFingerprint
    }
}

enum KnownHostVerificationResult: Sendable {
    case trusted
    case requiresUserApproval(KnownHostVerificationChallenge)
}

protocol KnownHostsStoreProtocol: Sendable {
    func allEntries() async throws -> [KnownHostEntry]
    func evaluate(
        hostname: String,
        port: UInt16,
        hostKeyType: String,
        presentedFingerprint: String
    ) async throws -> KnownHostVerificationResult
    func trust(challenge: KnownHostVerificationChallenge) async throws
    func clearAll() async throws
}

actor FileKnownHostsStore: KnownHostsStoreProtocol {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = Self.defaultFileURL(fileManager: fileManager)
    }

    func allEntries() throws -> [KnownHostEntry] {
        try loadEntries().sorted {
            $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending
        }
    }

    func evaluate(
        hostname: String,
        port: UInt16,
        hostKeyType: String,
        presentedFingerprint: String
    ) throws -> KnownHostVerificationResult {
        let normalizedHostname = hostname.lowercased()
        var entries = try loadEntries()

        guard let index = entries.firstIndex(where: {
            $0.hostname.lowercased() == normalizedHostname && $0.port == port
        }) else {
            return .requiresUserApproval(
                KnownHostVerificationChallenge(
                    hostname: hostname,
                    port: port,
                    hostKeyType: hostKeyType,
                    presentedFingerprint: presentedFingerprint,
                    expectedFingerprint: nil
                )
            )
        }

        let existing = entries[index]
        guard existing.fingerprint == presentedFingerprint else {
            return .requiresUserApproval(
                KnownHostVerificationChallenge(
                    hostname: hostname,
                    port: port,
                    hostKeyType: hostKeyType,
                    presentedFingerprint: presentedFingerprint,
                    expectedFingerprint: existing.fingerprint
                )
            )
        }

        entries[index].hostKeyType = hostKeyType
        entries[index].lastVerifiedAt = .now
        try persist(entries)
        return .trusted
    }

    func trust(challenge: KnownHostVerificationChallenge) throws {
        var entries = try loadEntries()
        let normalizedHostname = challenge.hostname.lowercased()
        let now = Date.now

        if let index = entries.firstIndex(where: {
            $0.hostname.lowercased() == normalizedHostname && $0.port == challenge.port
        }) {
            entries[index].hostKeyType = challenge.hostKeyType
            entries[index].fingerprint = challenge.presentedFingerprint
            entries[index].lastVerifiedAt = now
        } else {
            entries.append(
                KnownHostEntry(
                    hostname: challenge.hostname,
                    port: challenge.port,
                    hostKeyType: challenge.hostKeyType,
                    fingerprint: challenge.presentedFingerprint,
                    firstTrustedAt: now,
                    lastVerifiedAt: now
                )
            )
        }

        try persist(entries)
    }

    func clearAll() throws {
        try persist([])
    }

    private func loadEntries() throws -> [KnownHostEntry] {
        if !fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [KnownHostEntry].self,
            from: fileURL,
            fileManager: fileManager,
            decoder: decoder
        ) ?? []
    }

    private func persist(_ entries: [KnownHostEntry]) throws {
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
            .appendingPathComponent("known_hosts.json")
    }
}
