import Foundation
import Combine

@MainActor
final class OpenRouterModelStore: ObservableObject {
    @Published private(set) var selectedModelID: String?
    @Published private(set) var models: [OpenRouterModel] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var catalogError: String?
    @Published private(set) var selectedModelUnavailable = false

    private let client: any OpenRouterServicing
    private let defaults: UserDefaults
    private let selectionKey = "ai.openrouter.model"
    private let selectedModelCacheKey = "ai.openrouter.selectedModelMetadata"
    private let unavailableKey = "ai.openrouter.selectedModelUnavailable"
    private var cachedSelectedModel: OpenRouterModel?

    init(client: any OpenRouterServicing, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.selectedModelID = defaults.string(forKey: selectionKey)
        self.selectedModelUnavailable = defaults.bool(forKey: unavailableKey)
        if let data = defaults.data(forKey: selectedModelCacheKey),
           let cached = try? JSONDecoder().decode(OpenRouterModel.self, from: data),
           cached.id == selectedModelID {
            self.cachedSelectedModel = cached
        }
    }

    var selectedModel: OpenRouterModel? {
        models.first { $0.id == selectedModelID } ?? cachedSelectedModel
    }

    func select(_ modelID: String) throws {
        guard let model = models.first(where: { $0.id == modelID }) else {
            throw OpenRouterError.modelUnavailable(modelID)
        }
        selectedModelID = modelID
        cachedSelectedModel = model
        selectedModelUnavailable = false
        defaults.set(modelID, forKey: selectionKey)
        defaults.set(false, forKey: unavailableKey)
        defaults.set(try? JSONEncoder().encode(model), forKey: selectedModelCacheKey)
    }

    func requireSelection() throws -> String {
        guard let selectedModelID, !selectedModelID.isEmpty else {
            throw OpenRouterError.modelNotSelected
        }
        guard !selectedModelUnavailable else {
            throw OpenRouterError.modelUnavailable(selectedModelID)
        }
        return selectedModelID
    }

    func contextLength(for modelID: String) -> Int {
        models.first(where: { $0.id == modelID })?.contextLength
            ?? (cachedSelectedModel?.id == modelID ? cachedSelectedModel?.contextLength : nil)
            ?? 32_768
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await client.fetchModels()
            models = fresh
            catalogError = nil
            if let selectedModelID {
                selectedModelUnavailable = !fresh.contains { $0.id == selectedModelID }
                defaults.set(selectedModelUnavailable, forKey: unavailableKey)
                if let selected = fresh.first(where: { $0.id == selectedModelID }) {
                    cachedSelectedModel = selected
                    defaults.set(try? JSONEncoder().encode(selected), forKey: selectedModelCacheKey)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // A transient catalog outage does not invalidate a previously chosen model.
            catalogError = error.localizedDescription
        }
    }
}
