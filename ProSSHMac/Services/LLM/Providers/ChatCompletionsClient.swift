// ChatCompletionsClient.swift
// ProSSHMac
//
// Shared HTTP client for providers that speak the Chat Completions wire format.
// Used by MistralProvider and OllamaProvider. Could also serve OpenAI's
// /v1/chat/completions endpoint if you ever switch away from Responses API.

import Foundation
import os.log

// MARK: - Wire Types (internal to this client, never leaked to AIAgentRunner)

struct ChatCompletionsWireRequest: Encodable {
    var model: String
    var messages: [ChatCompletionsWireMessage]
    var tools: [ChatCompletionsWireTool]?
    var toolChoice: String?    // "auto", "none", or "required"
    var stream: Bool?
    var temperature: Double?
    var maxTokens: Int?
    /// DeepSeek thinking mode: `{"type": "enabled"}` activates chain-of-thought on deepseek-chat.
    var thinking: ChatCompletionsThinkingConfig?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, temperature, thinking
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
    }
}

struct ChatCompletionsThinkingConfig: Encodable {
    var type: String  // "enabled" or "disabled"
}

struct ChatCompletionsWireMessage: Codable {
    var role: String
    var content: String?
    var toolCalls: [ChatCompletionsWireToolCallRef]?
    var toolCallID: String?
    /// DeepSeek thinking mode requires assistant messages to include reasoning_content.
    var reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningContent = "reasoning_content"
    }
}

struct ChatCompletionsWireToolCallRef: Codable {
    var id: String
    var type: String = "function"
    var function: ChatCompletionsWireFunctionRef
}

struct ChatCompletionsWireFunctionRef: Codable {
    var name: String
    var arguments: String
}

struct ChatCompletionsWireTool: Encodable {
    var type: String = "function"
    var function: ChatCompletionsWireFunction
}

struct ChatCompletionsWireFunction: Encodable {
    var name: String
    var description: String
    var parameters: LLMJSONValue
}

// MARK: - Response Wire Types

struct ChatCompletionsWireResponse: Decodable {
    var id: String
    var choices: [ChatCompletionsWireChoice]

    struct ChatCompletionsWireChoice: Decodable {
        var message: ChatCompletionsWireResponseMessage
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct ChatCompletionsWireResponseMessage: Decodable {
        var role: String
        var content: String?
        var toolCalls: [ChatCompletionsWireResponseToolCall]?
        var reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case reasoningContent = "reasoning_content"
        }
    }

    struct ChatCompletionsWireResponseToolCall: Decodable {
        var id: String
        var type: String
        var function: ChatCompletionsWireResponseFunction
    }

    struct ChatCompletionsWireResponseFunction: Decodable {
        var name: String
        var arguments: String
    }
}

// MARK: - Streaming Wire Types

struct ChatCompletionsStreamChunk: Decodable {
    var choices: [StreamChoice]

    struct StreamChoice: Decodable {
        var delta: StreamDelta
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct StreamDelta: Decodable {
        /// Text content (string for OpenAI/Ollama, extracted from structured blocks for Mistral)
        var content: String?
        /// Reasoning from Ollama ("reasoning") or DeepSeek ("reasoning_content") wire field
        var reasoning: String?
        /// Thinking extracted from Mistral Magistral structured content blocks
        var thinkingContent: String?
        var toolCalls: [StreamToolCall]?

        enum CodingKeys: String, CodingKey {
            case content, reasoning
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            toolCalls = try container.decodeIfPresent([StreamToolCall].self, forKey: .toolCalls)

            // Ollama uses "reasoning", DeepSeek API uses "reasoning_content"
            let r1 = try container.decodeIfPresent(String.self, forKey: .reasoning)
            let r2 = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
            reasoning = r1 ?? r2

            // content: string (OpenAI/Ollama) or array of typed blocks (Mistral Magistral)
            if let stringContent = try? container.decodeIfPresent(String.self, forKey: .content) {
                content = stringContent
                thinkingContent = nil
            } else if let blocks = try? container.decodeIfPresent([MistralContentBlock].self, forKey: .content) {
                var textParts: [String] = []
                var thinkParts: [String] = []
                for block in blocks {
                    if block.type == "text", let t = block.text {
                        textParts.append(t)
                    } else if block.type == "thinking" {
                        for tb in block.thinking ?? [] {
                            if let t = tb.text { thinkParts.append(t) }
                        }
                    }
                }
                content = textParts.isEmpty ? nil : textParts.joined()
                thinkingContent = thinkParts.isEmpty ? nil : thinkParts.joined()
            } else {
                content = nil
                thinkingContent = nil
            }
        }

        struct MistralContentBlock: Decodable {
            var type: String
            var text: String?
            var thinking: [MistralThinkingBlock]?
        }

        struct MistralThinkingBlock: Decodable {
            var type: String?
            var text: String?
        }
    }

