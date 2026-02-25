// swiftlint:disable file_length
import Foundation
import os.log

@MainActor
final class OpenAIResponsesService: OpenAIResponsesServicing {
    static let requiredModel = "gpt-5.1-codex-max"
    static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.Responses")
    private static let maxResponsePreviewCharacters = 2_000

    let apiKeyProvider: any OpenAIAPIKeyProviding
    let session: any OpenAIHTTPSessioning
    let endpointURL: URL
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

    func performRequest(
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

    func createPayload(request: OpenAIResponsesRequest, stream: Bool) -> CreateRequestPayload {
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

    func normalizeTransportError(_ error: Error) -> OpenAIResponsesServiceError {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return .transportFailure("cancelled")
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return .transportFailure("cancelled")
        }
        return .transportFailure(error.localizedDescription)
    }

    func shouldRetry(after error: OpenAIResponsesServiceError, attempt: Int) -> Bool {
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

    func sleepBeforeRetry(attempt: Int) async throws {
        let exponent = max(0, attempt - 1)
        let multiplier = UInt64(1 << min(exponent, 6))
        let delay = min(baseRetryDelayNanoseconds * multiplier, 5_000_000_000)
        try await Task.sleep(nanoseconds: delay)
    }

    nonisolated static func shortTraceID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    nonisolated static func elapsedMillis(since startNanoseconds: UInt64) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = now >= startNanoseconds ? now - startNanoseconds : 0
        return Int(delta / 1_000_000)
    }

    static func extractErrorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let decoded = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
            return decoded.error.message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func shouldLogResponsePayloads() -> Bool {
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

    static func logPreview(from data: Data) -> String {
        guard !data.isEmpty else { return "<empty>" }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return logPreview(from: text)
    }

    static func logPreview(from text: String) -> String {
        guard !text.isEmpty else { return "<empty>" }
        let collapsed = text.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if collapsed.count <= maxResponsePreviewCharacters {
            return collapsed
        }
        let prefix = String(collapsed.prefix(maxResponsePreviewCharacters))
        return "\(prefix)…(truncated)"
    }

    static func sseFieldValue(prefix: String, line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        return value
    }

    static func decodeJSONValue<T: Decodable>(_ value: Any, as type: T.Type) -> T? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}
