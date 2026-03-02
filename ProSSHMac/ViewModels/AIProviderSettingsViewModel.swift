// AIProviderSettingsViewModel.swift
// ProSSHMac
//
// Settings ViewModel for multi-provider AI configuration.
// Replaces OpenAISettingsViewModel with provider/model selection and per-provider API key management.

import Foundation
import Combine

@MainActor
final class AIProviderSettingsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var selectedProviderID: LLMProviderID
    @Published var selectedModelID: String
    @Published var apiKeyInput = ""
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var storedKeyHint: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isRefreshingModels = false
    @Published private(set) var ollamaConnectionStatus: OllamaConnectionStatus = .unknown

    enum OllamaConnectionStatus {
        case unknown
        case connected(modelCount: Int)
        case notRunning
    }

    // MARK: - Dependencies

    private let registry: LLMProviderRegistry
    private let apiKeyStore: KeychainLLMAPIKeyStore
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed

    /// All provider IDs that can be selected (OpenAI is always available even without LLMProvider conformer).
    var availableProviders: [LLMProviderID] {
        var ids: [LLMProviderID] = [.openai]
        for provider in registry.allProviders where provider.providerID != .openai {
            ids.append(provider.providerID)
        }
        return ids
    }

    /// Models for the currently selected provider.
    var modelsForSelectedProvider: [LLMModelInfo] {
        if selectedProviderID == .openai {
            return Self.openAIModels
        }
        return registry.provider(for: selectedProviderID)?.availableModels ?? []
    }

    /// Whether the selected provider requires an API key.
    var requiresAPIKey: Bool {
        selectedProviderID.requiresAPIKey
    }

    // MARK: - Init

    init(registry: LLMProviderRegistry, apiKeyStore: KeychainLLMAPIKeyStore) {
        self.registry = registry
        self.apiKeyStore = apiKeyStore
        self.selectedProviderID = registry.activeProviderID
        self.selectedModelID = registry.activeModelID

        // Sync selection changes back to registry
        $selectedProviderID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newProvider in
                guard let self else { return }
                let firstModel = self.modelsForProvider(newProvider).first?.id ?? ""
                self.selectedModelID = firstModel
                self.registry.setActiveProvider(newProvider, model: firstModel)
                self.apiKeyInput = ""
                self.statusMessage = nil
                Task {
                    await self.refreshKeyStatus()
                    if newProvider == .ollama {
                        await self.refreshOllamaModels()
                    }
                }
            }
            .store(in: &cancellables)

        $selectedModelID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newModel in
                self?.registry.setActiveModel(newModel)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods

    func refresh() async {
        await refreshKeyStatus()
        if selectedProviderID == .ollama {
            await refreshOllamaModels()
        }
    }

    func saveAPIKey() async {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Enter an API key before saving."
            return
        }

        do {
            try await apiKeyStore.saveAPIKey(trimmed, for: selectedProviderID)
            applyStoredKeyState(trimmed)
            apiKeyInput = ""
            statusMessage = "\(selectedProviderID.displayName) API key saved securely."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeAPIKey() async {
        do {
            try await apiKeyStore.deleteAPIKey(for: selectedProviderID)
            hasStoredAPIKey = false
            storedKeyHint = nil
            apiKeyInput = ""
            statusMessage = "\(selectedProviderID.displayName) API key removed."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func pasteFromClipboard() {
        if let pasted = PlatformClipboard.readString() {
            apiKeyInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func refreshOllamaModels() async {
        guard let ollama = registry.provider(for: .ollama) as? OllamaProvider else { return }
        isRefreshingModels = true
        await ollama.refreshModels()
        let models = ollama.availableModels
        if ollama.dynamicModels.isEmpty {
            ollamaConnectionStatus = .notRunning
        } else {
            ollamaConnectionStatus = .connected(modelCount: ollama.dynamicModels.count)
        }
        if !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = models.first?.id ?? ""
        }
        isRefreshingModels = false
    }

    // MARK: - Private

    private func refreshKeyStatus() async {
        guard selectedProviderID.requiresAPIKey else {
            hasStoredAPIKey = false
            storedKeyHint = nil
            return
        }

        do {
            let key = try await apiKeyStore.loadAPIKey(for: selectedProviderID)
            applyStoredKeyState(key)
            statusMessage = nil
        } catch {
            hasStoredAPIKey = false
            storedKeyHint = nil
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

    private func modelsForProvider(_ providerID: LLMProviderID) -> [LLMModelInfo] {
        if providerID == .openai {
            return Self.openAIModels
        }
        return registry.provider(for: providerID)?.availableModels ?? []
    }

    private static func maskedKeyHint(for key: String) -> String {
        let suffix = String(key.suffix(4))
        return suffix.isEmpty ? "••••" : "••••\(suffix)"
    }

    // MARK: - OpenAI Models (hardcoded — no LLMProvider conformer yet)

    private static let openAIModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "gpt-5.1-codex-max",
            displayName: "GPT-5.1 Codex Max",
            providerID: .openai,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: true
        ),
        LLMModelInfo(
            id: "o3",
            displayName: "o3",
            providerID: .openai,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: true
        ),
        LLMModelInfo(
            id: "o4-mini",
            displayName: "o4-mini",
            providerID: .openai,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: true
        ),
        LLMModelInfo(
            id: "gpt-4.1",
            displayName: "GPT-4.1",
            providerID: .openai,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: false
        ),
    ]
}
