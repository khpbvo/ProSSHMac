// AnthropicProvider.swift
// ProSSHMac
//
// Anthropic provider using the Messages API.
// Anthropic uses a completely different wire format from Chat Completions,
// so this file contains its own HTTP client, wire types, and SSE parser.

import Foundation
import os.log

// MARK: - Wire Types — Request

private struct AnthropicWireRequest: Encodable {
    var model: String
    var maxTokens: Int
    var system: String?
    var messages: [AnthropicWireMessage]
    var tools: [AnthropicWireTool]?
    var stream: Bool?
    var thinking: AnthropicThinkingConfig?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, stream, thinking
        case maxTokens = "max_tokens"
    }
}

private struct AnthropicThinkingConfig: Encodable {
    var type: String = "enabled"
    var budgetTokens: Int

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

struct AnthropicWireMessage: Codable {
    var role: String
    var content: AnthropicContent
}

/// Polymorphic content: encodes as string for simple text, array for content blocks.
enum AnthropicContent: Codable {
    case text(String)
    case blocks([AnthropicContentBlock])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
            return
        }
        if let blocks = try? container.decode([AnthropicContentBlock].self) {
            self = .blocks(blocks)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected String or [AnthropicContentBlock]"
        )
    }
}

struct AnthropicContentBlock: Codable {
    var type: String
    var text: String?
    var id: String?
    var name: String?
    var input: LLMJSONValue?
    var toolUseId: String?
    var content: String?

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content
        case toolUseId = "tool_use_id"
    }
}

private struct AnthropicWireTool: Encodable {
    var name: String
    var description: String
    var inputSchema: LLMJSONValue

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

// MARK: - Wire Types — Response

private struct AnthropicWireResponse: Decodable {
    var id: String
    var type: String
    var role: String
    var content: [AnthropicResponseContentBlock]
    var model: String
    var stopReason: String?
    var usage: AnthropicUsage?

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, model, usage
        case stopReason = "stop_reason"
    }
}

private struct AnthropicResponseContentBlock: Decodable {
    var type: String
    var text: String?
    var id: String?
    var name: String?
    var input: LLMJSONValue?
    var thinking: String?
}

private struct AnthropicUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

private struct AnthropicWireError: Decodable {
    struct ErrorBody: Decodable { var type: String; var message: String }
    var error: ErrorBody
}

// MARK: - Wire Types — Streaming SSE

private struct AnthropicStreamEventType: Decodable {
    var type: String
}

private struct AnthropicStreamMessageStart: Decodable {
    var type: String
    var message: AnthropicWireResponse
}

private struct AnthropicStreamContentBlockStart: Decodable {
    var type: String
    var index: Int
    var contentBlock: AnthropicStreamContentBlock

    enum CodingKeys: String, CodingKey {
        case type, index
        case contentBlock = "content_block"
    }
}

private struct AnthropicStreamContentBlock: Decodable {
    var type: String
    var id: String?
    var name: String?
}

private struct AnthropicStreamContentBlockDelta: Decodable {
    var type: String
    var index: Int
    var delta: AnthropicStreamDelta
}

private struct AnthropicStreamDelta: Decodable {
    var type: String
    var text: String?
    var partialJson: String?
    var thinking: String?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking
        case partialJson = "partial_json"
    }
}

private struct AnthropicStreamContentBlockStop: Decodable {
    var type: String
    var index: Int
}

private struct AnthropicStreamMessageDelta: Decodable {
    var type: String
    var delta: AnthropicMessageDeltaPayload
}

private struct AnthropicMessageDeltaPayload: Decodable {
    var stopReason: String?

    enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
    }
}

// MARK: - Provider

@MainActor
final class AnthropicProvider: LLMProvider {
    private static let logger = Logger(subsystem: "com.prossh", category: "LLM.Anthropic")

    let providerID = LLMProviderID.anthropic
    let displayName = "Anthropic"

