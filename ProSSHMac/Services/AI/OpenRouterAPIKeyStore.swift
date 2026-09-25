import Foundation
import Security

protocol OpenRouterAPIKeyStoring: Sendable {
    func loadAPIKey() async throws -> String?
    func saveAPIKey(_ key: String) async throws
    func deleteAPIKey() async throws
}

protocol LegacyProviderKeyDeleting: Sendable {
    func deleteLegacyProviderKeys() async throws
}

enum OpenRouterKeyStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status): return "Keychain operation failed (\(status))."
        }
    }
}

actor KeychainOpenRouterAPIKeyStore: OpenRouterAPIKeyStoring, LegacyProviderKeyDeleting {
    nonisolated static let service = "nl.budgetsoft.ProSSHMac.openrouter"
    nonisolated static let legacyServices = [
        "nl.budgetsoft.ProSSHMac.llm.openai",
        "nl.budgetsoft.ProSSHMac.llm.mistral",
        "nl.budgetsoft.ProSSHMac.llm.anthropic",
        "nl.budgetsoft.ProSSHMac.llm.deepseek",
        "nl.budgetsoft.ProSSHV2.openai",
    ]
    private let account = "api-key"

    func loadAPIKey() throws -> String? {
        if let key = try load(service: Self.service, dataProtection: true) { return key }
        return try load(service: Self.service, dataProtection: false)
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenRouterError.missingAPIKey }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        let update: [CFString: Any] = [kSecValueData: Data(trimmed.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw OpenRouterKeyStoreError.keychain(updateStatus) }
        var add = query
        add[kSecValueData] = Data(trimmed.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw OpenRouterKeyStoreError.keychain(addStatus) }
    }

    func deleteAPIKey() throws {
        try delete(service: Self.service, dataProtection: true)
        try delete(service: Self.service, dataProtection: false)
    }

    func deleteLegacyProviderKeys() throws {
        for service in Self.legacyServices {
            try delete(service: service, dataProtection: true)
            try delete(service: service, dataProtection: false)
        }
    }

    private func load(service: String, dataProtection: Bool) throws -> String? {
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
        default: throw OpenRouterKeyStoreError.keychain(status)
        }
    }

    private func delete(service: String, dataProtection: Bool) throws {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain] = true }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenRouterKeyStoreError.keychain(status)
        }
    }
}

@MainActor
final class LegacyProviderKeyCleanup {
    private let deleter: any LegacyProviderKeyDeleting
    private let defaults: UserDefaults
    private let marker = "ai.openrouter.legacyKeysDeleted.v1"

    init(deleter: any LegacyProviderKeyDeleting, defaults: UserDefaults = .standard) {
        self.deleter = deleter
        self.defaults = defaults
    }

    func runIfNeeded() async throws {
        guard !defaults.bool(forKey: marker) else { return }
        try await deleter.deleteLegacyProviderKeys()
        defaults.removeObject(forKey: "ai.provider.active")
        defaults.removeObject(forKey: "ai.model.active")
        defaults.removeObject(forKey: "ai.logging.logOpenAIResponsesPayloads")
        defaults.set(true, forKey: marker)
    }
}
