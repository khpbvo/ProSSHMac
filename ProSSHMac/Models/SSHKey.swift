import Foundation

enum KeyType: String, Codable, CaseIterable, Identifiable {
    case rsa
    case ed25519
    case ecdsa
    case dsa

    var id: String { rawValue }
}

enum KeyFormat: String, Codable, CaseIterable, Identifiable {
    case openssh
    case pem
    case pkcs8

    var id: String { rawValue }
}

enum PrivateKeyCipher: String, Codable, CaseIterable, Identifiable {
    case aes256ctr
    case chacha20Poly1305

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aes256ctr:
            return "AES-256-CTR"
        case .chacha20Poly1305:
            return "ChaCha20-Poly1305"
        }
    }
}

enum StorageLocation: String, Codable, CaseIterable, Identifiable {
    case secureEnclave
    case encryptedStorage

    var id: String { rawValue }
}

struct SSHKey: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    var type: KeyType
    var bitLength: Int?
    var fingerprint: String
    var fingerprintMD5: String
    var publicKeyAuthorizedFormat: String
    var storageLocation: StorageLocation
    var format: KeyFormat
    var isPassphraseProtected: Bool
    var passphraseCipher: PrivateKeyCipher?
    var comment: String?
    var associatedCertificates: [UUID]
    var createdAt: Date
    var importedFrom: String?
    var preferredCopyIDHostID: UUID? = nil

    static let previewKeys: [SSHKey] = [
        SSHKey(
            id: UUID(),
            label: "Ops Laptop Key",
            type: .ed25519,
            bitLength: 256,
            fingerprint: "SHA256:q8B5Z9xM0wj+fW2Fa+ITQ4eD9P6rPUGL4uG53jA2H1g",
            fingerprintMD5: "MD5:4f:98:9c:35:7f:20:5a:77:b8:7a:03:20:3a:11:7f:2e",
            publicKeyAuthorizedFormat: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMOCKEYPLACEHOLDER ops@prossh",
            storageLocation: .encryptedStorage,
            format: .openssh,
            isPassphraseProtected: true,
            passphraseCipher: .chacha20Poly1305,
            comment: "Primary interactive key",
            associatedCertificates: [],
            createdAt: .now,
            importedFrom: "Generated on device",
            preferredCopyIDHostID: nil
        )
    ]
}
