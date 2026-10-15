import Foundation

protocol LegacyProviderKeyDeleting: Sendable {
    func deleteLegacyProviderKeys() async throws
}

actor KeychainOpenRouterAPIKeyStore: AIAPIKeyStoring, LegacyProviderKeyDeleting {
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
        try KeychainGenericPassword.load(service: Self.service, account: account)
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenRouterError.missingAPIKey }
        try KeychainGenericPassword.save(trimmed, service: Self.service, account: account)
    }

    func deleteAPIKey() throws {
        try KeychainGenericPassword.delete(service: Self.service, account: account)
    }

    func deleteLegacyProviderKeys() throws {
        for service in Self.legacyServices {
            try KeychainGenericPassword.delete(service: service, account: account)
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
