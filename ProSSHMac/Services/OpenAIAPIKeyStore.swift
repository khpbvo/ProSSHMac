import Foundation
import Security

protocol OpenAIAPIKeyStoring: Sendable {
    func loadAPIKey() async throws -> String?
    func saveAPIKey(_ apiKey: String) async throws
    func deleteAPIKey() async throws
}

protocol OpenAIAPIKeyProviding: Sendable {
    func currentAPIKey() async -> String?
}

enum OpenAIAPIKeyStoreError: LocalizedError {
    case invalidEncoding
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "The API key could not be encoded for secure storage."
        case let .keychainFailure(status):
            return "API key Keychain operation failed (status \(status))."
        }
    }
}

actor KeychainOpenAIAPIKeyStore: OpenAIAPIKeyStoring {
    private let service: String
    private let account: String

    init(
        service: String = "nl.budgetsoft.ProSSHV2.openai",
        account: String = "api-key"
    ) {
        self.service = service
        self.account = account
    }

    func loadAPIKey() throws -> String? {
        if let key = try loadFromDataProtectionKeychain() {
            return key
        }

        if let legacyKey = try loadFromLegacyKeychain() {
            try saveToDataProtectionKeychain(legacyKey)
            try deleteLegacyKeychainItem()
            return legacyKey
        }

        return nil
    }

    func saveAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey()
            return
        }

        guard let encoded = trimmed.data(using: .utf8) else {
            throw OpenAIAPIKeyStoreError.invalidEncoding
        }

        try saveDataProtectionData(encoded)
    }

    func deleteAPIKey() throws {
        try deleteDataProtectionKeychainItem()
        try deleteLegacyKeychainItem()
    }

    private func loadFromDataProtectionKeychain() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw OpenAIAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func loadFromLegacyKeychain() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw OpenAIAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func saveToDataProtectionKeychain(_ key: String) throws {
        guard let encoded = key.data(using: .utf8) else {
            throw OpenAIAPIKeyStoreError.invalidEncoding
        }
        try saveDataProtectionData(encoded)
    }

    private func saveDataProtectionData(_ data: Data) throws {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
            kSecValueData: data
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OpenAIAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func deleteDataProtectionKeychainItem() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAIAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func deleteLegacyKeychainItem() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAIAPIKeyStoreError.keychainFailure(status)
        }
    }
}

struct DefaultOpenAIAPIKeyProvider: OpenAIAPIKeyProviding {
    private let store: any OpenAIAPIKeyStoring

    init(store: any OpenAIAPIKeyStoring) {
        self.store = store
    }

    func currentAPIKey() async -> String? {
        do {
            return try await store.loadAPIKey()
        } catch {
            return nil
        }
    }
}
