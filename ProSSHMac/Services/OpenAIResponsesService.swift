import Foundation
import os.log

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
    static let requiredModel = "gpt-5.1-codex-max"
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.Responses")

    private let apiKeyProvider: any OpenAIAPIKeyProviding
    private let session: any OpenAIHTTPSessioning
    private let endpointURL: URL
    private let maxRetryAttempts: Int
    private let baseRetryDelayNanoseconds: UInt64

    init(
        apiKeyProvider: any OpenAIAPIKeyProviding,
        session: any OpenAIHTTPSessioning = URLSession.shared,
        endpointURL: URL = URL(string: "https://api.openai.com/v1/responses")!,
        maxRetryAttempts: Int = 2,
        baseRetryDelayMilliseconds: UInt64 = 450
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.endpointURL = endpointURL
        self.maxRetryAttempts = max(0, maxRetryAttempts)
        self.baseRetryDelayNanoseconds = max(100, baseRetryDelayMilliseconds) * 1_000_000
    }

    func createResponse(_ request: OpenAIResponsesRequest) async throws -> OpenAIResponsesResponse {
        let apiKey = await apiKeyProvider.currentAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey, !apiKey.isEmpty else {
            throw OpenAIResponsesServiceError.missingAPIKey
        }

        let traceID = Self.shortTraceID()
        Self.logger.debug(
            "[\(traceID, privacy: .public)] request_start messages=\(request.messages.count) tools=\(request.tools.count) tool_outputs=\(request.toolOutputs.count) prev_id_present=\(request.previousResponseID != nil)"
        )
        var attempt = 0
        while true {
            let attemptStart = DispatchTime.now().uptimeNanoseconds
            do {
                let response = try await performRequest(apiKey: apiKey, request: request)
                let ms = Self.elapsedMillis(since: attemptStart)
                Self.logger.info(
                    "[\(traceID, privacy: .public)] request_ok attempt=\(attempt + 1) ms=\(ms) response_id=\(response.id, privacy: .public) output_items=\(response.output.count)"
                )
                return response
            } catch let serviceError as OpenAIResponsesServiceError {
                let ms = Self.elapsedMillis(since: attemptStart)
                let willRetry = shouldRetry(after: serviceError, attempt: attempt)
                if willRetry {
                    let nextAttempt = attempt + 2
                    Self.logger.warning(
                        "[\(traceID, privacy: .public)] request_retry attempt=\(attempt + 1) ms=\(ms) next_attempt=\(nextAttempt) reason=\(serviceError.localizedDescription, privacy: .public)"
                    )
                } else {
                    Self.logger.error(
                        "[\(traceID, privacy: .public)] request_failed attempt=\(attempt + 1) ms=\(ms) reason=\(serviceError.localizedDescription, privacy: .public)"
                    )
                }
                guard willRetry else {
                    throw serviceError
                }
                attempt += 1
                try await sleepBeforeRetry(attempt: attempt)
            }
        }
    }

    private func performRequest(
        apiKey: String,
        request: OpenAIResponsesRequest
    ) async throws -> OpenAIResponsesResponse {
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
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw OpenAIResponsesServiceError.transportFailure("cancelled")
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                throw OpenAIResponsesServiceError.transportFailure("cancelled")
            }
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

    private func shouldRetry(after error: OpenAIResponsesServiceError, attempt: Int) -> Bool {
        guard attempt < maxRetryAttempts else { return false }

        switch error {
        case let .httpError(statusCode, _):
            return statusCode == 429 || (500...599).contains(statusCode)
        case let .transportFailure(message):
            let lowered = message.lowercased()
            if lowered.contains("cancelled") || lowered.contains("canceled") {
                return false
            }
            return true
        default:
            return false
        }
    }

    private func sleepBeforeRetry(attempt: Int) async throws {
        let exponent = max(0, attempt - 1)
        let multiplier = UInt64(1 << min(exponent, 6))
        let delay = min(baseRetryDelayNanoseconds * multiplier, 5_000_000_000)
        try await Task.sleep(nanoseconds: delay)
    }

    private nonisolated static func shortTraceID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private nonisolated static func elapsedMillis(since startNanoseconds: UInt64) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = now >= startNanoseconds ? now - startNanoseconds : 0
        return Int(delta / 1_000_000)
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

    var type = "message"
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