    struct StreamToolCall: Decodable {
        var index: Int
        var id: String?
        var function: StreamFunction?
    }

    struct StreamFunction: Decodable {
        var name: String?
        var arguments: String?
    }
}

// MARK: - Error Wire Type

struct ChatCompletionsWireError: Decodable {
    struct ErrorBody: Decodable {
        var message: String
    }
    var error: ErrorBody
}

// MARK: - Client

final class ChatCompletionsClient: Sendable {
    private static let logger = Logger(subsystem: "com.prossh", category: "LLM.ChatCompletions")

    /// When true, every outgoing request payload is written to ~/Desktop/llm_request_log/
    /// with a timestamped filename. API keys are redacted. Enable for security auditing.
    static let debugLogRequests = true

    let endpointURL: URL
    let session: URLSession

    init(endpointURL: URL, session: URLSession = .shared) {
        self.endpointURL = endpointURL
        self.session = session
    }

    private func logRequestPayload(_ data: Data, endpoint: URL, streaming: Bool) {
        guard Self.debugLogRequests else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/llm_request_log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let mode = streaming ? "stream" : "sync"
        let filename = "\(ts)_\(mode)_\(endpoint.host ?? "unknown").json"
        let fileURL = dir.appendingPathComponent(filename)

        // Pretty-print the JSON for readability
        var payload: String
        if let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: pretty, encoding: .utf8) {
            payload = str
        } else {
            payload = String(data: data, encoding: .utf8) ?? "<binary>"
        }

        // Prepend metadata
        let header = """
        // ENDPOINT: \(endpoint.absoluteString)
        // TIMESTAMP: \(ts)
        // MODE: \(mode)
        // PAYLOAD_BYTES: \(data.count)
        // ---

        """
        try? (header + payload).data(using: .utf8)?.write(to: fileURL, options: .atomic)
        Self.logger.info("DEBUG_LOG wrote \(data.count) bytes to \(fileURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Non-Streaming

    func send(
        _ request: ChatCompletionsWireRequest,
        apiKey: String,
        authStyle: AuthStyle = .bearer
    ) async throws -> ChatCompletionsWireResponse {
        var wireRequest = request
        wireRequest.stream = false

        let data = try JSONEncoder().encode(wireRequest)
        logRequestPayload(data, endpoint: endpointURL, streaming: false)
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600
        applyAuth(to: &urlRequest, apiKey: apiKey, style: authStyle)

        let (responseData, response) = try await session.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let msg = extractErrorMessage(from: responseData)
            throw LLMProviderError.httpError(statusCode: http.statusCode, message: msg)
        }

        do {
            return try JSONDecoder().decode(ChatCompletionsWireResponse.self, from: responseData)
        } catch {
            throw LLMProviderError.decodingFailure(error.localizedDescription)
        }
    }

    // MARK: - Streaming

    func sendStreaming(
        _ request: ChatCompletionsWireRequest,
        apiKey: String,
        authStyle: AuthStyle = .bearer,
        extractThinkTags: Bool = false,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> ChatCompletionsWireResponse {
        var wireRequest = request
        wireRequest.stream = true

        let data = try JSONEncoder().encode(wireRequest)
        logRequestPayload(data, endpoint: endpointURL, streaming: true)
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600
        applyAuth(to: &urlRequest, apiKey: apiKey, style: authStyle)

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Read error body from SSE stream to surface the real API error message
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 4096 { break }
            }
            let msg = extractErrorMessage(from: Data(errorBody.utf8))
            throw LLMProviderError.httpError(statusCode: status, message: msg.isEmpty ? "Streaming request failed" : msg)
        }

