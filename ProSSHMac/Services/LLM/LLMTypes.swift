// LLMTypes.swift
// ProSSHMac
//
// Provider-agnostic types for multi-LLM support.
// Every provider translates to/from these internally.

import Foundation

// MARK: - Provider Identity

/// All supported LLM providers.
enum LLMProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case openai
    case mistral
    case anthropic
    case ollama
    case deepseek

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .openai:    return "OpenAI"
        case .mistral:   return "Mistral AI"
        case .anthropic: return "Anthropic"
        case .ollama:    return "Ollama (Local)"
        case .deepseek:  return "DeepSeek"
        }
    }

    /// Whether this provider requires an API key.
    nonisolated var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        default:      return true
        }
    }
}

// MARK: - Model Info

struct LLMModelInfo: Sendable, Equatable, Codable, Identifiable {
    /// Wire-format model identifier, e.g. "gpt-5.1-codex-max", "mistral-large-latest"
    var id: String
    /// Human-friendly name, e.g. "GPT-5.1 Codex Max"
    var displayName: String
    var providerID: LLMProviderID
    var supportsFunctionCalling: Bool
    var supportsStreaming: Bool
    /// Extended thinking / chain-of-thought reasoning (OpenAI o-series, Claude extended thinking)
    var supportsReasoning: Bool
}

// MARK: - Messages

enum LLMMessageRole: String, Sendable, Equatable, Codable {
    case system
    /// OpenAI "developer" role — maps to system for all other providers.
    case developer
    case user
    case assistant
}

struct LLMMessage: Sendable, Equatable {
    var role: LLMMessageRole
    var content: String
}

// MARK: - Tool Definitions

/// Provider-agnostic function tool definition using JSON Schema.
struct LLMToolDefinition: Sendable, Equatable {
    var name: String
    var description: String
    /// JSON Schema describing the function parameters.
    var parameters: LLMJSONValue
    /// OpenAI strict mode. Ignored by providers that don't support it.
    var strict: Bool?
}

// MARK: - Tool Calls & Outputs

/// A tool call returned by the model in a response.
struct LLMToolCall: Sendable, Equatable {
    /// Provider-assigned call ID for correlating with tool outputs.
    var id: String
    /// Name of the function to call.
    var name: String
    /// Raw JSON string of the function arguments.
    var arguments: String
}

/// Result of executing a tool call, sent back to the model.
struct LLMToolOutput: Sendable, Equatable {
    /// Correlates with `LLMToolCall.id`.
    var callID: String
    /// Serialized tool result.
    var output: String
}

// MARK: - Conversation State

/// Opaque, provider-managed conversation state.
///
/// The agent runner stores this per session and passes it back into subsequent requests.
/// Each provider packs whatever it needs:
/// - **OpenAI**: the `previousResponseID` string
/// - **Mistral/Ollama**: accumulated message history (JSON-encoded)
/// - **Anthropic**: accumulated message history
///
/// The agent runner never inspects `data` — it only checks `providerID` to prevent
/// accidentally mixing state across providers.
struct LLMConversationState: Sendable {
    var providerID: LLMProviderID
    var data: Data

    /// Pack a simple string (e.g. OpenAI previousResponseID).
    static func string(_ value: String, provider: LLMProviderID) -> LLMConversationState {
        LLMConversationState(
            providerID: provider,
            data: Data(value.utf8)
        )
    }

    /// Unpack as string.
    var stringValue: String? {
        String(data: data, encoding: .utf8)
    }

    /// Pack Codable data (e.g. message history).
    static func encoded<T: Encodable>(_ value: T, provider: LLMProviderID) throws -> LLMConversationState {
        LLMConversationState(
            providerID: provider,
            data: try JSONEncoder().encode(value)
        )
    }

    /// Unpack Codable data.
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Request

struct LLMRequest: Sendable {
    var messages: [LLMMessage]
    var tools: [LLMToolDefinition]
    var toolOutputs: [LLMToolOutput]
    var conversationState: LLMConversationState?

    init(
        messages: [LLMMessage],
        tools: [LLMToolDefinition] = [],
        toolOutputs: [LLMToolOutput] = [],
        conversationState: LLMConversationState? = nil
    ) {
        self.messages = messages
        self.tools = tools
        self.toolOutputs = toolOutputs
        self.conversationState = conversationState
    }
}

// MARK: - Response

struct LLMResponse: Sendable {
    /// The assistant's text reply (empty if only tool calls were returned).
    var text: String
    /// Tool calls the model wants executed.
    var toolCalls: [LLMToolCall]
    /// Updated conversation state to pass into the next request.
    var updatedConversationState: LLMConversationState
}

// MARK: - Streaming Events

enum LLMStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case textDone(String)
    case reasoningDelta(String)
    case reasoningDone(String)
    case reasoningSummaryDelta(String)
    case reasoningSummaryDone(String)
}

// MARK: - Errors

enum LLMProviderError: LocalizedError, Equatable {
    case missingAPIKey(provider: String)
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case encodingFailure(String)
    case decodingFailure(String)
    case transportFailure(String)
    case providerNotConfigured(LLMProviderID)
    case modelNotSupported(model: String, provider: String)
    case conversationStateMismatch(expected: LLMProviderID, got: LLMProviderID)

    var errorDescription: String? {
        switch self {
        case let .missingAPIKey(provider):
            return "\(provider) API key is not configured. Add it in Settings → AI Assistant."
        case .invalidResponse:
            return "Provider returned an invalid response."
        case let .httpError(code, msg):
            return msg.isEmpty
                ? "Request failed (HTTP \(code))."
                : "Request failed (\(code)): \(msg)"
        case let .encodingFailure(msg):
            return "Failed to encode request: \(msg)"
        case let .decodingFailure(msg):
            return "Failed to decode response: \(msg)"
        case let .transportFailure(msg):
            return "Network request failed: \(msg)"
        case let .providerNotConfigured(id):
            return "\(id.displayName) is not configured."
        case let .modelNotSupported(model, provider):
            return "Model '\(model)' is not supported by \(provider)."
        case let .conversationStateMismatch(expected, got):
            return "Conversation from \(got.displayName) cannot continue with \(expected.displayName). Start a new conversation."
        }
    }
}

// MARK: - JSON Value

/// Generic JSON value type for tool parameter schemas.
/// Direct replacement for the existing OpenAIJSONValue — same Codable logic.
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

