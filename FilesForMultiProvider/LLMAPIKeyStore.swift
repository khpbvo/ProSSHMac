// LLMAPIKeyStore.swift
// ProSSHMac
//
// Generic Keychain-backed API key store, parameterized by provider.
// Replaces the OpenAI-specific KeychainOpenAIAPIKeyStore.

import Foundation
import Security

// MARK: - Protocols

protocol LLMAPIKeyStoring: Sendable {
    func loadAPIKey(for provider: LLMProviderID) async throws -> String?
    func saveAPIKey(_ apiKey: String, for provider: LLMProviderID) async throws
    func deleteAPIKey(for provider: LLMProviderID) async throws
}

// MARK: - Errors

enum LLMAPIKeyStoreError: LocalizedError {
    case invalidEncoding
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "The API key could not be encoded for secure storage."
        case let .keychainFailure(status):
            return "Keychain operation failed (status \(status))."
        }
    }
}

// MARK: - Keychain Implementation

actor KeychainLLMAPIKeyStore: LLMAPIKeyStoring {

    private let servicePrefix: String
    private let account: String

    init(
        servicePrefix: String = "nl.budgetsoft.ProSSHMac.llm",
        account: String = "api-key"
    ) {
        self.servicePrefix = servicePrefix
        self.account = account
    }

    /// Keychain service identifier per provider, e.g. "nl.budgetsoft.ProSSHMac.llm.mistral"
    private func service(for provider: LLMProviderID) -> String {
        "\(servicePrefix).\(provider.rawValue)"
    }

    // MARK: - Public API

    func loadAPIKey(for provider: LLMProviderID) throws -> String? {
        let svc = service(for: provider)

        // Try data-protection keychain first
        if let key = try loadFromKeychain(service: svc, useDataProtection: true) {
            return key
        }

        // Fall back to legacy (non-data-protection) keychain
        if let legacyKey = try loadFromKeychain(service: svc, useDataProtection: false) {
            // Migrate to data-protection keychain
            try saveToKeychain(legacyKey, service: svc)
            try deleteFromKeychain(service: svc, useDataProtection: false)
            return legacyKey
        }

        // Migration from old OpenAI-specific keychain service
        if provider == .openai {
            let legacyService = "nl.budgetsoft.ProSSHV2.openai"
            if let oldKey = try loadFromKeychain(service: legacyService, useDataProtection: true)
                ?? loadFromKeychain(service: legacyService, useDataProtection: false) {
                try saveToKeychain(oldKey, service: svc)
                // Don't delete old key yet — OpenAIAPIKeyStore might still be referenced
                return oldKey
            }
        }

        return nil
    }

    func saveAPIKey(_ apiKey: String, for provider: LLMProviderID) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey(for: provider)
            return
        }
        try saveToKeychain(trimmed, service: service(for: provider))
    }

    func deleteAPIKey(for provider: LLMProviderID) throws {
        let svc = service(for: provider)
        try deleteFromKeychain(service: svc, useDataProtection: true)
        try deleteFromKeychain(service: svc, useDataProtection: false)
    }

    // MARK: - Keychain Operations

    private func loadFromKeychain(service: String, useDataProtection: Bool) throws -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw LLMAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func saveToKeychain(_ key: String, service: String) throws {
        guard let encoded = key.data(using: .utf8) else {
            throw LLMAPIKeyStoreError.invalidEncoding
        }

        // Delete existing first
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain: true,
            kSecValueData: encoded,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LLMAPIKeyStoreError.keychainFailure(status)
        }
    }

    private func deleteFromKeychain(service: String, useDataProtection: Bool) throws {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LLMAPIKeyStoreError.keychainFailure(status)
        }
    }
}

// MARK: - Default Key Provider

/// Bridges `LLMAPIKeyStoring` → `LLMAPIKeyProviding` for use by provider implementations.
struct DefaultLLMAPIKeyProvider: LLMAPIKeyProviding {
    private let store: any LLMAPIKeyStoring

    init(store: any LLMAPIKeyStoring) {
        self.store = store
    }

    func apiKey(for provider: LLMProviderID) async -> String? {
        do {
            return try await store.loadAPIKey(for: provider)
        } catch {
            return nil
        }
    }
}

// MARK: - Backward Compatibility Bridge

/// Bridges the new LLMAPIKeyStore to the old OpenAIAPIKeyProviding protocol.
/// Use this during migration so existing OpenAIResponsesService keeps working.
struct LLMToOpenAIKeyProviderBridge: OpenAIAPIKeyProviding {
    private let keyProvider: any LLMAPIKeyProviding

    init(keyProvider: any LLMAPIKeyProviding) {
        self.keyProvider = keyProvider
    }

    func currentAPIKey() async -> String? {
        await keyProvider.apiKey(for: .openai)
    }
}
