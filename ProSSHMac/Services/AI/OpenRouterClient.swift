import Foundation

@MainActor
protocol OpenRouterServicing: Sendable {
    func fetchModels() async throws -> [OpenRouterModel]
    func complete(
        model: String,
        messages: [OpenRouterMessage],
        tools: [LLMToolDefinition],
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> OpenRouterCompletion
}

protocol OpenRouterHTTPSessioning: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

extension URLSession: OpenRouterHTTPSessioning {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await bytes(for: request, delegate: nil)
    }
}

@MainActor
final class OpenRouterClient: OpenRouterServicing {
    private struct Tool: Encodable {
        struct Function: Encodable {
            let name: String
            let description: String
            let parameters: LLMJSONValue
        }
        let type = "function"
        let function: Function
    }

    private struct Request: Encodable {
        struct Provider: Encodable { let requireParameters = true
            enum CodingKeys: String, CodingKey { case requireParameters = "require_parameters" }
        }
        let model: String
        let messages: [OpenRouterMessage]
        let tools: [Tool]
        let stream = true
        let provider = Provider()
    }

    private struct APIErrorBody: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail?
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolFragment: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int
                    let id: String?
                    let function: Function?
                }
                let content: String?
                let reasoning: String?
                let reasoningContent: String?
                let reasoningDetails: [LLMJSONValue]?
                let toolCalls: [ToolFragment]?

                enum CodingKeys: String, CodingKey {
                    case content, reasoning
                    case reasoningContent = "reasoning_content"
                    case reasoningDetails = "reasoning_details"
                    case toolCalls = "tool_calls"
                }
            }

            let delta: Delta
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }

        struct ErrorBody: Decodable { let message: String? }
        let id: String?
        let model: String?
        let choices: [Choice]?
        let usage: OpenRouterCompletion.Usage?
        let error: ErrorBody?
    }

    private struct ToolFragments {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private let keyStore: any OpenRouterAPIKeyStoring
    private let session: any OpenRouterHTTPSessioning
    private let completionURL: URL
    private let modelsURL: URL

    init(
        keyStore: any OpenRouterAPIKeyStoring,
        session: any OpenRouterHTTPSessioning = URLSession.shared,
        completionURL: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        modelsURL: URL = URL(string: "https://openrouter.ai/api/v1/models?supported_parameters=tools&input_modalities=text&output_modalities=text")!
    ) {
        self.keyStore = keyStore
        self.session = session
        self.completionURL = completionURL
        self.modelsURL = modelsURL
    }

    func fetchModels() async throws -> [OpenRouterModel] {
        let key = try await requireKey()
        var request = URLRequest(url: modelsURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            let decoded = try JSONDecoder().decode(OpenRouterCatalogResponse.self, from: data)
            return decoded.data.filter(\.isUsableForAssistant).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenRouterError {
            throw error
        } catch is DecodingError {
            throw OpenRouterError.invalidResponse
        } catch {
            throw OpenRouterError.transport(error.localizedDescription)
        }
    }

    func complete(
        model: String,
        messages: [OpenRouterMessage],
        tools: [LLMToolDefinition],
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> OpenRouterCompletion {
        let key = try await requireKey()
        let payload = Request(
            model: model,
            messages: messages,
            tools: tools.map { Tool(function: .init(name: $0.name, description: $0.description, parameters: $0.parameters)) }
        )
        let body: Data
        do {
            body = try JSONEncoder().encode(payload)
        } catch {
            throw OpenRouterError.invalidResponse
        }
        var request = URLRequest(url: completionURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 600
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")

        for attempt in 0...2 {
            try Task.checkCancellation()
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
                if !(200...299).contains(http.statusCode) {
                    let data = try await readAll(bytes)
                    let message = errorMessage(from: data)
                    if attempt < 2 && [429, 502, 503, 504, 529].contains(http.statusCode) {
                        try await Task.sleep(for: .seconds(attempt == 0 ? 1 : 2))
                        continue
                    }
                    throw OpenRouterError.httpError(http.statusCode, message)
                }
                if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true {
                    let data = try await readAll(bytes)
                    let completion = try JSONDecoder().decode(OpenRouterCompletion.self, from: data)
                    try validateCompletion(completion)
                    emitDoneEvents(for: completion.choices[0].message, onEvent: onEvent)
                    return completion
                }
                return try await consumeStream(bytes, selectedModel: model, onEvent: onEvent)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as OpenRouterError {
                throw error
            } catch is DecodingError {
                throw OpenRouterError.invalidResponse
            } catch {
                throw OpenRouterError.transport(error.localizedDescription)
            }
        }
        throw OpenRouterError.invalidResponse
    }

    private func consumeStream(
        _ bytes: URLSession.AsyncBytes,
        selectedModel: String,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> OpenRouterCompletion {
        var responseID: String?
        var routedModel: String?
        var text = ""
        var reasoning = ""
        var reasoningSummary = ""
        var details: [LLMJSONValue] = []
        var toolFragments: [Int: ToolFragments] = [:]
        var usage: OpenRouterCompletion.Usage?
        var finishReason: String?
        var sawDone = false
        var dataLines: [String] = []
        var lineBytes = Data()
        var lastWasCR = false

        func consumeEvent() throws {
            guard !dataLines.isEmpty else { return }
            let dataText = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            if dataText == "[DONE]" { sawDone = true; return }
            guard let data = dataText.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                throw OpenRouterError.invalidResponse
            }
            if let error = chunk.error {
                throw OpenRouterError.streamError(error.message ?? "Unknown error")
            }
            responseID = chunk.id ?? responseID
            routedModel = chunk.model ?? routedModel
            usage = chunk.usage ?? usage
            for choice in chunk.choices ?? [] {
                finishReason = choice.finishReason ?? finishReason
                if let delta = choice.delta.content, !delta.isEmpty {
                    text += delta
                    onEvent(.textDelta(delta))
                }
                if let delta = deltaReasoning(choice.delta), !delta.isEmpty {
                    reasoning += delta
                    onEvent(.reasoningDelta(delta))
                }
                for detail in choice.delta.reasoningDetails ?? [] {
                    details.append(detail)
                    if case let .object(fields) = detail,
                       case let .string(kind)? = fields["type"],
                       kind == "reasoning.summary",
                       case let .string(summary)? = fields["summary"] {
                        reasoningSummary += summary
                        onEvent(.reasoningSummaryDelta(summary))
                    }
                }
                for fragment in choice.delta.toolCalls ?? [] {
                    var current = toolFragments[fragment.index] ?? ToolFragments()
                    if let id = fragment.id { current.id += id }
                    if let name = fragment.function?.name { current.name += name }
                    if let arguments = fragment.function?.arguments { current.arguments += arguments }
                    toolFragments[fragment.index] = current
                }
            }
        }

        func consumeLine() throws {
            guard let line = String(data: lineBytes, encoding: .utf8) else {
                throw OpenRouterError.invalidResponse
            }
            lineBytes.removeAll(keepingCapacity: true)
            if line.isEmpty {
                try consumeEvent()
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 13 {
                try consumeLine()
                lastWasCR = true
            } else if byte == 10 {
                if !lastWasCR { try consumeLine() }
                lastWasCR = false
            } else {
                lastWasCR = false
                lineBytes.append(byte)
                if lineBytes.count > 4_000_000 { throw OpenRouterError.invalidResponse }
            }
        }
        if !lineBytes.isEmpty { try consumeLine() }
        try consumeEvent()
        guard sawDone, let responseID, let finishReason else { throw OpenRouterError.invalidResponse }
        if finishReason == "length" { throw OpenRouterError.incompleteResponse }
        if finishReason == "error" { throw OpenRouterError.streamError("Generation stopped with an error") }
        guard finishReason == "stop" || finishReason == "tool_calls" else { throw OpenRouterError.invalidResponse }

        let toolCalls = try toolFragments.sorted { $0.key < $1.key }.map { _, fragment -> OpenRouterToolCall in
            guard !fragment.id.isEmpty, !fragment.name.isEmpty,
                  let arguments = fragment.arguments.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: arguments)) is [String: Any] else {
                throw OpenRouterError.invalidToolCall
            }
            return OpenRouterToolCall(id: fragment.id, function: .init(name: fragment.name, arguments: fragment.arguments))
        }
        if finishReason == "tool_calls" && toolCalls.isEmpty { throw OpenRouterError.invalidToolCall }
        if Set(toolCalls.map(\.id)).count != toolCalls.count { throw OpenRouterError.invalidToolCall }
        if toolCalls.isEmpty && text.isEmpty { throw OpenRouterError.invalidResponse }
        let message = OpenRouterMessage(
            role: "assistant",
            content: text.isEmpty ? nil : text,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            reasoningDetails: details.isEmpty ? nil : details,
            reasoning: details.isEmpty && !reasoning.isEmpty ? reasoning : nil
        )
        emitDoneEvents(for: message, onEvent: onEvent)
        if !details.isEmpty && !reasoning.isEmpty { onEvent(.reasoningDone(reasoning)) }
        if !reasoningSummary.isEmpty { onEvent(.reasoningSummaryDone(reasoningSummary)) }
        return OpenRouterCompletion(
            id: responseID,
            model: routedModel ?? selectedModel,
            choices: [.init(message: message, finishReason: finishReason)],
            usage: usage
        )
    }

    private func deltaReasoning(_ delta: StreamChunk.Choice.Delta) -> String? {
        if let text = delta.reasoning ?? delta.reasoningContent { return text }
        return nil
    }

    private func emitDoneEvents(
        for message: OpenRouterMessage,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) {
        if let text = message.content, !text.isEmpty { onEvent(.textDone(text)) }
        if let text = message.reasoning, !text.isEmpty { onEvent(.reasoningDone(text)) }
    }

    private func validateCompletion(_ completion: OpenRouterCompletion) throws {
        guard let choice = completion.choices.first else { throw OpenRouterError.invalidResponse }
        if choice.finishReason == "length" { throw OpenRouterError.incompleteResponse }
        if choice.finishReason == "error" { throw OpenRouterError.streamError("Generation stopped with an error") }
        guard choice.message.role == "assistant",
              choice.finishReason == "stop" || choice.finishReason == "tool_calls" else {
            throw OpenRouterError.invalidResponse
        }
        if choice.finishReason == "tool_calls" && (choice.message.toolCalls ?? []).isEmpty {
            throw OpenRouterError.invalidToolCall
        }
        let calls = choice.message.toolCalls ?? []
        if Set(calls.map(\.id)).count != calls.count { throw OpenRouterError.invalidToolCall }
        if (choice.message.toolCalls ?? []).isEmpty && (choice.message.content ?? "").isEmpty {
            throw OpenRouterError.invalidResponse
        }
        for call in calls {
            guard !call.id.isEmpty, !call.function.name.isEmpty,
                  let data = call.function.arguments.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw OpenRouterError.invalidToolCall
            }
        }
    }

    private func requireKey() async throws -> String {
        let key = try await keyStore.loadAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { throw OpenRouterError.missingAPIKey }
        return key
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw OpenRouterError.httpError(http.statusCode, errorMessage(from: data))
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
            if data.count > 4_000_000 { throw OpenRouterError.invalidResponse }
        }
        return data
    }
}
