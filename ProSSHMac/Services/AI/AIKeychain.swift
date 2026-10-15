import Foundation
import Security

/// An AI provider's API key, kept in the Keychain.
protocol AIAPIKeyStoring: Sendable {
    func loadAPIKey() async throws -> String?
    func saveAPIKey(_ key: String) async throws
    func deleteAPIKey() async throws
}

enum AIKeychainError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status): return "Keychain operation failed (\(status))."
        }
    }
}

/// Generic-password Keychain access shared by the provider key stores. New items go to the
/// data-protection Keychain, readable only while this device is unlocked; lookups and deletes
/// can also target the legacy file-based Keychain.
nonisolated enum KeychainGenericPassword {
    static func load(service: String, account: String, dataProtection: Bool) throws -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain] = true }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound: return nil
        default: throw AIKeychainError.keychain(status)
        }
    }

    /// Loads from the data-protection Keychain first, then the legacy one.
    static func load(service: String, account: String) throws -> String? {
        if let value = try load(service: service, account: account, dataProtection: true) { return value }
        return try load(service: service, account: account, dataProtection: false)
    }

    static func save(_ value: String, service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        let update: [CFString: Any] = [kSecValueData: Data(value.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw AIKeychainError.keychain(updateStatus) }
        var add = query
        add[kSecValueData] = Data(value.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AIKeychainError.keychain(addStatus) }
    }

    static func delete(service: String, account: String, dataProtection: Bool) throws {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain] = true }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIKeychainError.keychain(status)
        }
    }

    /// Deletes from both the data-protection and the legacy Keychain.
    static func delete(service: String, account: String) throws {
        try delete(service: service, account: account, dataProtection: true)
        try delete(service: service, account: account, dataProtection: false)
    }
}
