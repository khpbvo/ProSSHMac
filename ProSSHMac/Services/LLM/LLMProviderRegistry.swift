// LLMProviderRegistry.swift
// ProSSHMac
//
// Runtime provider selection and management.
// Persists active provider/model choice in UserDefaults.

import Foundation
import Combine

@MainActor
final class LLMProviderRegistry: ObservableObject {

    // MARK: - Published State

    @Published private(set) var activeProviderID: LLMProviderID
    @Published private(set) var activeModelID: String

    // MARK: - Storage

    private var providers: [LLMProviderID: any LLMProvider] = [:]

    private static let providerDefaultsKey = "ai.provider.active"
    private static let modelDefaultsKey = "ai.model.active"

    // MARK: - Init

    init(
        defaultProvider: LLMProviderID = .openai,
        defaultModel: String = "gpt-5.1-codex-max"
    ) {
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerDefaultsKey)
            .flatMap(LLMProviderID.init(rawValue:))
        let storedModel = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)

        self.activeProviderID = storedProvider ?? defaultProvider
        self.activeModelID = storedModel ?? defaultModel
    }

    // MARK: - Registration

    func register(_ provider: any LLMProvider) {
        providers[provider.providerID] = provider
    }

    // MARK: - Access

    /// The currently active provider, if registered.
    var activeProvider: (any LLMProvider)? {
        providers[activeProviderID]
    }

    /// Look up a specific provider by ID.
    func provider(for id: LLMProviderID) -> (any LLMProvider)? {
        providers[id]
    }

    /// All registered providers.
    var allProviders: [any LLMProvider] {
        LLMProviderID.allCases.compactMap { providers[$0] }
    }

    /// Only providers that are ready to use (have API keys, etc.).
    var configuredProviders: [any LLMProvider] {
        allProviders.filter { $0.isConfigured }
    }

    // MARK: - Selection

    /// Switch the active provider and model. Persists to UserDefaults.
    func setActiveProvider(_ providerID: LLMProviderID, model: String) {
        activeProviderID = providerID
        activeModelID = model
        UserDefaults.standard.set(providerID.rawValue, forKey: Self.providerDefaultsKey)
        UserDefaults.standard.set(model, forKey: Self.modelDefaultsKey)
    }

    /// Switch only the model within the current provider.
    func setActiveModel(_ model: String) {
        activeModelID = model
        UserDefaults.standard.set(model, forKey: Self.modelDefaultsKey)
    }

    /// Validate that the current selection is still valid.
    /// Call this after registration or when a provider's configuration changes.
    func validateSelection() {
        guard let provider = activeProvider else {
            // Active provider not registered — fall back to first configured provider
            if let fallback = configuredProviders.first {
                let model = fallback.availableModels.first?.id ?? ""
                setActiveProvider(fallback.providerID, model: model)
            }
            return
        }

        // Check if the selected model is still available
        let modelStillValid = provider.availableModels.contains { $0.id == activeModelID }
        if !modelStillValid, let firstModel = provider.availableModels.first {
            setActiveModel(firstModel.id)
        }
    }
}
