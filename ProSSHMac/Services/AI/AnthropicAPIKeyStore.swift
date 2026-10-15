import Foundation

actor KeychainAnthropicAPIKeyStore: AIAPIKeyStoring {
    /// Not `nl.budgetsoft.ProSSHMac.llm.anthropic`: that is a legacy service which
    /// `LegacyProviderKeyCleanup` deletes.
    nonisolated static let service = "nl.budgetsoft.ProSSHMac.anthropic"
    private let account = "api-key"

    func loadAPIKey() throws -> String? {
        try KeychainGenericPassword.load(service: Self.service, account: account)
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AnthropicError.missingAPIKey }
        try KeychainGenericPassword.save(trimmed, service: Self.service, account: account)
    }

    func deleteAPIKey() throws {
        try KeychainGenericPassword.delete(service: Self.service, account: account)
    }
}
