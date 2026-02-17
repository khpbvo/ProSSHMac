import Foundation
import CryptoKit
import Security

enum EncryptedStorageError: LocalizedError {
    case keychainFailure(status: OSStatus)
    case encryptionFailed
    case malformedPayload

    var errorDescription: String? {
        switch self {
        case let .keychainFailure(status):
            return "Secure key storage failed (status \(status))."
        case .encryptionFailed:
            return "Failed to encrypt data for storage."
        case .malformedPayload:
            return "Encrypted storage payload is malformed."
        }
    }
}

enum EncryptedStorage {
    nonisolated private static let keyService = "nl.budgetsoft.ProSSHV2.encrypted-storage"
    nonisolated private static let keyAccount = "master-key-v1"
    nonisolated private static let envelopeMagic = Data("PSSHENC1".utf8)
    nonisolated private static let envelopeVersion: UInt8 = 1
    nonisolated private static let keychainLock = NSLock()

    nonisolated static func loadJSON<T: Decodable>(
        _ type: T.Type,
        from fileURL: URL,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) throws -> T? {
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return nil
        }

        var persisted = try Data(contentsOf: fileURL)
        defer { scrub(&persisted) }
        var plaintext: Data

        if isEncryptedEnvelope(persisted) {
            plaintext = try decryptEnvelope(persisted)
        } else {
            // Migrate legacy plaintext JSON to encrypted storage on first read.
            plaintext = persisted
            try writeEncryptedData(plaintext, to: fileURL, fileManager: fileManager)
        }
        defer { scrub(&plaintext) }

        return try decoder.decode(type, from: plaintext)
    }

    nonisolated static func saveJSON<T: Encodable>(
        _ value: T,
        to fileURL: URL,
        fileManager: FileManager,
        encoder: JSONEncoder
    ) throws {
        var plaintext = try encoder.encode(value)
        defer { scrub(&plaintext) }
        try writeEncryptedData(plaintext, to: fileURL, fileManager: fileManager)
    }

    nonisolated private static func writeEncryptedData(
        _ plaintext: Data,
        to fileURL: URL,
        fileManager: FileManager
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encrypted = try encryptEnvelope(plaintext)
        try encrypted.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path(percentEncoded: false)
        )
    }

    nonisolated private static func isEncryptedEnvelope(_ data: Data) -> Bool {
        data.count > envelopeMagic.count + 1 && data.prefix(envelopeMagic.count) == envelopeMagic
    }

    nonisolated private static func encryptEnvelope(_ plaintext: Data) throws -> Data {
        var keyData = try loadOrCreateMasterKey()
        defer { scrub(&keyData) }
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw EncryptedStorageError.encryptionFailed
        }

        var payload = Data()
        payload.append(envelopeMagic)
        payload.append(envelopeVersion)
        payload.append(combined)
        return payload
    }

    nonisolated private static func decryptEnvelope(_ envelope: Data) throws -> Data {
        let minimumCount = envelopeMagic.count + 1 + 12 + 16
        guard envelope.count >= minimumCount else {
            throw EncryptedStorageError.malformedPayload
        }

        let prefix = envelope.prefix(envelopeMagic.count)
        guard prefix == envelopeMagic else {
            throw EncryptedStorageError.malformedPayload
        }

        let versionIndex = envelopeMagic.count
        guard envelope[versionIndex] == envelopeVersion else {
            throw EncryptedStorageError.malformedPayload
        }

        var combined = Data(envelope.dropFirst(envelopeMagic.count + 1))
        defer { scrub(&combined) }
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        var keyData = try loadOrCreateMasterKey()
        defer { scrub(&keyData) }
        let key = SymmetricKey(data: keyData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    nonisolated private static func loadOrCreateMasterKey() throws -> Data {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        if let existing = try loadKeyFromKeychain() {
            return existing
        }

        // Migrate key from legacy login keychain to Data Protection keychain
        if let legacy = try loadKeyFromLegacyKeychain() {
            try saveKeyToKeychain(legacy)
            deleteLegacyKeychainKey()
            return legacy
        }

        var generated = Data(count: 32)
        let status = generated.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        guard status == errSecSuccess else {
            throw EncryptedStorageError.keychainFailure(status: status)
        }

        try saveKeyToKeychain(generated)
        return generated
    }

    nonisolated private static func loadKeyFromKeychain() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keyService,
            kSecAttrAccount: keyAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw EncryptedStorageError.keychainFailure(status: status)
        }
    }

    nonisolated private static func saveKeyToKeychain(_ key: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keyService,
            kSecAttrAccount: keyAccount,
            kSecUseDataProtectionKeychain: true
        ]
        SecItemDelete(query as CFDictionary)

        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keyService,
            kSecAttrAccount: keyAccount,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
            kSecValueData: key
        ]

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptedStorageError.keychainFailure(status: status)
        }
    }

    nonisolated private static func loadKeyFromLegacyKeychain() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keyService,
            kSecAttrAccount: keyAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw EncryptedStorageError.keychainFailure(status: status)
        }
    }

    nonisolated private static func deleteLegacyKeychainKey() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keyService,
            kSecAttrAccount: keyAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    nonisolated private static func scrub(_ data: inout Data) {
        guard !data.isEmpty else {
            return
        }
        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            memset_s(baseAddress, buffer.count, 0, buffer.count)
        }
    }
}
