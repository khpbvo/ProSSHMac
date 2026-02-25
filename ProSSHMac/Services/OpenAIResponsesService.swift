import Foundation
import os.log

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

private struct OpenAIStreamingUnsupportedError: Error {}

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

@MainActor
final class OpenAIResponsesService: OpenAIResponsesServicing {
    static let requiredModel = "gpt-5.1-codex-max"
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.Responses")
    private static let maxResponsePreviewCharacters = 2_000

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
                let response = try await performRequest(
                    apiKey: apiKey,
                    request: request,
                    traceID: traceID
                )
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

    func createResponseStreaming(
        _ request: OpenAIResponsesRequest,
        onEvent: @escaping @Sendable (OpenAIResponsesStreamEvent) -> Void
    ) async throws -> OpenAIResponsesResponse {
        let apiKey = await apiKeyProvider.currentAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey, !apiKey.isEmpty else {
            throw OpenAIResponsesServiceError.missingAPIKey
        }

        let traceID = Self.shortTraceID()
        Self.logger.debug(
            "[\(traceID, privacy: .public)] stream_request_start messages=\(request.messages.count) tools=\(request.tools.count) tool_outputs=\(request.toolOutputs.count) prev_id_present=\(request.previousResponseID != nil)"
        )

        var attempt = 0
        while true {
            let attemptStart = DispatchTime.now().uptimeNanoseconds
            do {
                let response = try await performStreamingRequest(
                    apiKey: apiKey,
                    request: request,
                    onEvent: onEvent,
                    traceID: traceID
                )
                let ms = Self.elapsedMillis(since: attemptStart)
                Self.logger.info(
                    "[\(traceID, privacy: .public)] stream_request_ok attempt=\(attempt + 1) ms=\(ms) response_id=\(response.id, privacy: .public) output_items=\(response.output.count)"
                )
                return response
            } catch let serviceError as OpenAIResponsesServiceError {
                let ms = Self.elapsedMillis(since: attemptStart)
                var effectiveError = serviceError

                if case .invalidResponse = serviceError {
                    Self.logger.warning(
                        "[\(traceID, privacy: .public)] stream_fallback_start attempt=\(attempt + 1) reason=invalid_response"
                    )
                    do {
                        let fallbackResponse = try await performRequest(
                            apiKey: apiKey,
                            request: request,
                            traceID: traceID
                        )
                        let fallbackText = fallbackResponse.text
                        if !fallbackText.isEmpty {
                            onEvent(.outputTextDone(fallbackText))
                        }
                        Self.logger.info(
                            "[\(traceID, privacy: .public)] stream_fallback_ok attempt=\(attempt + 1) response_id=\(fallbackResponse.id, privacy: .public)"
                        )
                        return fallbackResponse
                    } catch let fallbackError as OpenAIResponsesServiceError {
                        effectiveError = fallbackError
                        Self.logger.warning(
                            "[\(traceID, privacy: .public)] stream_fallback_failed attempt=\(attempt + 1) reason=\(fallbackError.localizedDescription, privacy: .public)"
                        )
                    }
                }

                let willRetry = shouldRetry(after: effectiveError, attempt: attempt)
                if willRetry {
                    let nextAttempt = attempt + 2
                    Self.logger.warning(
                        "[\(traceID, privacy: .public)] stream_request_retry attempt=\(attempt + 1) ms=\(ms) next_attempt=\(nextAttempt) reason=\(effectiveError.localizedDescription, privacy: .public)"
                    )
                } else {
                    Self.logger.error(
                        "[\(traceID, privacy: .public)] stream_request_failed attempt=\(attempt + 1) ms=\(ms) reason=\(effectiveError.localizedDescription, privacy: .public)"
                    )
                }
                guard willRetry else {
                    throw effectiveError
                }
                attempt += 1
                try await sleepBeforeRetry(attempt: attempt)
            }
        }
    }

    private func performRequest(
        apiKey: String,
        request: OpenAIResponsesRequest,
        traceID: String?
    ) async throws -> OpenAIResponsesResponse {
        let payload = createPayload(request: request, stream: false)

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
            throw normalizeTransportError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            if let traceID {
                Self.logger.error(
                    "[\(traceID, privacy: .public)] response_invalid_non_http body_preview=\(Self.logPreview(from: data), privacy: .public)"
                )
            }
            throw OpenAIResponsesServiceError.invalidResponse
        }

