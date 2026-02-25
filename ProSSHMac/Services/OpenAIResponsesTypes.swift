// Extracted from OpenAIResponsesService.swift
import Foundation

@MainActor
protocol OpenAIResponsesServicing: Sendable {
    func createResponse(_ request: OpenAIResponsesRequest) async throws -> OpenAIResponsesResponse
    func createResponseStreaming(
        _ request: OpenAIResponsesRequest,
        onEvent: @escaping @Sendable (OpenAIResponsesStreamEvent) -> Void
    ) async throws -> OpenAIResponsesResponse
}

extension OpenAIResponsesServicing {
    func createResponseStreaming(
        _ request: OpenAIResponsesRequest,
        onEvent: @escaping @Sendable (OpenAIResponsesStreamEvent) -> Void
    ) async throws -> OpenAIResponsesResponse {
        let response = try await createResponse(request)
        let text = response.text
        if !text.isEmpty {
            onEvent(.outputTextDone(text))
        }
        return response
    }
}

protocol OpenAIHTTPSessioning: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

struct OpenAIStreamingUnsupportedError: Error {}

extension OpenAIHTTPSessioning {
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        _ = request
        throw OpenAIStreamingUnsupportedError()
    }
}

extension URLSession: OpenAIHTTPSessioning {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await bytes(for: request, delegate: nil)
    }
}

enum OpenAIResponsesServiceError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case encodingFailure(String)
    case decodingFailure(String)
    case transportFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is not configured. Add it in Settings > AI Assistant."
        case .invalidResponse:
            return "OpenAI service returned an invalid response."
        case let .httpError(statusCode, message):
            if message.isEmpty {
                return "OpenAI request failed with status \(statusCode)."
            }
            return "OpenAI request failed (\(statusCode)): \(message)"
        case let .encodingFailure(message):
            return "Failed to encode OpenAI request: \(message)"
        case let .decodingFailure(message):
            return "Failed to decode OpenAI response: \(message)"
        case let .transportFailure(message):
            return "OpenAI request failed: \(message)"
        }
    }
}

struct OpenAIResponsesMessage: Sendable, Equatable {
    enum Role: String, Sendable, Equatable {
        case user
        case assistant
        case system
        case developer
    }

    var role: Role
    var text: String
}

struct OpenAIResponsesToolOutput: Sendable, Equatable {
    var callID: String
    var output: String
}

enum OpenAIJSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OpenAIJSONValue])
    case array([OpenAIJSONValue])
    case null
}

extension OpenAIJSONValue: Codable {
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
        if let value = try? container.decode([String: OpenAIJSONValue].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([OpenAIJSONValue].self) {
            self = .array(value)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value for OpenAI payload."
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct OpenAIResponsesToolDefinition: Encodable, Sendable, Equatable {
    var type: String = "function"
    var name: String
    var description: String
    var parameters: OpenAIJSONValue
    var strict: Bool?
}

struct OpenAIResponsesRequest: Sendable, Equatable {
    var messages: [OpenAIResponsesMessage]
    var previousResponseID: String?
    var tools: [OpenAIResponsesToolDefinition]
    var toolOutputs: [OpenAIResponsesToolOutput]

    init(
        messages: [OpenAIResponsesMessage],
        previousResponseID: String? = nil,
        tools: [OpenAIResponsesToolDefinition] = [],
        toolOutputs: [OpenAIResponsesToolOutput] = []
    ) {
        self.messages = messages
        self.previousResponseID = previousResponseID
        self.tools = tools
        self.toolOutputs = toolOutputs
    }
}

struct OpenAIResponsesResponse: Decodable, Sendable, Equatable {
    struct ContentItem: Decodable, Sendable, Equatable {
        var type: String
        var text: String?
    }

    struct OutputItem: Decodable, Sendable, Equatable {
        var type: String
        var id: String?
        var role: String?
        var content: [ContentItem]?
        var name: String?
        var callID: String?
        var arguments: String?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case role
            case content
            case name
            case callID = "call_id"
            case arguments
        }
    }

    struct ToolCall: Sendable, Equatable {
        var id: String
        var name: String
        var arguments: String
    }

    var id: String
    var status: String?
    var outputText: String?
    var output: [OutputItem]

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case outputText = "output_text"
        case output
    }

    var text: String {
        if let outputText, !outputText.isEmpty {
            return outputText
        }

        let fragments = output.flatMap { item in
            (item.content ?? []).compactMap { content -> String? in
                guard content.type == "output_text" || content.type == "text" else {
                    return nil
                }
                return content.text
            }
        }
        return fragments.joined()
    }

    var toolCalls: [ToolCall] {
        output.compactMap { item in
            guard item.type == "function_call",
                  let callID = item.callID,
                  let name = item.name else {
                return nil
            }
            return ToolCall(id: callID, name: name, arguments: item.arguments ?? "")
        }
    }
}

enum OpenAIResponsesStreamEvent: Sendable, Equatable {
    case outputTextDelta(String)
    case outputTextDone(String)
    case reasoningTextDelta(String)
    case reasoningTextDone(String)
    case reasoningSummaryTextDelta(String)
    case reasoningSummaryTextDone(String)
}
