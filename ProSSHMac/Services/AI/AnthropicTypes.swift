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

// MARK: - Messages wire types

/// One content block exactly as it is sent. Blocks are kept as JSON text, never re-encoded from
/// a dictionary, so a replayed turn is byte-identical on every request: thinking signatures bind
/// the conversation prefix.
nonisolated struct AnthropicBlock: Equatable, Sendable {
    let json: String

    static func text(_ text: String) -> Self {
        Self(json: AnthropicJSON.object([("text", AnthropicJSON.string(text)), ("type", #""text""#)]))
    }

    /// The block's `type` field.
    var type: String? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["type"] as? String
    }

    var isThinking: Bool {
        type == "thinking" || type == "redacted_thinking"
    }

    static func toolResult(toolUseID: String, content: String, isError: Bool = false) -> Self {
        var fields = [("content", AnthropicJSON.string(content))]
        if isError { fields.append(("is_error", "true")) }
        fields += [("tool_use_id", AnthropicJSON.string(toolUseID)), ("type", #""tool_result""#)]
        return Self(json: AnthropicJSON.object(fields))
    }
}

struct AnthropicMessage: Equatable, Sendable {
    var role: String
    var content: [AnthropicBlock]
}

struct AnthropicRequest: Sendable {
    var model: String
    var maxTokens: Int
    var system: String
    var messages: [AnthropicMessage]
    var tools: [LLMToolDefinition]
    /// Sends `thinking: {type: "adaptive", display: "summarized"}` with `drop_block` binding.
    var adaptiveThinking: Bool
    var effort: AnthropicEffort?
    /// Sends `fallbacks: "default"` so a safety refusal is retried on another model.
    var serverFallback: Bool
}

struct AnthropicUsage: Codable, Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    /// Later events report running totals; keep each field's latest value.
    mutating func merge(_ other: AnthropicUsage) {
        inputTokens = other.inputTokens ?? inputTokens
        outputTokens = other.outputTokens ?? outputTokens
        cacheCreationInputTokens = other.cacheCreationInputTokens ?? cacheCreationInputTokens
        cacheReadInputTokens = other.cacheReadInputTokens ?? cacheReadInputTokens
    }
}

struct AnthropicResponse: Equatable, Sendable {
    var id: String
    var model: String
    /// The assistant turn to send back next time, with the fallback echo rule applied.
    var content: [AnthropicBlock]
    var text: String
    var reasoning: String
    var toolCalls: [LLMToolCall]
    var stopReason: String
    var usage: AnthropicUsage?
    /// Thinking blocks the API dropped or let through despite a binding mismatch.
    var inputTransformations: [LLMJSONValue]
}

/// Builds JSON text in a fixed key order. Values passed in are already-encoded JSON.
nonisolated enum AnthropicJSON {
    static func string(_ value: String) -> String {
        encode(value) ?? "\"\""
    }

    static func object(_ fields: [(String, String)]) -> String {
        "{" + fields.map { "\(string($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    static func array(_ elements: [String]) -> String {
        "[" + elements.joined(separator: ",") + "]"
    }

    /// Encodes with sorted keys, so the same value always yields the same text.
    static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum AnthropicError: LocalizedError, Equatable {
    case missingAPIKey
    case modelNotSelected
    case modelUnavailable(String)
    case invalidResponse
    case incompleteResponse
    case invalidToolCall
    case refused(category: String?, explanation: String?)
    case httpError(Int, String)
    case streamError(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an Anthropic API key in Settings → AI Assistant."
        case .modelNotSelected: return "Choose a Claude model in Settings → AI Assistant."
        case let .modelUnavailable(model): return "The selected Claude model is no longer available: \(model). Choose another model."
        case .invalidResponse: return "Anthropic returned an invalid response."
        case .incompleteResponse: return "Claude stopped before finishing the response (output or context limit reached)."
        case .invalidToolCall: return "Claude returned an incomplete tool call; no tool was run."
        case let .refused(category, explanation):
            var message = "Claude declined this request"
            if let category { message += " (\(category))" }
            message += "."
            if let explanation, !explanation.isEmpty { message += " \(explanation)" }
            return message
        case let .httpError(code, message): return "Anthropic request failed (\(code)): \(message)"
        case let .streamError(message): return "Anthropic stream failed: \(message)"
        case let .transport(message): return "Anthropic connection failed: \(message)"
        }
    }
}
