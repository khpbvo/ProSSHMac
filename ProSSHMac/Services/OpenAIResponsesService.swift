import Foundation

@MainActor
protocol OpenAIResponsesServicing: Sendable {
    func createResponse(_ request: OpenAIResponsesRequest) async throws -> OpenAIResponsesResponse
}

protocol OpenAIHTTPSessioning: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: OpenAIHTTPSessioning {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
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

@MainActor
final class OpenAIResponsesService: OpenAIResponsesServicing {
    static let requiredModel = "gpt-5.1-codex"

    private let apiKeyProvider: any OpenAIAPIKeyProviding
    private let session: any OpenAIHTTPSessioning
    private let endpointURL: URL

    init(
        apiKeyProvider: any OpenAIAPIKeyProviding,
        session: any OpenAIHTTPSessioning = URLSession.shared,
        endpointURL: URL = URL(string: "https://api.openai.com/v1/responses")!
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.endpointURL = endpointURL
    }

    func createResponse(_ request: OpenAIResponsesRequest) async throws -> OpenAIResponsesResponse {
        let apiKey = await apiKeyProvider.currentAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey, !apiKey.isEmpty else {
            throw OpenAIResponsesServiceError.missingAPIKey
        }

        let payload = CreateRequestPayload(
            model: Self.requiredModel,
            input: request.messages.map { .message(CreateInputMessage(message: $0)) }
                + request.toolOutputs.map { .functionCallOutput(CreateFunctionCallOutput(output: $0)) },
            tools: request.tools.isEmpty ? nil : request.tools,
            previousResponseID: request.previousResponseID
        )

        let encodedPayload: Data
        do {
            encodedPayload = try JSONEncoder().encode(payload)
        } catch {
            throw OpenAIResponsesServiceError.encodingFailure(error.localizedDescription)
        }

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = encodedPayload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw OpenAIResponsesServiceError.transportFailure(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIResponsesServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = Self.extractErrorMessage(from: data)
            throw OpenAIResponsesServiceError.httpError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        do {
            return try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        } catch {
            throw OpenAIResponsesServiceError.decodingFailure(error.localizedDescription)
        }
    }

    private static func extractErrorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let decoded = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
            return decoded.error.message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private struct CreateRequestPayload: Encodable {
    var model: String
    var input: [CreateInputItem]
    var tools: [OpenAIResponsesToolDefinition]?
    var previousResponseID: String?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case tools
        case previousResponseID = "previous_response_id"
    }
}

private enum CreateInputItem: Encodable {
    case message(CreateInputMessage)
    case functionCallOutput(CreateFunctionCallOutput)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case let .message(message):
            try message.encode(to: encoder)
        case let .functionCallOutput(output):
            try output.encode(to: encoder)
        }
    }
}

private struct CreateInputMessage: Encodable {
    struct Content: Encodable {
        var type = "input_text"
        var text: String
    }

    var role: String
    var content: [Content]

    init(message: OpenAIResponsesMessage) {
        self.role = message.role.rawValue
        self.content = [Content(text: message.text)]
    }
}

private struct CreateFunctionCallOutput: Encodable {
    var type = "function_call_output"
    var callID: String
    var output: String

    enum CodingKeys: String, CodingKey {
        case type
        case callID = "call_id"
        case output
    }

    init(output: OpenAIResponsesToolOutput) {
        callID = output.callID
        self.output = output.output
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        var message: String
        var type: String?
        var code: String?
    }

    var error: APIError
}