    let availableModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "claude-opus-4-6",
            displayName: "Claude Opus 4.6",
            providerID: .anthropic,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: true
        ),
        LLMModelInfo(
            id: "claude-sonnet-4-6",
            displayName: "Claude Sonnet 4.6",
            providerID: .anthropic,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: true
        ),
        LLMModelInfo(
            id: "claude-haiku-4-5-20251001",
            displayName: "Claude Haiku 4.5",
            providerID: .anthropic,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: false
        ),
    ]

    private let apiKeyProvider: any LLMAPIKeyProviding
    private let session: URLSession
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    private static let defaultMaxTokens = 16384
    private static let thinkingBudgetTokens = 10000

    var isConfigured: Bool {
        // Same pattern as Mistral: optimistically return true.
        // sendRequest will throw .missingAPIKey if the key is absent.
        true
    }

    init(apiKeyProvider: any LLMAPIKeyProviding, session: URLSession = .shared) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    // MARK: - LLMProvider

    func sendRequest(
        _ request: LLMRequest,
        model: String
    ) async throws -> LLMResponse {
        let apiKey = try await resolveAPIKey()
        let priorMessages = try extractPriorMessages(from: request.conversationState)

        Self.logger.debug("request_start model=\(model, privacy: .public) messages=\(request.messages.count) history=\(priorMessages.count) tools=\(request.tools.count)")

        let wireRequest = buildWireRequest(from: request, model: model, priorMessages: priorMessages, stream: false)

        let bodyData = try JSONEncoder().encode(wireRequest)
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.timeoutInterval = 60

        let (responseData, response) = try await session.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let msg = extractErrorMessage(from: responseData)
            throw LLMProviderError.httpError(statusCode: http.statusCode, message: msg)
        }

        let wireResponse: AnthropicWireResponse
        do {
            wireResponse = try JSONDecoder().decode(AnthropicWireResponse.self, from: responseData)
        } catch {
            throw LLMProviderError.decodingFailure(error.localizedDescription)
        }

        Self.logger.debug("request_ok response_id=\(wireResponse.id, privacy: .public)")

        let updatedHistory = buildUpdatedHistory(
            prior: priorMessages,
            request: request,
            wireResponse: wireResponse
        )
        return toLLMResponse(wireResponse: wireResponse, history: updatedHistory)
    }

    func sendRequestStreaming(
        _ request: LLMRequest,
        model: String,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> LLMResponse {
        let apiKey = try await resolveAPIKey()
        let priorMessages = try extractPriorMessages(from: request.conversationState)

        Self.logger.debug("stream_start model=\(model, privacy: .public) messages=\(request.messages.count) history=\(priorMessages.count)")

        let wireRequest = buildWireRequest(from: request, model: model, priorMessages: priorMessages, stream: true)

        let bodyData = try JSONEncoder().encode(wireRequest)
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.timeoutInterval = 120

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LLMProviderError.httpError(statusCode: status, message: "Streaming request failed")
        }

        // Per-block streaming state
        var responseID = ""
        var blockTypes: [Int: String] = [:]
        var blockIDs: [Int: String] = [:]
        var blockNames: [Int: String] = [:]
        var accumulatedText = ""
        var accumulatedThinking = ""
        var accumulatedToolInputs: [Int: String] = [:]
        var stopReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { continue }
            guard let jsonData = payload.data(using: .utf8) else { continue }

            guard let eventType = try? JSONDecoder().decode(AnthropicStreamEventType.self, from: jsonData) else {
                continue
            }

            switch eventType.type {
            case "message_start":
                if let parsed = try? JSONDecoder().decode(AnthropicStreamMessageStart.self, from: jsonData) {
                    responseID = parsed.message.id
                }

            case "content_block_start":
                if let parsed = try? JSONDecoder().decode(AnthropicStreamContentBlockStart.self, from: jsonData) {
                    blockTypes[parsed.index] = parsed.contentBlock.type
                    if let id = parsed.contentBlock.id {
                        blockIDs[parsed.index] = id
                    }
                    if let name = parsed.contentBlock.name {
                        blockNames[parsed.index] = name
                    }
                }

            case "content_block_delta":
                if let parsed = try? JSONDecoder().decode(AnthropicStreamContentBlockDelta.self, from: jsonData) {
                    switch parsed.delta.type {
                    case "text_delta":
                        if let text = parsed.delta.text {
                            accumulatedText += text
                            onEvent(.textDelta(text))
                        }
                    case "thinking_delta":
                        if let thinking = parsed.delta.thinking {
                            accumulatedThinking += thinking
                            onEvent(.reasoningDelta(thinking))
                        }
                    case "input_json_delta":
                        if let partialJson = parsed.delta.partialJson {
                            accumulatedToolInputs[parsed.index, default: ""] += partialJson
                        }
                    default:
                        break
                    }
                }

            case "content_block_stop":
                if let parsed = try? JSONDecoder().decode(AnthropicStreamContentBlockStop.self, from: jsonData) {
                    if blockTypes[parsed.index] == "thinking" && !accumulatedThinking.isEmpty {
                        onEvent(.reasoningDone(accumulatedThinking))
                    }
                }

            case "message_delta":
                if let parsed = try? JSONDecoder().decode(AnthropicStreamMessageDelta.self, from: jsonData) {
                    stopReason = parsed.delta.stopReason
                }

            case "message_stop":
                break

            default:
                break
            }
        }

        if !accumulatedText.isEmpty {
            onEvent(.textDone(accumulatedText))
        }

        // Build synthetic AnthropicWireResponse from accumulated stream data
        var contentBlocks: [AnthropicResponseContentBlock] = []

        if !accumulatedText.isEmpty {
            contentBlocks.append(AnthropicResponseContentBlock(
                type: "text", text: accumulatedText
            ))
        }

        for (index, inputJson) in accumulatedToolInputs.sorted(by: { $0.key < $1.key }) {
            let parsedInput = Self.parseJSONValue(inputJson)
            contentBlocks.append(AnthropicResponseContentBlock(
                type: "tool_use",
                id: blockIDs[index],
                name: blockNames[index],
                input: parsedInput
            ))
        }

        let syntheticResponse = AnthropicWireResponse(
            id: responseID,
            type: "message",
            role: "assistant",
            content: contentBlocks,
            model: model,
            stopReason: stopReason
        )

        Self.logger.debug("stream_ok response_id=\(responseID, privacy: .public)")

        let updatedHistory = buildUpdatedHistory(
            prior: priorMessages,
            request: request,
            wireResponse: syntheticResponse
        )
        return toLLMResponse(wireResponse: syntheticResponse, history: updatedHistory)
    }

    func resetConversationState() {
        // Stateless — nothing to reset
    }

    // MARK: - Request Building

    private func buildWireRequest(
        from request: LLMRequest,
        model: String,
        priorMessages: [AnthropicWireMessage],
        stream: Bool
    ) -> AnthropicWireRequest {
        // 1. Extract system messages → top-level system string
        let systemText = request.messages
            .filter { $0.role == .system || $0.role == .developer }
            .map(\.content)
            .joined(separator: "\n\n")

        // 2. Map non-system messages → AnthropicWireMessage
        var wireMessages = priorMessages

        for msg in request.messages where msg.role != .system && msg.role != .developer {
            let role = msg.role == .assistant ? "assistant" : "user"
            wireMessages.append(AnthropicWireMessage(
                role: role,
                content: .text(msg.content)
            ))
        }

        // 3. Map tool outputs → tool_result content blocks in a "user" message
        if !request.toolOutputs.isEmpty {
            let resultBlocks = request.toolOutputs.map { output in
                AnthropicContentBlock(
                    type: "tool_result",
                    toolUseId: output.callID,
                    content: output.output
                )
            }
            wireMessages.append(AnthropicWireMessage(
                role: "user",
                content: .blocks(resultBlocks)
            ))
        }

        // 4. Map tool definitions
        let wireTools: [AnthropicWireTool]? = request.tools.isEmpty ? nil : request.tools.map { tool in
            AnthropicWireTool(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.parameters
            )
        }

        // 5. Determine if extended thinking should be enabled
        let modelInfo = availableModels.first { $0.id == model }
        let supportsReasoning = modelInfo?.supportsReasoning ?? false

        var thinking: AnthropicThinkingConfig?
        if supportsReasoning {
            thinking = AnthropicThinkingConfig(
                budgetTokens: Self.thinkingBudgetTokens
            )
        }

        return AnthropicWireRequest(
            model: model,
            maxTokens: Self.defaultMaxTokens,
            system: systemText.isEmpty ? nil : systemText,
            messages: wireMessages,
            tools: wireTools,
            stream: stream ? true : nil,
            thinking: thinking
        )
    }

    // MARK: - Response Translation

    private func toLLMResponse(
        wireResponse: AnthropicWireResponse,
        history: [AnthropicWireMessage]
    ) -> LLMResponse {
        // Collect text blocks
        let text = wireResponse.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()

        // Collect tool_use blocks → LLMToolCall
        let toolCalls: [LLMToolCall] = wireResponse.content
            .filter { $0.type == "tool_use" }
            .compactMap { block in
                guard let id = block.id, let name = block.name else { return nil }
                let arguments: String
                if let input = block.input {
                    arguments = AIToolDefinitions.jsonString(from: input)
                } else {
                    arguments = "{}"
                }
                return LLMToolCall(id: id, name: name, arguments: arguments)
            }

        // Pack conversation state
        let state: LLMConversationState
        if let packed = try? LLMConversationState.encoded(history, provider: providerID) {
            state = packed
        } else {
            state = .string(wireResponse.id, provider: providerID)
        }

        return LLMResponse(
            text: text,
            toolCalls: toolCalls,
            updatedConversationState: state
        )
    }

    // MARK: - Conversation History

    private func extractPriorMessages(
        from state: LLMConversationState?
    ) throws -> [AnthropicWireMessage] {
        guard let state else { return [] }
        guard state.providerID == providerID else {
            throw LLMProviderError.conversationStateMismatch(
                expected: providerID, got: state.providerID
            )
        }
        return (try? state.decoded(as: [AnthropicWireMessage].self)) ?? []
    }

    private func buildUpdatedHistory(
        prior: [AnthropicWireMessage],
        request: LLMRequest,
        wireResponse: AnthropicWireResponse
    ) -> [AnthropicWireMessage] {
        var history = prior

        // Append current request messages (non-system) that were sent
        for msg in request.messages where msg.role != .system && msg.role != .developer {
            let role = msg.role == .assistant ? "assistant" : "user"
            history.append(AnthropicWireMessage(
                role: role,
                content: .text(msg.content)
            ))
        }

        // Append tool outputs as user message with tool_result blocks
        if !request.toolOutputs.isEmpty {
            let resultBlocks = request.toolOutputs.map { output in
                AnthropicContentBlock(
                    type: "tool_result",
                    toolUseId: output.callID,
                    content: output.output
                )
            }
            history.append(AnthropicWireMessage(
                role: "user",
                content: .blocks(resultBlocks)
            ))
        }

        // Append assistant response (excluding thinking blocks from persisted history)
        let assistantBlocks = wireResponse.content
            .filter { $0.type != "thinking" }
            .map { block -> AnthropicContentBlock in
                switch block.type {
                case "text":
                    return AnthropicContentBlock(type: "text", text: block.text)
                case "tool_use":
                    return AnthropicContentBlock(
                        type: "tool_use",
                        id: block.id,
                        name: block.name,
                        input: block.input
                    )
                default:
                    return AnthropicContentBlock(type: block.type, text: block.text)
                }
            }

        if !assistantBlocks.isEmpty {
            history.append(AnthropicWireMessage(
                role: "assistant",
                content: .blocks(assistantBlocks)
            ))
        }

        return history
    }

    // MARK: - Helpers

    private func resolveAPIKey() async throws -> String {
        guard let key = await apiKeyProvider.apiKey(for: .anthropic),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.missingAPIKey(provider: displayName)
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractErrorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(AnthropicWireError.self, from: data) {
            return decoded.error.message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseJSONValue(_ jsonString: String) -> LLMJSONValue {
        guard let data = jsonString.data(using: .utf8),
              let value = try? JSONDecoder().decode(LLMJSONValue.self, from: data) else {
            return .object([:])
        }
        return value
    }
}
