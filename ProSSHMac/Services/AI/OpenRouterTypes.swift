import Foundation

struct OpenRouterModel: Codable, Identifiable, Equatable, Sendable {
    struct Architecture: Codable, Equatable, Sendable {
        let inputModalities: [String]
        let outputModalities: [String]

        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
        }
    }

    struct Pricing: Codable, Equatable, Sendable {
        let prompt: String?
        let completion: String?
    }

    let id: String
    let name: String
    let contextLength: Int?
    let supportedParameters: [String]
    let architecture: Architecture?
    let pricing: Pricing?

    enum CodingKeys: String, CodingKey {
        case id, name, architecture, pricing
        case contextLength = "context_length"
        case supportedParameters = "supported_parameters"
    }

    var isUsableForAssistant: Bool {
        supportedParameters.contains("tools")
            && architecture?.inputModalities.contains("text") == true
            && architecture?.outputModalities.contains("text") == true
    }

    var promptPricePerMillion: Decimal? {
        pricing?.prompt.flatMap { Decimal(string: $0) }.map { $0 * 1_000_000 }
    }

    var completionPricePerMillion: Decimal? {
        pricing?.completion.flatMap { Decimal(string: $0) }.map { $0 * 1_000_000 }
    }
}

struct OpenRouterCatalogResponse: Decodable, Sendable {
    let data: [OpenRouterModel]
}

struct OpenRouterToolCall: Codable, Equatable, Sendable {
    struct Function: Codable, Equatable, Sendable {
        var name: String
        var arguments: String
    }

    var id: String
    var type: String = "function"
    var function: Function
}

struct OpenRouterMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String?
    var toolCalls: [OpenRouterToolCall]? = nil
    var toolCallID: String? = nil
    var reasoningDetails: [LLMJSONValue]? = nil
    var reasoning: String? = nil

    enum CodingKeys: String, CodingKey {
        case role, content, reasoning
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningDetails = "reasoning_details"
    }

    static func system(_ text: String) -> Self { .init(role: "system", content: text) }
    static func user(_ text: String) -> Self { .init(role: "user", content: text) }
    static func tool(_ output: String, callID: String) -> Self {
        .init(role: "tool", content: output, toolCallID: callID)
    }

    func removingReasoning() -> Self {
        var result = self
        result.reasoningDetails = nil
        result.reasoning = nil
        return result
    }
}

struct OpenRouterCompletion: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        let message: OpenRouterMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable, Sendable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let cost: Double?

        enum CodingKeys: String, CodingKey {
            case cost
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    let id: String
    let model: String?
    let choices: [Choice]
    let usage: Usage?
}

enum OpenRouterError: LocalizedError, Equatable {
    case missingAPIKey
    case modelNotSelected
    case modelUnavailable(String)
    case invalidResponse
    case incompleteResponse
    case invalidToolCall
    case contextTooLarge
    case httpError(Int, String)
    case streamError(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an OpenRouter API key in Settings → AI Assistant."
        case .modelNotSelected: return "Choose an OpenRouter model in Settings → AI Assistant."
        case let .modelUnavailable(model): return "The selected OpenRouter model is no longer available: \(model). Choose another model."
        case .invalidResponse: return "OpenRouter returned an invalid response."
        case .incompleteResponse: return "OpenRouter stopped before finishing the response."
        case .invalidToolCall: return "OpenRouter returned an incomplete tool call; no tool was run."
        case .contextTooLarge: return "This request is too large for the selected model's context window."
        case let .httpError(code, message): return "OpenRouter request failed (\(code)): \(message)"
        case let .streamError(message): return "OpenRouter stream failed: \(message)"
        case let .transport(message): return "OpenRouter connection failed: \(message)"
        }
    }
}
