import Foundation
import Combine

enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case openRouter
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .anthropic: return "Anthropic"
        }
    }
}

/// Which provider the AI assistant uses. OpenRouter until the user picks another.
@MainActor
final class AIProviderSelection: ObservableObject {
    /// Not `ai.provider.active`: that legacy key is removed by `LegacyProviderKeyCleanup`.
    nonisolated static let defaultsKey = "ai.provider.selected"

    @Published private(set) var provider: AIProvider
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.provider = defaults.string(forKey: Self.defaultsKey).flatMap(AIProvider.init(rawValue:)) ?? .openRouter
    }

    func select(_ provider: AIProvider) {
        // Pickers can write the current value back while SwiftUI updates the view; publishing
        // then is not allowed, so an unchanged value must not publish.
        guard provider != self.provider else { return }
        self.provider = provider
        defaults.set(provider.rawValue, forKey: Self.defaultsKey)
    }
}