        if let traceID, Self.shouldLogResponsePayloads() {
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            Self.logger.debug(
                "[\(traceID, privacy: .public)] response_payload status=\(httpResponse.statusCode) content_type=\(contentType, privacy: .public) body_preview=\(Self.logPreview(from: data), privacy: .public)"
            )
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

    private func performStreamingRequest(
        apiKey: String,
        request: OpenAIResponsesRequest,
        onEvent: @escaping @Sendable (OpenAIResponsesStreamEvent) -> Void,
        traceID: String
    ) async throws -> OpenAIResponsesResponse {
        let payload = createPayload(request: request, stream: true)
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
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = encodedPayload

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch is OpenAIStreamingUnsupportedError {
            let response = try await performRequest(
                apiKey: apiKey,
                request: request,
                traceID: traceID
            )
            let text = response.text
            if !text.isEmpty {
                onEvent(.outputTextDone(text))
            }
            return response
        } catch {
            throw normalizeTransportError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Self.logger.error("[\(traceID, privacy: .public)] stream_invalid_non_http_response")
            throw OpenAIResponsesServiceError.invalidResponse
        }

        if Self.shouldLogResponsePayloads() {
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            Self.logger.debug(
                "[\(traceID, privacy: .public)] stream_response_headers status=\(httpResponse.statusCode) content_type=\(contentType, privacy: .public)"
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            if Self.shouldLogResponsePayloads() {
                Self.logger.error(
                    "[\(traceID, privacy: .public)] stream_http_error_payload status=\(httpResponse.statusCode) body_preview=\(Self.logPreview(from: data), privacy: .public)"
                )
            }
            let message = Self.extractErrorMessage(from: data)
            throw OpenAIResponsesServiceError.httpError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let isSSEContentType = contentType.contains("text/event-stream")
        let isJSONContentType = contentType.contains("application/json")
        if isJSONContentType && !isSSEContentType {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            if Self.shouldLogResponsePayloads() {
                Self.logger.debug(
                    "[\(traceID, privacy: .public)] stream_json_success_payload body_preview=\(Self.logPreview(from: data), privacy: .public)"
                )
            }
            do {
                let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
                let text = decoded.text
                if !text.isEmpty {
                    onEvent(.outputTextDone(text))
                }
                return decoded
            } catch {
                throw OpenAIResponsesServiceError.decodingFailure(error.localizedDescription)
            }
        }

        var eventName: String?
        var dataLines: [String] = []
        var completedResponse: OpenAIResponsesResponse?
        var accumulator = StreamingResponseAccumulator()
        var nonSSELines: [String] = []

        func flushEvent() throws {
            guard !dataLines.isEmpty else {
                eventName = nil
                return
            }
            let payloadText = dataLines.joined(separator: "\n")
            let currentEventName = eventName
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            if payloadText.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                return
            }
            if Self.shouldLogResponsePayloads() {
                let eventForLog = currentEventName ?? "n/a"
                Self.logger.debug(
                    "[\(traceID, privacy: .public)] stream_event event=\(eventForLog, privacy: .public) payload_preview=\(Self.logPreview(from: payloadText), privacy: .public)"
                )
            }
            if let parsedResponse = try Self.consumeStreamPayload(
                payloadText,
                eventName: currentEventName,
                onEvent: onEvent,
                accumulator: &accumulator
            ) {
                completedResponse = parsedResponse
            }
        }

        do {
            var lineBuffer = Data()
            func consumeLine(_ rawLine: String) throws {
                var line = rawLine
                if line.hasSuffix("\r") {
                    line.removeLast()
                }
                if line.isEmpty {
                    try flushEvent()
                    return
                }
                if line.hasPrefix(":") {
                    return
                }
                if let value = Self.sseFieldValue(prefix: "event:", line: line) {
                    eventName = value
                    return
                }
                if let value = Self.sseFieldValue(prefix: "data:", line: line) {
                    dataLines.append(value)
                    return
                }
                nonSSELines.append(line)
            }

            for try await byte in bytes {
                if byte == 0x0A { // LF
                    let line = String(decoding: lineBuffer, as: UTF8.self)
                    try consumeLine(line)
                    lineBuffer.removeAll(keepingCapacity: true)
                } else {
                    lineBuffer.append(byte)
                }
            }
            if !lineBuffer.isEmpty {
                let line = String(decoding: lineBuffer, as: UTF8.self)
                try consumeLine(line)
            }
            try flushEvent()
        } catch let serviceError as OpenAIResponsesServiceError {
            throw serviceError
        } catch {
            throw OpenAIResponsesServiceError.transportFailure(error.localizedDescription)
        }

        if let completedResponse {
            return completedResponse
        }
        if let assembled = accumulator.assembledResponse {
            return assembled
        }
        if !nonSSELines.isEmpty {
            let body = nonSSELines.joined(separator: "\n")
            if Self.shouldLogResponsePayloads() {
                Self.logger.warning(
                    "[\(traceID, privacy: .public)] stream_non_sse_body_preview=\(Self.logPreview(from: body), privacy: .public)"
                )
            }
            if let data = body.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(OpenAIResponsesResponse.self, from: data) {
                let text = decoded.text
                if !text.isEmpty {
                    onEvent(.outputTextDone(text))
                }
                return decoded
            }
        }
        if Self.shouldLogResponsePayloads() {
            Self.logger.error(
                "[\(traceID, privacy: .public)] stream_invalid_response_no_completed_payload"
            )
        }
        throw OpenAIResponsesServiceError.invalidResponse
    }

    private func createPayload(request: OpenAIResponsesRequest, stream: Bool) -> CreateRequestPayload {
        CreateRequestPayload(
            model: Self.requiredModel,
            input: request.messages.map { .message(CreateInputMessage(message: $0)) }
                + request.toolOutputs.map { .functionCallOutput(CreateFunctionCallOutput(output: $0)) },
            tools: request.tools.isEmpty ? nil : request.tools,
            previousResponseID: request.previousResponseID,
            stream: stream ? true : nil,
            reasoning: .init(summary: "auto")
        )
    }

    private func normalizeTransportError(_ error: Error) -> OpenAIResponsesServiceError {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return .transportFailure("cancelled")
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return .transportFailure("cancelled")
        }
        return .transportFailure(error.localizedDescription)
    }

    private func shouldRetry(after error: OpenAIResponsesServiceError, attempt: Int) -> Bool {
        guard attempt < maxRetryAttempts else { return false }

        switch error {
        case .invalidResponse:
            return true
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

    private static func shouldLogResponsePayloads() -> Bool {
        let defaultsKey = "ai.logging.logOpenAIResponsesPayloads"
        if let value = UserDefaults.standard.object(forKey: defaultsKey) as? Bool {
            return value
        }

        let env = ProcessInfo.processInfo.environment["PROSSH_LOG_OPENAI_RESPONSE_PAYLOADS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let env, ["1", "true", "yes", "on"].contains(env) {
            return true
        }
        if let env, ["0", "false", "no", "off"].contains(env) {
            return false
        }

        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func logPreview(from data: Data) -> String {
        guard !data.isEmpty else { return "<empty>" }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return logPreview(from: text)
    }

    private static func logPreview(from text: String) -> String {
        guard !text.isEmpty else { return "<empty>" }
        let collapsed = text.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if collapsed.count <= maxResponsePreviewCharacters {
            return collapsed
        }
        let prefix = String(collapsed.prefix(maxResponsePreviewCharacters))
        return "\(prefix)…(truncated)"
    }

    private static func sseFieldValue(prefix: String, line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        return value
    }

    private static func consumeStreamPayload(
        _ payloadText: String,
        eventName: String?,
        onEvent: @escaping @Sendable (OpenAIResponsesStreamEvent) -> Void,
        accumulator: inout StreamingResponseAccumulator
    ) throws -> OpenAIResponsesResponse? {
        guard let data = payloadText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        let type = (dictionary["type"] as? String) ?? eventName ?? ""
        guard !type.isEmpty else { return nil }
        accumulator.ingest(type: type, payload: dictionary)

        switch type {
        case "response.text.delta":
            if let delta = stringField(in: dictionary, key: "delta"), !delta.isEmpty {
                onEvent(.outputTextDelta(delta))
            }
        case "response.text.done":
            if let text = stringField(in: dictionary, key: "text"), !text.isEmpty {
                onEvent(.outputTextDone(text))
            }
        case "response.output_text.delta":
            if let delta = stringField(in: dictionary, key: "delta"), !delta.isEmpty {
                onEvent(.outputTextDelta(delta))
            }
        case "response.output_text.done":
            if let text = stringField(in: dictionary, key: "text"), !text.isEmpty {
                onEvent(.outputTextDone(text))
            }
        case "response.reasoning_text.delta":
            if let delta = stringField(in: dictionary, key: "delta"), !delta.isEmpty {
                onEvent(.reasoningTextDelta(delta))
            }
        case "response.reasoning_text.done":
            if let text = stringField(in: dictionary, key: "text"), !text.isEmpty {
                onEvent(.reasoningTextDone(text))
            }
        case "response.reasoning_summary_text.delta":
            if let delta = stringField(in: dictionary, key: "delta"), !delta.isEmpty {
                onEvent(.reasoningSummaryTextDelta(delta))
            }
        case "response.reasoning_summary_text.done":
            if let text = stringField(in: dictionary, key: "text"), !text.isEmpty {
                onEvent(.reasoningSummaryTextDone(text))
            }
        case "response.reasoning_summary_part.added":
            if let text = reasoningSummaryText(from: dictionary), !text.isEmpty {
                onEvent(.reasoningSummaryTextDelta(text))
            }
        case "response.reasoning_summary_part.done":
            if let text = reasoningSummaryText(from: dictionary), !text.isEmpty {
                onEvent(.reasoningSummaryTextDone(text))
            }
        case "response.refusal.delta":
            if let delta = stringField(in: dictionary, key: "delta"), !delta.isEmpty {
                onEvent(.outputTextDelta(delta))
            }
        case "response.refusal.done":
            if let text = stringField(in: dictionary, key: "refusal")
                ?? stringField(in: dictionary, key: "text"),
               !text.isEmpty {
                onEvent(.outputTextDone(text))
            }
        case "error":
            let message = streamErrorMessage(from: dictionary)
            throw OpenAIResponsesServiceError.httpError(statusCode: 500, message: message)
        case "response.failed":
            let message = streamErrorMessage(from: dictionary)
            throw OpenAIResponsesServiceError.httpError(statusCode: 500, message: message)
        case "response.completed":
            if let response = completedResponse(from: dictionary) {
                return response
            }
        default:
            break
        }

        return nil
    }

    private static func completedResponse(from payload: [String: Any]) -> OpenAIResponsesResponse? {
        if let responseObject = payload["response"] {
            if let decoded = decodeJSONValue(responseObject, as: OpenAIResponsesResponse.self) {
                return decoded
            }
        }
        return decodeJSONValue(payload, as: OpenAIResponsesResponse.self)
    }

    private static func streamErrorMessage(from payload: [String: Any]) -> String {
        if let errorObject = payload["error"] as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let message = payload["message"] as? String, !message.isEmpty {
            return message
        }
        if let responseObject = payload["response"] as? [String: Any],
           let errorObject = responseObject["error"] as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.isEmpty {
            return message
        }
        return "OpenAI streaming request failed."
    }

    private static func stringField(in payload: [String: Any], key: String) -> String? {
        payload[key] as? String
    }

    private static func reasoningSummaryText(from payload: [String: Any]) -> String? {
        guard let part = payload["part"] as? [String: Any] else {
            return nil
        }
        let type = part["type"] as? String
        guard type == "summary_text" || type == "text" || type == "output_text" else {
            return nil
        }
        return part["text"] as? String
    }

    fileprivate static func decodeJSONValue<T: Decodable>(_ value: Any, as type: T.Type) -> T? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private struct StreamingResponseAccumulator {
    var responseID: String?
    var status: String?
    private var outputItemsByID: [String: OpenAIResponsesResponse.OutputItem] = [:]
    private var outputItemsNoID: [OpenAIResponsesResponse.OutputItem] = []
    private var outputOrderByItemID: [String: Int] = [:]
    private var fallbackText = ""
    private var fallbackTextFinal: String?
    private var functionCallArgumentsByItemID: [String: String] = [:]

    var assembledResponse: OpenAIResponsesResponse? {
        guard let responseID else { return nil }
        return OpenAIResponsesResponse(
            id: responseID,
            status: status,
            outputText: nil,
            output: buildOutputItems()
        )
    }

    mutating func ingest(type: String, payload: [String: Any]) {
        if responseID == nil {
            responseID = payload["response_id"] as? String
        }
        if responseID == nil {
            responseID = payload["id"] as? String
        }
        if let outputIndex = payload["output_index"] as? Int,
           let itemID = payload["item_id"] as? String {
            outputOrderByItemID[itemID] = outputIndex
        }

        if let responseObject = payload["response"] as? [String: Any] {
            ingestResponseObject(responseObject)
        }

        switch type {
        case "response.created":
            status = "created"
        case "response.in_progress":
            status = "in_progress"
        case "response.completed":
            status = "completed"
        case "response.failed":
            status = "failed"
        case "response.output_item.added",
             "response.output_item.done":
            if let itemObject = payload["item"] {
                ingestOutputItem(itemObject, outputIndex: payload["output_index"] as? Int)
            }
        case "response.function_call_arguments.delta":
            ingestFunctionCallArgumentsDelta(payload)
        case "response.function_call_arguments.done":
            ingestFunctionCallArgumentsDone(payload)
        case "response.text.delta",
             "response.output_text.delta":
            ingestTextDelta(payload)
        case "response.text.done",
             "response.output_text.done":
            ingestTextDone(payload)
        case "response.refusal.delta":
            ingestRefusalDelta(payload)
        case "response.refusal.done":
            ingestRefusalDone(payload)
        case "response.content_part.added":
            ingestContentPart(payload, isDone: false)
        case "response.content_part.done":
            ingestContentPart(payload, isDone: true)
        default:
            break
        }
    }

    private mutating func ingestResponseObject(_ responseObject: [String: Any]) {
        if let id = responseObject["id"] as? String, !id.isEmpty {
            responseID = id
        }
        if let statusValue = responseObject["status"] as? String, !statusValue.isEmpty {
            status = statusValue
        }
        if let outputValue = responseObject["output"] as? [Any], !outputValue.isEmpty {
            for (index, itemObject) in outputValue.enumerated() {
                ingestOutputItem(itemObject, outputIndex: index)
            }
        }
    }

    private mutating func ingestOutputItem(_ itemObject: Any, outputIndex: Int?) {
        guard let item = parseOutputItem(itemObject) else { return }
        if let itemID = item.id {
            outputItemsByID[itemID] = item
            if let outputIndex {
                outputOrderByItemID[itemID] = outputIndex
            }
        } else {
            outputItemsNoID.append(item)
        }
    }

    private mutating func ingestFunctionCallArgumentsDelta(_ payload: [String: Any]) {
        guard let itemID = payload["item_id"] as? String else { return }
        let delta = payload["delta"] as? String ?? ""
        guard !delta.isEmpty else { return }
        functionCallArgumentsByItemID[itemID, default: ""] += delta
    }

    private mutating func ingestFunctionCallArgumentsDone(_ payload: [String: Any]) {
        guard let itemID = payload["item_id"] as? String else { return }
        let doneArgs = payload["arguments"] as? String
        if let doneArgs {
            functionCallArgumentsByItemID[itemID] = doneArgs
        } else if functionCallArgumentsByItemID[itemID] == nil {
            functionCallArgumentsByItemID[itemID] = ""
        }
    }

    private mutating func ingestTextDelta(_ payload: [String: Any]) {
        guard let delta = payload["delta"] as? String, !delta.isEmpty else { return }
        if let itemID = payload["item_id"] as? String {
            appendText(delta, toMessageItemID: itemID)
        } else {
            fallbackText += delta
        }
    }

    private mutating func ingestTextDone(_ payload: [String: Any]) {
        guard let text = payload["text"] as? String, !text.isEmpty else { return }
        if let itemID = payload["item_id"] as? String {
            setText(text, toMessageItemID: itemID)
        } else {
            fallbackTextFinal = text
        }
    }

    private mutating func ingestRefusalDelta(_ payload: [String: Any]) {
        guard let delta = payload["delta"] as? String, !delta.isEmpty else { return }
        if let itemID = payload["item_id"] as? String {
            appendText(delta, toMessageItemID: itemID)
        } else {
            fallbackText += delta
        }
    }

    private mutating func ingestRefusalDone(_ payload: [String: Any]) {
        let text = (payload["refusal"] as? String) ?? (payload["text"] as? String) ?? ""
        guard !text.isEmpty else { return }
        if let itemID = payload["item_id"] as? String {
            setText(text, toMessageItemID: itemID)
        } else {
            fallbackTextFinal = text
        }
    }

    private mutating func ingestContentPart(_ payload: [String: Any], isDone: Bool) {
        guard let itemID = payload["item_id"] as? String,
              let part = payload["part"] as? [String: Any] else {
            return
        }
        let type = part["type"] as? String
        guard type == "text" || type == "output_text" else { return }
        let text = part["text"] as? String ?? ""
        guard !text.isEmpty else { return }
        if isDone {
            setText(text, toMessageItemID: itemID)
        } else {
            appendText(text, toMessageItemID: itemID)
        }
    }

    private mutating func appendText(_ delta: String, toMessageItemID itemID: String) {
        var item = messageItem(for: itemID)
        let existing = item.content?.first?.text ?? ""
        item.content = [.init(type: "output_text", text: existing + delta)]
        outputItemsByID[itemID] = item
    }

    private mutating func setText(_ text: String, toMessageItemID itemID: String) {
        var item = messageItem(for: itemID)
        item.content = [.init(type: "output_text", text: text)]
        outputItemsByID[itemID] = item
    }

    private func messageItem(for itemID: String) -> OpenAIResponsesResponse.OutputItem {
        if let existing = outputItemsByID[itemID] {
            return existing
        }
        return OpenAIResponsesResponse.OutputItem(
            type: "message",
            id: itemID,
            role: "assistant",
            content: [.init(type: "output_text", text: "")],
            name: nil,
            callID: nil,
            arguments: nil
        )
    }

    private func parseOutputItem(_ value: Any) -> OpenAIResponsesResponse.OutputItem? {
        if let decoded = OpenAIResponsesService.decodeJSONValue(
            value,
            as: OpenAIResponsesResponse.OutputItem.self
        ) {
            return decoded
        }

        guard let itemDict = value as? [String: Any] else { return nil }
        let type = itemDict["type"] as? String ?? "message"
        let id = itemDict["id"] as? String
        let role = itemDict["role"] as? String
        let name = itemDict["name"] as? String
        let callID = (itemDict["call_id"] as? String) ?? (itemDict["callID"] as? String)
        let arguments = itemDict["arguments"] as? String

        var contentItems: [OpenAIResponsesResponse.ContentItem] = []
        if let contentArray = itemDict["content"] as? [Any] {
            for part in contentArray {
                guard let partDict = part as? [String: Any] else { continue }
                let partType = partDict["type"] as? String ?? "text"
                let text = partDict["text"] as? String
                contentItems.append(.init(type: partType, text: text))
            }
        } else if let text = itemDict["text"] as? String {
            contentItems = [.init(type: "output_text", text: text)]
        }

        return OpenAIResponsesResponse.OutputItem(
            type: type,
            id: id,
            role: role,
            content: contentItems.isEmpty ? nil : contentItems,
            name: name,
            callID: callID,
            arguments: arguments
        )
    }

    private func buildOutputItems() -> [OpenAIResponsesResponse.OutputItem] {
        var mergedByID = outputItemsByID
        var orderByItemID = outputOrderByItemID

        for (itemID, arguments) in functionCallArgumentsByItemID {
            var item = mergedByID[itemID] ?? OpenAIResponsesResponse.OutputItem(
                type: "function_call",
                id: itemID,
                role: nil,
                content: nil,
                name: nil,
                callID: nil,
                arguments: nil
            )
            if item.type != "function_call" {
                item.type = "function_call"
                item.role = nil
                item.content = nil
            }
            item.arguments = arguments
            mergedByID[itemID] = item
        }

        let fallbackFinalText = fallbackTextFinal ?? (fallbackText.isEmpty ? nil : fallbackText)
        if let fallbackFinalText, !fallbackFinalText.isEmpty {
            if let firstMessageID = mergedByID.first(where: { $0.value.type == "message" })?.key {
                var item = mergedByID[firstMessageID]!
                item.content = [.init(type: "output_text", text: fallbackFinalText)]
                mergedByID[firstMessageID] = item
            } else if mergedByID.isEmpty {
                let syntheticID = "msg_stream_text"
                mergedByID[syntheticID] = OpenAIResponsesResponse.OutputItem(
                    type: "message",
                    id: syntheticID,
                    role: "assistant",
                    content: [.init(type: "output_text", text: fallbackFinalText)],
                    name: nil,
                    callID: nil,
                    arguments: nil
                )
                if orderByItemID[syntheticID] == nil {
                    orderByItemID[syntheticID] = 0
                }
            }
        }

        var result = mergedByID
            .sorted { lhs, rhs in
                let l = orderByItemID[lhs.key] ?? Int.max
                let r = orderByItemID[rhs.key] ?? Int.max
                if l == r { return lhs.key < rhs.key }
                return l < r
            }
            .map(\.value)
        result.append(contentsOf: outputItemsNoID)
        return result
    }
}

private struct CreateRequestPayload: Encodable {
    struct Reasoning: Encodable {
        var summary: String
    }

    var model: String
    var input: [CreateInputItem]
    var tools: [OpenAIResponsesToolDefinition]?
    var previousResponseID: String?
    var stream: Bool?
    var reasoning: Reasoning?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case tools
        case previousResponseID = "previous_response_id"
        case stream
        case reasoning
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
