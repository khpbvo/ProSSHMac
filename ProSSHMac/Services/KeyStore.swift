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

