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

        Self.logger.debug("request_start model=\(model, privacy: .public) messages=\(request.messages.count) tools=\(request.tools.count)")

        let wireRequest = ChatCompletionsWireRequest(from: request, model: model)
        let wireResponse = try await client.send(wireRequest, apiKey: apiKey)

        Self.logger.debug("request_ok response_id=\(wireResponse.id, privacy: .public)")

        return wireResponse.toLLMResponse(providerID: providerID)
    }

    func sendRequestStreaming(
        _ request: LLMRequest,
        model: String,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> LLMResponse {
        let apiKey = try await resolveAPIKey()

        Self.logger.debug("stream_start model=\(model, privacy: .public) messages=\(request.messages.count)")

        let wireRequest = ChatCompletionsWireRequest(from: request, model: model)
        let wireResponse = try await client.sendStreaming(
            wireRequest, apiKey: apiKey, onEvent: onEvent
        )

        Self.logger.debug("stream_ok response_id=\(wireResponse.id, privacy: .public)")

        return wireResponse.toLLMResponse(providerID: providerID)
    }

    func resetConversationState() {
        // Stateless — nothing to reset
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
