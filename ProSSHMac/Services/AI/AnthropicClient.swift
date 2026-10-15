import Foundation
import os.log

@MainActor
protocol AnthropicServicing: Sendable {
    func fetchModels() async throws -> [AnthropicModel]
    func complete(
        _ request: AnthropicRequest,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> AnthropicResponse
}

/// Anthropic API over raw HTTPS (there is no Swift SDK). See `Docs/Anthropic.md`.
@MainActor
final class AnthropicClient: AnthropicServicing {
    nonisolated static let apiVersion = "2023-06-01"
    /// Makes `/v1/models` publish `allowed_fallback_models`.
    nonisolated static let modelsBetas = ["server-side-fallback-2026-06-01"]
    /// Required for `thinking.block_binding`; adds `input_transformations` to responses.
    nonisolated static let thinkingBindingBeta = "thinking-binding-controls-2026-08-01"
    /// The `fallbacks: "default"` form (the array form uses a different header).
    nonisolated static let defaultFallbackBeta = "server-side-fallback-2026-07-01"
    private static let maxCatalogPages = 20
    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504, 529]
    private nonisolated static let maxRetryAfterSeconds = 60.0
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.Anthropic")

    private struct APIErrorBody: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail?
    }

    private let keyStore: any AIAPIKeyStoring
    private let session: any AIHTTPSessioning
    private let baseURL: URL
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        keyStore: any AIAPIKeyStoring,
        session: any AIHTTPSessioning = URLSession.shared,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1/")!,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.keyStore = keyStore
        self.session = session
        self.baseURL = baseURL
        self.sleep = sleep
    }

    // MARK: - Models

    func fetchModels() async throws -> [AnthropicModel] {
        let key = try await requireKey()
        var models: [AnthropicModel] = []
        var afterID: String?
        do {
            for _ in 0..<Self.maxCatalogPages {
                var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                if let afterID { components.queryItems?.append(URLQueryItem(name: "after_id", value: afterID)) }
                var request = URLRequest(url: components.url!)
                request.timeoutInterval = 30
                applyHeaders(to: &request, key: key, betas: Self.modelsBetas)
                let (data, response) = try await session.data(for: request)
                try validate(response: response, data: data)
                let page = try JSONDecoder().decode(AnthropicModelsPage.self, from: data)
                models += page.data.filter { $0.type == nil || $0.type == "model" }
                guard page.hasMore, let lastID = page.lastID else { break }
                afterID = lastID
            }
        } catch {
            throw Self.mapped(error)
        }
        // Newest first; RFC 3339 timestamps in UTC sort correctly as strings.
        return models.sorted {
            if ($0.createdAt ?? "") != ($1.createdAt ?? "") { return ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            return $0.id < $1.id
        }
    }

    // MARK: - Messages

    func complete(
        _ request: AnthropicRequest,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> AnthropicResponse {
        let key = try await requireKey()
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Self.requestBody(for: request)
        urlRequest.timeoutInterval = 600
        applyHeaders(to: &urlRequest, key: key, betas: Self.betas(for: request))
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")

        for attempt in 0...2 {
            try Task.checkCancellation()
            do {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                guard let http = response as? HTTPURLResponse else { throw AnthropicError.invalidResponse }
                if let requestID = http.value(forHTTPHeaderField: "request-id") {
                    Self.logger.notice("messages request_id=\(requestID, privacy: .public) status=\(http.statusCode)")
                }
                guard (200...299).contains(http.statusCode) else {
                    let message = errorMessage(from: try await readAll(bytes))
                    if attempt < 2 && Self.retryableStatuses.contains(http.statusCode) {
                        try await sleep(Self.retryDelay(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "retry-after")))
                        continue
                    }
                    throw AnthropicError.httpError(http.statusCode, message)
                }
                return try await consumeStream(bytes, requestedModel: request.model, onEvent: onEvent)
            } catch {
                throw Self.mapped(error)
            }
        }
        throw AnthropicError.invalidResponse
    }

    nonisolated static func betas(for request: AnthropicRequest) -> [String] {
        var betas: [String] = []
        if request.adaptiveThinking { betas.append(thinkingBindingBeta) }
        if request.serverFallback { betas.append(defaultFallbackBeta) }
        return betas
    }

    /// The request body in a fixed key order, with every block's JSON spliced in verbatim.
    nonisolated static func requestBody(for request: AnthropicRequest) -> Data {
        var fields: [(String, String)] = [
            ("model", AnthropicJSON.string(request.model)),
            ("max_tokens", String(request.maxTokens)),
            ("stream", "true"),
            ("system", AnthropicJSON.array([AnthropicBlock.text(request.system).json])),
            ("messages", AnthropicJSON.array(request.messages.map { message in
                AnthropicJSON.object([
                    ("role", AnthropicJSON.string(message.role)),
                    ("content", AnthropicJSON.array(message.content.map(\.json))),
                ])
            })),
        ]
        if !request.tools.isEmpty {
            fields.append(("tools", AnthropicJSON.array(request.tools.map(toolJSON))))
        }
        if request.adaptiveThinking {
            fields.append(("thinking", #"{"block_binding":{"prefix_mismatch_behavior":"drop_block"},"display":"summarized","type":"adaptive"}"#))
        }
        if let effort = request.effort {
            fields.append(("output_config", AnthropicJSON.object([("effort", AnthropicJSON.string(effort.rawValue))])))
        }
        fields.append(("cache_control", #"{"type":"ephemeral"}"#))
        if request.serverFallback {
            fields.append(("fallbacks", #""default""#))
        }
        return Data(AnthropicJSON.object(fields).utf8)
    }

    nonisolated static func toolJSON(_ tool: LLMToolDefinition) -> String {
        struct Wire: Encodable {
            let description: String
            let eager_input_streaming = true
            let input_schema: LLMJSONValue
            let name: String
            let strict: Bool?
        }
        return AnthropicJSON.encode(Wire(description: tool.description, input_schema: tool.parameters, name: tool.name, strict: tool.strict)) ?? "{}"
    }

    private nonisolated static func retryDelay(attempt: Int, retryAfter: String?) -> Duration {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return .milliseconds(Int(min(seconds, maxRetryAfterSeconds) * 1000))
        }
        return .seconds(attempt == 0 ? 1 : 2)
    }

    // MARK: - Stream

    private struct StreamEvent: Decodable {
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: AnthropicUsage?
            let inputTransformations: [LLMJSONValue]?
            enum CodingKeys: String, CodingKey {
                case id, model, usage
                case inputTransformations = "input_transformations"
            }
        }

        struct StopDetails: Decodable {
            let category: String?
            let explanation: String?
        }

        struct Delta: Decodable {
            let type: String?
            let text: String?
            let thinking: String?
            let signature: String?
            let partialJSON: String?
            let stopReason: String?
            let stopDetails: StopDetails?
            let inputTransformations: [LLMJSONValue]?
            enum CodingKeys: String, CodingKey {
                case type, text, thinking, signature
                case partialJSON = "partial_json"
                case stopReason = "stop_reason"
                case stopDetails = "stop_details"
                case inputTransformations = "input_transformations"
            }
        }

        struct ErrorBody: Decodable {
            let type: String?
            let message: String?
        }

        let type: String
        let index: Int?
        let message: Message?
        let contentBlock: LLMJSONValue?
        let delta: Delta?
        let usage: AnthropicUsage?
        let inputTransformations: [LLMJSONValue]?
        let error: ErrorBody?

        enum CodingKeys: String, CodingKey {
            case type, index, message, delta, usage, error
            case contentBlock = "content_block"
            case inputTransformations = "input_transformations"
        }
    }

    struct StreamedBlock: Equatable {
        var type: String
        var start: [String: LLMJSONValue]
        var text = ""
        var thinking = ""
        var signature = ""
        var partialJSON = ""
        var sawInputDelta = false

        init(start: [String: LLMJSONValue]) {
            self.start = start
            if case let .string(type)? = start["type"] { self.type = type } else { self.type = "" }
            if case let .string(text)? = start["text"] { self.text = text }
            if case let .string(thinking)? = start["thinking"] { self.thinking = thinking }
            if case let .string(signature)? = start["signature"] { self.signature = signature }
        }
    }

    private func consumeStream(
        _ bytes: URLSession.AsyncBytes,
        requestedModel: String,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> AnthropicResponse {
        var decoder = ServerSentEventDecoder()
        var messageID: String?
        var model: String?
        var usage: AnthropicUsage?
        var transformations: [LLMJSONValue] = []
        var blocks: [Int: StreamedBlock] = [:]
        var stopReason: String?
        var stopDetails: StreamEvent.StopDetails?
        var sawMessageStop = false

        func handle(_ payload: String) throws {
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else {
                throw AnthropicError.invalidResponse
            }
            switch event.type {
            case "message_start":
                messageID = event.message?.id ?? messageID
                model = event.message?.model ?? model
                if let start = event.message?.usage { usage = start }
                if let list = event.message?.inputTransformations { transformations = list }
            case "content_block_start":
                guard let index = event.index, case let .object(start)? = event.contentBlock else {
                    throw AnthropicError.invalidResponse
                }
                blocks[index] = StreamedBlock(start: start)
            case "content_block_delta":
                guard let index = event.index, var block = blocks[index], let delta = event.delta else {
                    throw AnthropicError.invalidResponse
                }
                switch delta.type {
                case "text_delta":
                    let text = delta.text ?? ""
                    block.text += text
                    if !text.isEmpty { onEvent(.textDelta(text)) }
                case "thinking_delta":
                    let thinking = delta.thinking ?? ""
                    block.thinking += thinking
                    if !thinking.isEmpty { onEvent(.reasoningSummaryDelta(thinking)) }
                case "signature_delta":
                    block.signature += delta.signature ?? ""
                case "input_json_delta":
                    block.partialJSON += delta.partialJSON ?? ""
                    block.sawInputDelta = true
                default:
                    break  // citations_delta and future delta types carry nothing we replay.
                }
                blocks[index] = block
            case "message_delta":
                stopReason = event.delta?.stopReason ?? stopReason
                stopDetails = event.delta?.stopDetails ?? stopDetails
                if let delta = event.usage {
                    if usage == nil { usage = delta } else { usage?.merge(delta) }
                }
                if let list = event.inputTransformations ?? event.delta?.inputTransformations { transformations = list }
            case "message_stop":
                sawMessageStop = true
            case "error":
                throw AnthropicError.streamError(event.error?.message ?? event.error?.type ?? "Unknown error")
            default:
                break  // ping, content_block_stop, and event types added later.
            }
        }

        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                if let payload = try decoder.consume(byte) { try handle(payload) }
            }
            if let payload = try decoder.finish() { try handle(payload) }
        } catch is ServerSentEventDecoder.DecodingError {
            throw AnthropicError.invalidResponse
        }

        guard sawMessageStop, let messageID, let stopReason else { throw AnthropicError.invalidResponse }
        let response = try Self.assemble(
            id: messageID,
            model: model ?? requestedModel,
            blocks: blocks.sorted { $0.key < $1.key }.map(\.value),
            stopReason: stopReason,
            refusal: stopReason == "refusal" ? (stopDetails?.category, stopDetails?.explanation) : nil,
            usage: usage,
            inputTransformations: transformations
        )
        if !response.text.isEmpty { onEvent(.textDone(response.text)) }
        if !response.reasoning.isEmpty { onEvent(.reasoningSummaryDone(response.reasoning)) }
        return response
    }

    /// Builds the response from the streamed blocks, applying the stop reason and the fallback
    /// echo rule: blocks before the last `fallback` block keep only their text.
    nonisolated static func assemble(
        id: String,
        model: String,
        blocks: [StreamedBlock],
        stopReason: String,
        refusal: (category: String?, explanation: String?)?,
        usage: AnthropicUsage?,
        inputTransformations: [LLMJSONValue]
    ) throws -> AnthropicResponse {
        switch stopReason {
        case "end_turn", "stop_sequence", "tool_use":
            break
        case "max_tokens", "model_context_window_exceeded":
            throw AnthropicError.incompleteResponse
        case "refusal":
            throw AnthropicError.refused(category: refusal?.category, explanation: refusal?.explanation)
        default:
            throw AnthropicError.invalidResponse
        }

        let boundary = blocks.lastIndex { $0.type == "fallback" } ?? -1
        var content: [AnthropicBlock] = []
        var text = ""
        var reasoning = ""
        var toolCalls: [LLMToolCall] = []
        for (position, block) in blocks.enumerated() {
            let beforeBoundary = position < boundary
            switch block.type {
            case "text":
                text += block.text
                content.append(.text(block.text))
            case "thinking":
                guard !beforeBoundary else { continue }
                reasoning += block.thinking
                content.append(AnthropicBlock(json: AnthropicJSON.object([
                    ("signature", AnthropicJSON.string(block.signature)),
                    ("thinking", AnthropicJSON.string(block.thinking)),
                    ("type", #""thinking""#),
                ])))
            case "tool_use":
                guard !beforeBoundary, stopReason == "tool_use" else { continue }
                guard case let .string(toolID)? = block.start["id"], !toolID.isEmpty,
                      case let .string(name)? = block.start["name"], !name.isEmpty else {
                    throw AnthropicError.invalidToolCall
                }
                var raw = block.sawInputDelta
                    ? block.partialJSON
                    : (block.start["input"].flatMap { AnthropicJSON.encode($0) } ?? "{}")
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { raw = "{}" }
                let isObject = raw.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } is [String: Any]
                toolCalls.append(LLMToolCall(id: toolID, name: name, arguments: raw))
                content.append(AnthropicBlock(json: AnthropicJSON.object([
                    ("id", AnthropicJSON.string(toolID)),
                    ("input", isObject ? raw : "{}"),
                    ("name", AnthropicJSON.string(name)),
                    ("type", #""tool_use""#),
                ])))
            case "fallback":
                continue
            default:
                // redacted_thinking and block types added later go back as the API sent them.
                guard !beforeBoundary else { continue }
                content.append(AnthropicBlock(json: AnthropicJSON.encode(LLMJSONValue.object(block.start)) ?? "{}"))
            }
        }

        if stopReason == "tool_use" {
            if toolCalls.isEmpty || Set(toolCalls.map(\.id)).count != toolCalls.count {
                throw AnthropicError.invalidToolCall
            }
        }
        return AnthropicResponse(
            id: id,
            model: model,
            content: content,
            text: text,
            reasoning: reasoning,
            toolCalls: toolCalls,
            stopReason: stopReason,
            usage: usage,
            inputTransformations: inputTransformations
        )
    }

    // MARK: - Helpers

    private func applyHeaders(to request: inout URLRequest, key: String, betas: [String]) {
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty {
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
    }

    private func requireKey() async throws -> String {
        let key = try await keyStore.loadAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { throw AnthropicError.missingAPIKey }
        return key
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw AnthropicError.httpError(http.statusCode, errorMessage(from: data))
        }
    }

    private func errorMessage(from data: Data) -> String {
        let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data).error?.message) ?? "Request failed"
        return String(message.prefix(500))
    }

    private func readAll(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count > 4_000_000 { throw AnthropicError.invalidResponse }
        }
        return data
    }

    private nonisolated static func mapped(_ error: Error) -> Error {
        switch error {
        case is CancellationError:
            return CancellationError()
        case let error as URLError where error.code == .cancelled:
            return CancellationError()
        case let error as AnthropicError:
            return error
        case is DecodingError:
            return AnthropicError.invalidResponse
        default:
            return AnthropicError.transport(error.localizedDescription)
        }
    }
}
