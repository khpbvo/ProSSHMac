// OllamaProvider.swift
// ProSSHMac
//
// Ollama provider for local inference on MacBook Pro.
// Uses Ollama's OpenAI-compatible endpoint at localhost:11434.
// No API key needed — just needs Ollama running.

import Foundation
import Combine
import os.log

@MainActor
final class OllamaProvider: LLMProvider {
    private static let logger = Logger(subsystem: "com.prossh", category: "LLM.Ollama")

    let providerID = LLMProviderID.ollama
    let displayName = "Ollama (Local)"

    /// Dynamically populated from Ollama's /api/tags endpoint.
    /// Starts with sensible defaults for function-calling capable models.
    @Published private(set) var dynamicModels: [LLMModelInfo] = []

    var availableModels: [LLMModelInfo] {
        dynamicModels.isEmpty ? Self.fallbackModels : dynamicModels
    }

    var isConfigured: Bool {
        // Could ping Ollama to check, but that's async.
        // Just return true and let sendRequest fail gracefully.
        true
    }

    private let client: ChatCompletionsClient
    private let baseURL: URL

    init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
        self.client = ChatCompletionsClient(
            endpointURL: baseURL.appendingPathComponent("v1/chat/completions")
        )
    }

    // MARK: - Model Discovery

    /// Fetch available models from Ollama's API.
    /// Call this on app launch and when the user opens the provider settings.
    func refreshModels() async {
        let tagsURL = baseURL.appendingPathComponent("api/tags")
        do {
            let (data, response) = try await URLSession.shared.data(from: tagsURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Self.logger.warning("model_refresh_failed: non-200 response")
                return
            }

            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            dynamicModels = decoded.models.map { model in
                LLMModelInfo(
                    id: model.name,
                    displayName: model.name,
                    providerID: .ollama,
                    // Most modern Ollama models support function calling via the
                    // OpenAI-compatible endpoint, but we can't know for sure.
                    supportsFunctionCalling: true,
                    supportsStreaming: true,
                    supportsReasoning: false
                )
            }
            Self.logger.info("model_refresh_ok count=\(self.dynamicModels.count)")
        } catch {
            Self.logger.warning("model_refresh_error: \(error.localizedDescription, privacy: .public)")
            // Keep existing models or fallbacks
        }
    }

    // MARK: - LLMProvider

    func sendRequest(
        _ request: LLMRequest,
        model: String
    ) async throws -> LLMResponse {
        let priorMessages = try extractPriorMessages(from: request.conversationState)

        Self.logger.debug("request_start model=\(model, privacy: .public) messages=\(request.messages.count) history=\(priorMessages.count)")

        var wireRequest = ChatCompletionsWireRequest(from: request, model: model)
        wireRequest.messages = priorMessages + wireRequest.messages

        let wireResponse = try await client.send(wireRequest, apiKey: "", authStyle: .none)

        Self.logger.debug("request_ok")

        let updatedHistory = buildUpdatedHistory(
            prior: wireRequest.messages,
            response: wireResponse
        )
        return toLLMResponse(wireResponse: wireResponse, history: updatedHistory)
    }

    func sendRequestStreaming(
        _ request: LLMRequest,
        model: String,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> LLMResponse {
        let priorMessages = try extractPriorMessages(from: request.conversationState)

        Self.logger.debug("stream_start model=\(model, privacy: .public) messages=\(request.messages.count) history=\(priorMessages.count)")

        var wireRequest = ChatCompletionsWireRequest(from: request, model: model)
        wireRequest.messages = priorMessages + wireRequest.messages

        let wireResponse = try await client.sendStreaming(
            wireRequest, apiKey: "", authStyle: .none, extractThinkTags: true, onEvent: onEvent
        )

        Self.logger.debug("stream_ok")

        let updatedHistory = buildUpdatedHistory(
            prior: wireRequest.messages,
            response: wireResponse
        )
        return toLLMResponse(wireResponse: wireResponse, history: updatedHistory)
    }

    func resetConversationState() { }

    // MARK: - Conversation History

    private func extractPriorMessages(
        from state: LLMConversationState?
    ) throws -> [ChatCompletionsWireMessage] {
        guard let state else { return [] }
        guard state.providerID == providerID else {
            throw LLMProviderError.conversationStateMismatch(
                expected: providerID, got: state.providerID
            )
        }
        return (try? state.decoded(as: [ChatCompletionsWireMessage].self)) ?? []
    }

    private func buildUpdatedHistory(
        prior: [ChatCompletionsWireMessage],
        response: ChatCompletionsWireResponse
    ) -> [ChatCompletionsWireMessage] {
        var history = prior
        guard let choice = response.choices.first else { return history }
        let msg = choice.message
        let toolCallRefs: [ChatCompletionsWireToolCallRef]? = msg.toolCalls?.map { tc in
            ChatCompletionsWireToolCallRef(
                id: tc.id,
                type: tc.type,
                function: ChatCompletionsWireFunctionRef(
                    name: tc.function.name,
                    arguments: tc.function.arguments
                )
            )
        }
        history.append(ChatCompletionsWireMessage(
            role: msg.role,
            content: msg.content,
            toolCalls: toolCallRefs
        ))
        return history
    }

    private func toLLMResponse(
        wireResponse: ChatCompletionsWireResponse,
        history: [ChatCompletionsWireMessage]
    ) -> LLMResponse {
        let choice = wireResponse.choices.first
        let text = choice?.message.content ?? ""
        let toolCalls: [LLMToolCall] = (choice?.message.toolCalls ?? []).map { tc in
            LLMToolCall(id: tc.id, name: tc.function.name, arguments: tc.function.arguments)
        }
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

    // MARK: - Fallback Models

    private static let fallbackModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "qwen2.5-coder:32b",
            displayName: "Qwen 2.5 Coder 32B",
            providerID: .ollama,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: false
        ),
        LLMModelInfo(
            id: "llama3.1:70b",
            displayName: "Llama 3.1 70B",
            providerID: .ollama,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: false
        ),
        LLMModelInfo(
            id: "mistral:latest",
            displayName: "Mistral (Ollama)",
            providerID: .ollama,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: false
        ),
    ]
}

// MARK: - Ollama Tags API Response

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        var name: String
        var size: Int64?
        var modifiedAt: String?

        enum CodingKeys: String, CodingKey {
            case name, size
            case modifiedAt = "modified_at"
        }
    }
    var models: [Model]
}
