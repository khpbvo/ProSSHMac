// LLMProvider.swift
// ProSSHMac
//
// Core protocol that every LLM provider implements.
// Provider internals (HTTP clients, wire formats, auth) stay private.

import Foundation

/// The contract every LLM provider implements.
///
/// Providers handle their own:
/// - API authentication
/// - Request/response serialization to their wire format
/// - Conversation state management (response chaining vs message accumulation)
/// - Streaming SSE parsing
///
/// The agent runner only sees `LLMRequest` → `LLMResponse` through this protocol.
@MainActor
protocol LLMProvider: Sendable {
    /// Unique identifier for this provider.
    var providerID: LLMProviderID { get }

    /// Human-readable name shown in the UI.
    var displayName: String { get }

    /// Models this provider supports.
    var availableModels: [LLMModelInfo] { get }

    /// Whether the provider is ready to accept requests.
    /// Typically: has a valid API key (or is local like Ollama).
    var isConfigured: Bool { get }

    /// Send a non-streaming request.
    ///
    /// - Parameters:
    ///   - request: Provider-agnostic request containing messages, tools, and conversation state.
    ///   - model: The wire-format model ID (e.g. "mistral-large-latest").
    /// - Returns: Provider-agnostic response with text, tool calls, and updated conversation state.
    func sendRequest(
        _ request: LLMRequest,
        model: String
    ) async throws -> LLMResponse

    /// Send a streaming request with real-time event callbacks.
    ///
    /// Default implementation falls back to non-streaming and emits a single `.textDone` event.
    ///
    /// - Parameters:
    ///   - request: Provider-agnostic request.
    ///   - model: The wire-format model ID.
    ///   - onEvent: Callback for streaming events (text deltas, reasoning, etc.).
    /// - Returns: The final aggregated response.
    func sendRequestStreaming(
        _ request: LLMRequest,
        model: String,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> LLMResponse

    /// Reset any cached conversation state (e.g. on provider switch or session clear).
    func resetConversationState()
}

// MARK: - Default Streaming Implementation

extension LLMProvider {
    func sendRequestStreaming(
        _ request: LLMRequest,
        model: String,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> LLMResponse {
        let response = try await sendRequest(request, model: model)
        if !response.text.isEmpty {
            onEvent(.textDone(response.text))
        }
        return response
    }
}

// MARK: - API Key Providing

/// Generic API key provider used by providers that need authentication.
protocol LLMAPIKeyProviding: Sendable {
    func apiKey(for provider: LLMProviderID) async -> String?
}
