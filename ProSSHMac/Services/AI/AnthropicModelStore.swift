import Foundation
import Combine

@MainActor
final class AnthropicModelStore: ObservableObject {
    /// Used until the user picks a model; not persisted, so a later default can replace it.
    nonisolated static let defaultModelID = "claude-opus-5-5"
    /// Every current Claude model has at least this context window.
    nonisolated static let fallbackContextLength = 200_000
    nonisolated static let fallbackMaxOutputTokens = 64_000

    @Published private(set) var selectedModelID: String
    @Published private(set) var models: [AnthropicModel] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var catalogError: String?
    @Published private(set) var selectedModelUnavailable = false
    @Published private(set) var effort: AnthropicEffort

    private let client: any AnthropicServicing
    private let defaults: UserDefaults
    private let selectionKey = "ai.anthropic.model"
    private let selectedModelCacheKey = "ai.anthropic.selectedModelMetadata"
    private let unavailableKey = "ai.anthropic.selectedModelUnavailable"
    private let effortKey = "ai.anthropic.effort"
    private var cachedSelectedModel: AnthropicModel?

    init(client: any AnthropicServicing, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        let selected = defaults.string(forKey: selectionKey) ?? Self.defaultModelID
        self.selectedModelID = selected
        self.selectedModelUnavailable = defaults.bool(forKey: unavailableKey)
        self.effort = defaults.string(forKey: effortKey).flatMap(AnthropicEffort.init(rawValue:)) ?? .medium
        if let data = defaults.data(forKey: selectedModelCacheKey),
           let cached = try? JSONDecoder().decode(AnthropicModel.self, from: data),
           cached.id == selected {
            self.cachedSelectedModel = cached
        }
    }

    var selectedModel: AnthropicModel? {
        metadata(for: selectedModelID)
    }

    func select(_ modelID: String) throws {
        guard let model = models.first(where: { $0.id == modelID }) else {
            throw AnthropicError.modelUnavailable(modelID)
        }
        selectedModelID = modelID
        cachedSelectedModel = model
        selectedModelUnavailable = false
        defaults.set(modelID, forKey: selectionKey)
        defaults.set(false, forKey: unavailableKey)
        defaults.set(try? JSONEncoder().encode(model), forKey: selectedModelCacheKey)
    }

    func requireSelection() throws -> String {
        guard !selectedModelUnavailable else {
            throw AnthropicError.modelUnavailable(selectedModelID)
        }
        return selectedModelID
    }

    func setEffort(_ effort: AnthropicEffort) {
        self.effort = effort
        defaults.set(effort.rawValue, forKey: effortKey)
    }

    /// The `effort` to send for `modelID`: nil when the model takes none, otherwise the setting
    /// lowered to the highest level the model supports. Unknown models get the setting as is.
    func effort(for modelID: String) -> AnthropicEffort? {
        guard let model = metadata(for: modelID) else { return effort }
        let supported = model.supportedEffortLevels
        guard !supported.isEmpty else { return nil }
        return supported.last { $0 <= effort } ?? supported.first
    }

    func contextLength(for modelID: String) -> Int {
        metadata(for: modelID)?.maxInputTokens ?? Self.fallbackContextLength
    }

    func maxOutputTokens(for modelID: String) -> Int {
        metadata(for: modelID)?.maxTokens ?? Self.fallbackMaxOutputTokens
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await client.fetchModels()
            models = fresh
            catalogError = nil
            selectedModelUnavailable = !fresh.contains { $0.id == selectedModelID }
            defaults.set(selectedModelUnavailable, forKey: unavailableKey)
            if let selected = fresh.first(where: { $0.id == selectedModelID }) {
                cachedSelectedModel = selected
                defaults.set(try? JSONEncoder().encode(selected), forKey: selectedModelCacheKey)
            }
        } catch is CancellationError {
            return
        } catch {
            // A transient catalog outage does not invalidate a previously chosen model.
            catalogError = error.localizedDescription
        }
    }

    /// The catalog entry for `modelID`, or the cached one for the selection.
    func metadata(for modelID: String) -> AnthropicModel? {
        models.first { $0.id == modelID }
            ?? (cachedSelectedModel?.id == modelID ? cachedSelectedModel : nil)
    }
}
