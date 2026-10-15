import Foundation

@MainActor
final class OpenRouterSettingsViewModel: AIKeySettingsViewModel {
    let modelStore: OpenRouterModelStore

    init(modelStore: OpenRouterModelStore, keyStore: any AIAPIKeyStoring) {
        self.modelStore = modelStore
        super.init(providerName: "OpenRouter", keyStore: keyStore) { await modelStore.refresh() }
    }
}
