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
        Self.logger.debug("request_start model=\(model, privacy: .public) messages=\(request.messages.count)")

        let wireRequest = ChatCompletionsWireRequest(from: request, model: model)
        let wireResponse = try await client.send(wireRequest, apiKey: "", authStyle: .none)

        Self.logger.debug("request_ok")
        return wireResponse.toLLMResponse(providerID: providerID)
    }

    func sendRequestStreaming(
        _ request: LLMRequest,
        model: String,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> LLMResponse {
        Self.logger.debug("stream_start model=\(model, privacy: .public)")

        let wireRequest = ChatCompletionsWireRequest(from: request, model: model)
        let wireResponse = try await client.sendStreaming(
            wireRequest, apiKey: "", authStyle: .none, onEvent: onEvent
        )

        Self.logger.debug("stream_ok")
        return wireResponse.toLLMResponse(providerID: providerID)
    }

    func resetConversationState() { }

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
