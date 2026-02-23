import Foundation
import Combine

@MainActor
final class OpenAISettingsViewModel: ObservableObject {
    @Published var apiKeyInput = ""
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var storedKeyHint: String?
    @Published private(set) var statusMessage: String?

    private let apiKeyStore: any OpenAIAPIKeyStoring

    init(apiKeyStore: any OpenAIAPIKeyStoring) {
        self.apiKeyStore = apiKeyStore
    }

    func refresh() async {
        do {
            let key = try await apiKeyStore.loadAPIKey()
            applyStoredKeyState(key)
            statusMessage = nil
        } catch {
            hasStoredAPIKey = false
            storedKeyHint = nil
            statusMessage = error.localizedDescription
        }
    }

    func saveAPIKey() async {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Enter an API key before saving."
            return
        }

        do {
            try await apiKeyStore.saveAPIKey(trimmed)
            applyStoredKeyState(trimmed)
            apiKeyInput = ""
            statusMessage = "OpenAI API key saved securely."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeAPIKey() async {
        do {
            try await apiKeyStore.deleteAPIKey()
            hasStoredAPIKey = false
            storedKeyHint = nil
            apiKeyInput = ""
            statusMessage = "OpenAI API key removed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func applyStoredKeyState(_ key: String?) {
        guard let key, !key.isEmpty else {
            hasStoredAPIKey = false
            storedKeyHint = nil
            return
        }

        hasStoredAPIKey = true
        storedKeyHint = Self.maskedKeyHint(for: key)
    }

    private static func maskedKeyHint(for key: String) -> String {
        let suffix = String(key.suffix(4))
        if suffix.isEmpty {
            return "••••"
        }
        return "••••\(suffix)"
    }
}
