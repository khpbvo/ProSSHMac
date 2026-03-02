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

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, temperature
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
    }
}

struct ChatCompletionsWireMessage: Encodable {
    var role: String
    var content: String?
    var toolCalls: [ChatCompletionsWireToolCallRef]?
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

struct ChatCompletionsWireToolCallRef: Encodable {
    var id: String
    var type: String = "function"
    var function: ChatCompletionsWireFunctionRef
}

struct ChatCompletionsWireFunctionRef: Encodable {
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

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
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
        var content: String?
        var toolCalls: [StreamToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
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

    let endpointURL: URL
    let session: URLSession

    init(endpointURL: URL, session: URLSession = .shared) {
        self.endpointURL = endpointURL
        self.session = session
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
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 60
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
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> ChatCompletionsWireResponse {
        var wireRequest = request
        wireRequest.stream = true

        let data = try JSONEncoder().encode(wireRequest)
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 120
        applyAuth(to: &urlRequest, apiKey: apiKey, style: authStyle)

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LLMProviderError.httpError(statusCode: status, message: "Streaming request failed")
        }

        var accumulatedText = ""
        var accumulatedToolCalls: [String: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }
            guard let chunkData = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(ChatCompletionsStreamChunk.self, from: chunkData)
            else { continue }

            for choice in chunk.choices {
                if let content = choice.delta.content, !content.isEmpty {
                    accumulatedText += content
                    onEvent(.textDelta(content))
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
                        toolCalls: toolCallRefs.isEmpty ? nil : toolCallRefs
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
