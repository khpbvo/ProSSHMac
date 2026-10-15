import Foundation

@MainActor
final class AnthropicSettingsViewModel: AIKeySettingsViewModel {
    let modelStore: AnthropicModelStore

    init(modelStore: AnthropicModelStore, keyStore: any AIAPIKeyStoring) {
        self.modelStore = modelStore
        super.init(providerName: "Anthropic", keyStore: keyStore) { await modelStore.refresh() }
    }
}
