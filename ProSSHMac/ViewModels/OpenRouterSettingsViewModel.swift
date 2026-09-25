import Foundation
import Combine

@MainActor
final class OpenRouterSettingsViewModel: ObservableObject {
    @Published var apiKeyInput = ""
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var storedKeyHint: String?
    @Published private(set) var statusMessage: String?

    let modelStore: OpenRouterModelStore
    private let keyStore: any OpenRouterAPIKeyStoring

    init(modelStore: OpenRouterModelStore, keyStore: any OpenRouterAPIKeyStoring) {
        self.modelStore = modelStore
        self.keyStore = keyStore
    }

    func refresh() async {
        do {
            let key = try await keyStore.loadAPIKey()
            applyStoredKeyState(key)
            statusMessage = nil
            if hasStoredAPIKey { await modelStore.refresh() }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveAPIKey() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusMessage = "Enter an OpenRouter API key before saving."
            return
        }
        do {
            try await keyStore.saveAPIKey(key)
            applyStoredKeyState(key)
            apiKeyInput = ""
            statusMessage = "OpenRouter API key saved securely."
            await modelStore.refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeAPIKey() async {
        do {
            try await keyStore.deleteAPIKey()
            applyStoredKeyState(nil)
            apiKeyInput = ""
            statusMessage = "OpenRouter API key removed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func pasteFromClipboard() {
        if let pasted = PlatformClipboard.readString() {
            apiKeyInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func applyStoredKeyState(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hasStoredAPIKey = !trimmed.isEmpty
        storedKeyHint = hasStoredAPIKey ? "••••\(trimmed.suffix(4))" : nil
    }
}