        var accumulatedText = ""
        var accumulatedReasoning = ""
        var accumulatedToolCalls: [String: (id: String, name: String, arguments: String)] = [:]
        var extractor = ThinkTagExtractor()

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }
            guard let chunkData = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(ChatCompletionsStreamChunk.self, from: chunkData)
            else { continue }

            for choice in chunk.choices {
                // Native reasoning field (Ollama "reasoning" / DeepSeek "reasoning_content")
                if let reasoning = choice.delta.reasoning, !reasoning.isEmpty {
                    accumulatedReasoning += reasoning
                    onEvent(.reasoningDelta(reasoning))
                }
                // Mistral Magistral structured thinking blocks
                if let thinking = choice.delta.thinkingContent, !thinking.isEmpty {
                    accumulatedReasoning += thinking
                    onEvent(.reasoningDelta(thinking))
                }
                if let content = choice.delta.content, !content.isEmpty {
                    if extractThinkTags {
                        for output in extractor.feed(content) {
                            switch output {
                            case .text(let t):
                                accumulatedText += t
                                onEvent(.textDelta(t))
                            case .reasoningDelta(let t):
                                onEvent(.reasoningDelta(t))
                            case .reasoningDone(let t):
                                onEvent(.reasoningDone(t))
                            }
                        }
                    } else {
                        accumulatedText += content
                        onEvent(.textDelta(content))
                    }
                }
                if let toolCalls = choice.delta.toolCalls {
                    for tc in toolCalls {
                        let key = "\(tc.index)"
                        var existing = accumulatedToolCalls[key] ?? (id: "", name: "", arguments: "")
                        if let id = tc.id { existing.id = id }
                        if let name = tc.function?.name { existing.name += name }
                        if let args = tc.function?.arguments { existing.arguments += args }
                        accumulatedToolCalls[key] = existing
                    }
                }
            }
        }

        // Flush native reasoning_content accumulated across chunks
        if !accumulatedReasoning.isEmpty {
            onEvent(.reasoningDone(accumulatedReasoning))
        }

        // Flush ThinkTagExtractor buffer (for <think> tags in content)
        if extractThinkTags {
            for output in extractor.flush() {
                switch output {
                case .text(let t):
                    accumulatedText += t
                case .reasoningDelta(let t):
                    onEvent(.reasoningDelta(t))
                case .reasoningDone(let t):
                    onEvent(.reasoningDone(t))
                }
            }
        }

        if !accumulatedText.isEmpty {
            onEvent(.textDone(accumulatedText))
        }

        // Build a synthetic ChatCompletionsWireResponse from accumulated stream data
        let toolCallRefs = accumulatedToolCalls.sorted(by: { $0.key < $1.key }).map { (_, tc) in
            ChatCompletionsWireResponse.ChatCompletionsWireResponseToolCall(
                id: tc.id, type: "function",
                function: .init(name: tc.name, arguments: tc.arguments)
            )
        }

        return ChatCompletionsWireResponse(
            id: UUID().uuidString,
            choices: [
                .init(
                    message: .init(
                        role: "assistant",
                        content: accumulatedText.isEmpty ? nil : accumulatedText,
                        toolCalls: toolCallRefs.isEmpty ? nil : toolCallRefs,
                        reasoningContent: accumulatedReasoning.isEmpty ? nil : accumulatedReasoning
                    ),
                    finishReason: toolCallRefs.isEmpty ? "stop" : "tool_calls"
                )
            ]
        )
    }

    // MARK: - Auth Styles

    enum AuthStyle: Sendable {
        case bearer       // Authorization: Bearer <key> — used by Mistral, OpenAI
        case none          // No auth header — used by Ollama
    }

    private func applyAuth(to request: inout URLRequest, apiKey: String, style: AuthStyle) {
        switch style {
        case .bearer:
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .none:
            break
        }
    }
}

// MARK: - ThinkTagExtractor

private struct ThinkTagExtractor {
    enum Output {
        case text(String)
        case reasoningDelta(String)
        case reasoningDone(String)   // full accumulated thinking for this block
    }

    private static let openTag  = "<think>"
    private static let closeTag = "</think>"

    private var buffer = ""
    private var isInsideThink = false
    private var accumulatedThinking = ""

    mutating func feed(_ input: String) -> [Output] {
        buffer += input
        return drain()
    }

