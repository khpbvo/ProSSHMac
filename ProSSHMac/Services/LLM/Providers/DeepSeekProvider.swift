// DeepSeekProvider.swift
// ProSSHMac
//
// DeepSeek provider using Chat Completions-compatible API.
// Supports deepseek-reasoner (R1) with native reasoning_content streaming
// and deepseek-chat (V3) for general purpose use.

import Foundation
import os.log

@MainActor
final class DeepSeekProvider: LLMProvider {
    private static let logger = Logger(subsystem: "com.prossh", category: "LLM.DeepSeek")

    let providerID = LLMProviderID.deepseek
    let displayName = "DeepSeek"

    let availableModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "deepseek-reasoner",
            displayName: "DeepSeek R1",
            providerID: .deepseek,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: true
        ),
        LLMModelInfo(
            id: "deepseek-chat",
            displayName: "DeepSeek V3",
            providerID: .deepseek,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: true
        ),
    ]

    private let client: ChatCompletionsClient
    private let apiKeyProvider: any LLMAPIKeyProviding

    var isConfigured: Bool {
        true
    }

    init(apiKeyProvider: any LLMAPIKeyProviding) {
        self.apiKeyProvider = apiKeyProvider
        self.client = ChatCompletionsClient(
            endpointURL: URL(string: "https://api.deepseek.com/chat/completions")!
        )
    }

    func sendRequest(
        _ request: LLMRequest,
        model: String
    ) async throws -> LLMResponse {
        let apiKey = try await resolveAPIKey()
        let priorMessages = try extractPriorMessages(from: request.conversationState)

        Self.logger.debug("request_start model=\(model, privacy: .public) messages=\(request.messages.count) history=\(priorMessages.count) tools=\(request.tools.count)")

        var wireRequest = ChatCompletionsWireRequest(from: request, model: model)
        wireRequest.messages = priorMessages + wireRequest.messages
        applyThinkingConfig(to: &wireRequest, model: model)

        let wireResponse = try await client.send(wireRequest, apiKey: apiKey)

        Self.logger.debug("request_ok response_id=\(wireResponse.id, privacy: .public)")

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
        let apiKey = try await resolveAPIKey()
        let priorMessages = try extractPriorMessages(from: request.conversationState)

        Self.logger.debug("stream_start model=\(model, privacy: .public) messages=\(request.messages.count) history=\(priorMessages.count)")

        var wireRequest = ChatCompletionsWireRequest(from: request, model: model)
        wireRequest.messages = priorMessages + wireRequest.messages
        applyThinkingConfig(to: &wireRequest, model: model)

        let wireResponse = try await client.sendStreaming(
            wireRequest, apiKey: apiKey, extractThinkTags: true, onEvent: onEvent
        )

        Self.logger.debug("stream_ok response_id=\(wireResponse.id, privacy: .public)")

        let updatedHistory = buildUpdatedHistory(
            prior: wireRequest.messages,
            response: wireResponse
        )
        return toLLMResponse(wireResponse: wireResponse, history: updatedHistory)
    }

    func resetConversationState() {
        // Stateless — nothing to reset
    }

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
            toolCalls: toolCallRefs,
            reasoningContent: msg.reasoningContent
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

    // MARK: - Private

    /// DeepSeek thinking mode constraints: temperature/top_p must not be set,
    /// max_tokens is required. deepseek-reasoner uses thinking by default;
    /// deepseek-chat needs the explicit thinking config.
    private func applyThinkingConfig(to request: inout ChatCompletionsWireRequest, model: String) {
        request.temperature = nil
        if model == "deepseek-chat" {
            request.thinking = ChatCompletionsThinkingConfig(type: "enabled")
        }
        if request.maxTokens == nil {
            request.maxTokens = 8192
        }
    }

    private func resolveAPIKey() async throws -> String {
        guard let key = await apiKeyProvider.apiKey(for: .deepseek),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.missingAPIKey(provider: displayName)
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
