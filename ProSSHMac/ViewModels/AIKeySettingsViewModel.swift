import Foundation
import Combine

/// API key entry for one AI provider in Settings. Each provider subclasses it, because SwiftUI
/// environment objects are looked up by type.
@MainActor
class AIKeySettingsViewModel: ObservableObject {
    @Published var apiKeyInput = ""
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var storedKeyHint: String?
    @Published private(set) var statusMessage: String?

    let providerName: String
    private let keyStore: any AIAPIKeyStoring
    private let refreshCatalog: @MainActor () async -> Void

    init(providerName: String, keyStore: any AIAPIKeyStoring, refreshCatalog: @escaping @MainActor () async -> Void) {
        self.providerName = providerName
        self.keyStore = keyStore
        self.refreshCatalog = refreshCatalog
    }

    func refresh() async {
        do {
            let key = try await keyStore.loadAPIKey()
            applyStoredKeyState(key)
            statusMessage = nil
            if hasStoredAPIKey { await refreshCatalog() }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveAPIKey() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusMessage = "Enter an \(providerName) API key before saving."
            return
        }
        do {
            try await keyStore.saveAPIKey(key)
            applyStoredKeyState(key)
            apiKeyInput = ""
            statusMessage = "\(providerName) API key saved securely."
            await refreshCatalog()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeAPIKey() async {
        do {
            try await keyStore.deleteAPIKey()
            applyStoredKeyState(nil)
            apiKeyInput = ""
            statusMessage = "\(providerName) API key removed."
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