    mutating func flush() -> [Output] {
        guard !buffer.isEmpty else { return [] }
        var outputs: [Output] = []
        if isInsideThink {
            accumulatedThinking += buffer
            outputs.append(.reasoningDelta(buffer))
            outputs.append(.reasoningDone(accumulatedThinking))
            accumulatedThinking = ""
            isInsideThink = false
        } else {
            outputs.append(.text(buffer))
        }
        buffer = ""
        return outputs
    }

    private mutating func drain() -> [Output] {
        var outputs: [Output] = []
        while true {
            let target = isInsideThink ? Self.closeTag : Self.openTag
            if let range = buffer.range(of: target) {
                let before = String(buffer[..<range.lowerBound])
                buffer = String(buffer[range.upperBound...])
                if !before.isEmpty {
                    if isInsideThink {
                        accumulatedThinking += before
                        outputs.append(.reasoningDelta(before))
                    } else {
                        outputs.append(.text(before))
                    }
                }
                if isInsideThink {
                    outputs.append(.reasoningDone(accumulatedThinking))
                    accumulatedThinking = ""
                    isInsideThink = false
                } else {
                    isInsideThink = true
                }
            } else {
                // Hold back (tag.count - 1) chars — they might be a partial tag
                let holdback = target.count - 1
                guard buffer.count > holdback else { break }
                let safe = String(buffer.prefix(buffer.count - holdback))
                buffer = String(buffer.dropFirst(safe.count))
                if !safe.isEmpty {
                    if isInsideThink {
                        accumulatedThinking += safe
                        outputs.append(.reasoningDelta(safe))
                    } else {
                        outputs.append(.text(safe))
                    }
                }
                break
            }
        }
        return outputs
    }
}

extension ChatCompletionsClient {

    // MARK: - Helpers

    private func extractErrorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ChatCompletionsWireError.self, from: data) {
            return decoded.error.message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Translation Helpers (Wire Types ↔ LLM Types)

extension ChatCompletionsWireRequest {

    /// Build a wire request from provider-agnostic LLM types.
    init(from request: LLMRequest, model: String, messageHistory: [LLMMessage]? = nil) {
        // Build messages: conversation history + current messages + tool outputs
        var wireMessages: [ChatCompletionsWireMessage] = []

        // Include message history from conversation state if provided
        if let history = messageHistory {
            wireMessages += history.map { msg in
                ChatCompletionsWireMessage(
                    role: Self.wireRole(msg.role),
                    content: msg.content
                )
            }
        }

        // Current request messages
        wireMessages += request.messages.map { msg in
            ChatCompletionsWireMessage(
                role: Self.wireRole(msg.role),
                content: msg.content
            )
        }

        // Tool outputs → assistant tool_calls reference + tool role messages
        for output in request.toolOutputs {
            wireMessages.append(ChatCompletionsWireMessage(
                role: "tool",
                content: output.output,
                toolCallID: output.callID
            ))
        }

        // Build tools
        let wireTools: [ChatCompletionsWireTool]? = request.tools.isEmpty ? nil : request.tools.map { tool in
            ChatCompletionsWireTool(
                function: ChatCompletionsWireFunction(
                    name: tool.name,
                    description: tool.description,
                    parameters: tool.parameters
                )
            )
        }

        self.model = model
        self.messages = wireMessages
        self.tools = wireTools
        self.toolChoice = wireTools != nil ? "auto" : nil
    }

    private static func wireRole(_ role: LLMMessageRole) -> String {
        switch role {
        case .system, .developer: return "system"
        case .user:               return "user"
        case .assistant:          return "assistant"
        }
    }
}

extension ChatCompletionsWireResponse {

    /// Convert wire response to provider-agnostic LLM types.
    func toLLMResponse(providerID: LLMProviderID, existingState: LLMConversationState? = nil) -> LLMResponse {
        let choice = choices.first

        let text = choice?.message.content ?? ""

        let toolCalls: [LLMToolCall] = (choice?.message.toolCalls ?? []).map { tc in
            LLMToolCall(id: tc.id, name: tc.function.name, arguments: tc.function.arguments)
        }

        // For Chat Completions providers, conversation state is "stateless" —
        // the agent runner manages message history externally.
        // We pass back a minimal state marker.
        let state = LLMConversationState.string(id, provider: providerID)

        return LLMResponse(
            text: text,
            toolCalls: toolCalls,
            updatedConversationState: state
        )
    }
}
