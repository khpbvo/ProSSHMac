import Foundation

/// `output_config.effort`: how much a model thinks per response, and so its latency and cost.
enum AnthropicEffort: String, CaseIterable, Codable, Sendable, Comparable {
    case low, medium, high, xhigh, max

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One `/v1/models` entry. Encodes with the API's own keys, so the selection cache round-trips.
struct AnthropicModel: Codable, Identifiable, Equatable, Sendable {
    struct Support: Codable, Equatable, Sendable {
        var supported: Bool
    }

    struct Capabilities: Codable, Equatable, Sendable {
        struct Thinking: Codable, Equatable, Sendable {
            struct Types: Codable, Equatable, Sendable {
                var adaptive: Support?
            }
            var supported: Bool?
            var types: Types?
        }

        struct Effort: Codable, Equatable, Sendable {
            var supported: Bool?
            var low: Support?
            var medium: Support?
            var high: Support?
            var xhigh: Support?
            var max: Support?
        }

        var thinking: Thinking?
        var effort: Effort?
    }

    let id: String
    let displayName: String
    let createdAt: String?
    let maxInputTokens: Int?
    let maxTokens: Int?
    let allowedFallbackModels: [String]?
    let capabilities: Capabilities?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case id, capabilities, type
        case displayName = "display_name"
        case createdAt = "created_at"
        case maxInputTokens = "max_input_tokens"
        case maxTokens = "max_tokens"
        case allowedFallbackModels = "allowed_fallback_models"
    }

    init(
        id: String,
        displayName: String,
        createdAt: String? = nil,
        maxInputTokens: Int? = nil,
        maxTokens: Int? = nil,
        allowedFallbackModels: [String]? = nil,
        capabilities: Capabilities? = nil,
        type: String? = "model"
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.maxInputTokens = maxInputTokens
        self.maxTokens = maxTokens
        self.allowedFallbackModels = allowedFallbackModels
        self.capabilities = capabilities
        self.type = type
    }

    var supportsAdaptiveThinking: Bool {
        capabilities?.thinking?.types?.adaptive?.supported == true
    }

    /// Effort levels the model accepts, lowest first. Empty when it takes no `effort`.
    var supportedEffortLevels: [AnthropicEffort] {
        guard let effort = capabilities?.effort, effort.supported == true else { return [] }
        let levels: [(AnthropicEffort, Support?)] = [
            (.low, effort.low), (.medium, effort.medium), (.high, effort.high),
            (.xhigh, effort.xhigh), (.max, effort.max),
        ]
        return levels.filter { $0.1?.supported == true }.map(\.0)
    }

    /// Whether the request may carry `fallbacks` (an empty list means it may not).
    var supportsServerFallback: Bool {
        !(allowedFallbackModels ?? []).isEmpty
    }
}

struct AnthropicModelsPage: Decodable, Sendable {
    let data: [AnthropicModel]
    let hasMore: Bool
    let lastID: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}

enum AnthropicError: LocalizedError, Equatable {
    case missingAPIKey
    case modelNotSelected
    case modelUnavailable(String)
    case invalidResponse
    case httpError(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an Anthropic API key in Settings → AI Assistant."
        case .modelNotSelected: return "Choose a Claude model in Settings → AI Assistant."
        case let .modelUnavailable(model): return "The selected Claude model is no longer available: \(model). Choose another model."
        case .invalidResponse: return "Anthropic returned an invalid response."
        case let .httpError(code, message): return "Anthropic request failed (\(code)): \(message)"
        case let .transport(message): return "Anthropic connection failed: \(message)"
        }
    }
}
