// MistralProvider.swift
// ProSSHMac
//
// Mistral AI provider using Chat Completions-compatible API.
// First non-OpenAI provider — Kevin has API credits here.

import Foundation
import os.log

@MainActor
final class MistralProvider: LLMProvider {
    private static let logger = Logger(subsystem: "com.prossh", category: "LLM.Mistral")

    let providerID = LLMProviderID.mistral
    let displayName = "Mistral AI"

    let availableModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "mistral-large-latest",
            displayName: "Mistral Large",
            providerID: .mistral,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: false
        ),
        LLMModelInfo(
            id: "mistral-medium-latest",
            displayName: "Mistral Medium",
            providerID: .mistral,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: false
        ),
        LLMModelInfo(
            id: "codestral-latest",
            displayName: "Codestral",
            providerID: .mistral,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: false
        ),
        LLMModelInfo(
            id: "mistral-small-latest",
            displayName: "Mistral Small",
            providerID: .mistral,
            supportsFunctionCalling: true,
            supportsStreaming: true,
            supportsReasoning: false
        ),
    ]

    private let client: ChatCompletionsClient
    private let apiKeyProvider: any LLMAPIKeyProviding

    var isConfigured: Bool {
        // We can't check async from a sync property, so we optimistically return true.
        // sendRequest will throw .missingAPIKey if the key is absent.
        true
    }

    init(apiKeyProvider: any LLMAPIKeyProviding) {
        self.apiKeyProvider = apiKeyProvider
        self.client = ChatCompletionsClient(
            endpointURL: URL(string: "https://api.mistral.ai/v1/chat/completions")!
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

        let wireResponse = try await client.sendStreaming(
            wireRequest, apiKey: apiKey, onEvent: onEvent
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

    // MARK: - Private

    private func resolveAPIKey() async throws -> String {
        guard let key = await apiKeyProvider.apiKey(for: .mistral),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.missingAPIKey(provider: displayName)
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
