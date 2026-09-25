import Foundation

// Shared AI tool and streaming types. Wire messages and model metadata live in
// OpenRouterTypes.swift.

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
