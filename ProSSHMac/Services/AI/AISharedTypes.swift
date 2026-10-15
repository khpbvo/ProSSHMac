import Foundation

// Shared AI tool, streaming and transcript types. Each provider's wire messages and model
// metadata live in its own file (OpenRouterTypes.swift); the agent loop and the per-session
// transcript use only the types here.

struct LLMToolDefinition: Sendable, Equatable {
    var name: String
    var description: String
    var parameters: LLMJSONValue
    var strict: Bool?
}

struct LLMToolCall: Sendable, Equatable {
    var id: String
    var name: String
    var arguments: String
}

struct LLMToolOutput: Sendable, Equatable {
    var callID: String
    var output: String
}

enum LLMStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case textDone(String)
    case reasoningDelta(String)
    case reasoningDone(String)
    case reasoningSummaryDelta(String)
    case reasoningSummaryDone(String)
}

// MARK: - Transcript

/// One entry of a session's conversation, independent of any provider's wire format.
enum AITranscriptMessage: Sendable, Equatable {
    case user(String)
    case assistant(AIAssistantTurn)
    case toolResult(LLMToolOutput)
}

struct AIAssistantTurn: Sendable, Equatable {
    var text: String?
    var toolCalls: [LLMToolCall] = []
    var reasoning: AIProviderReasoning?
}

/// Reasoning a provider needs replayed verbatim on its own next request. Each case belongs to
/// one provider.
enum AIProviderReasoning: Sendable, Equatable {
    case openRouter(details: [LLMJSONValue]?, text: String?)
}

/// One provider's chat completion endpoint, seen by the agent loop.
@MainActor
protocol AIChatProviding: Sendable {
    /// Request size in UTF-8 bytes, used to fit history into the context budget.
    func estimatedRequestBytes(
        systemPrompt: String,
        messages: [AITranscriptMessage],
        tools: [LLMToolDefinition]
    ) -> Int

    /// Streams one assistant response. Throws on any stop that leaves the turn unusable
    /// (truncation, refusal, malformed tool calls), so a returned turn is always complete.
    func complete(
        model: String,
        systemPrompt: String,
        messages: [AITranscriptMessage],
        tools: [LLMToolDefinition],
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> AIAssistantTurn
}

// MARK: - JSON Value

/// Generic JSON value type for tool parameter schemas and reasoning blocks.
enum LLMJSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LLMJSONValue])
    case array([LLMJSONValue])
    case null
}

extension LLMJSONValue: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([String: LLMJSONValue].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([LLMJSONValue].self) {
            self = .array(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value."
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value):   try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value):  try container.encode(value)
        case .null:              try container.encodeNil()
        }
    }
}
