# ProSSHMac Multi-Provider LLM Architecture

## Problem

The AI integration is hardwired to OpenAI's Responses API across ~9 files.
Adding Mistral, Anthropic, and Ollama requires a provider abstraction that:

1. Doesn't leak OpenAI naming into other providers' code
2. Handles fundamentally different conversation models (response-chaining vs message-history)
3. Unifies tool calling across providers (all support function calling, but wire formats differ)
4. Manages per-provider API keys in Keychain
5. Allows runtime provider/model switching via Settings

## Proposed Directory Structure

```
ProSSHMac/Services/
├── AI/                              # KEEP AS-IS (already provider-agnostic)
│   ├── AIAgentRunner.swift          # Refactor: use LLMProvider instead of OpenAIResponsesServicing
│   ├── AIToolHandler.swift          
│   ├── AIToolDefinitions.swift      
│   └── ...
│
├── LLM/                             # NEW — Provider abstraction layer
│   ├── LLMTypes.swift               # Provider-agnostic request/response/tool types
│   ├── LLMProvider.swift            # Core protocol
│   ├── LLMProviderRegistry.swift    # Runtime provider selection + factory
│   ├── LLMAPIKeyStore.swift         # Generic Keychain store (parameterized by provider)
│   │
│   └── Providers/
│       ├── OpenAIProvider.swift      # Wraps existing Responses API code
│       ├── OpenAIResponsesService.swift        # MOVED from Services/ (internals unchanged)
│       ├── OpenAIResponsesService+Streaming.swift
│       ├── OpenAIResponsesStreamAccumulator.swift
│       ├── OpenAIResponsesTypes.swift
│       ├── OpenAIResponsesPayloadTypes.swift
│       │
│       ├── MistralProvider.swift     # Chat Completions (OpenAI-compatible wire format)
│       ├── AnthropicProvider.swift   # Anthropic Messages API
│       ├── OllamaProvider.swift      # Local inference, OpenAI-compatible endpoint
│       └── ChatCompletionsClient.swift  # Shared HTTP client for Mistral/Ollama/OpenAI-compat
│
├── OpenAIAgentService.swift         # Refactor: rename to AIAgentService, use LLMProvider
├── OpenAIAPIKeyStore.swift          # DEPRECATED — replaced by LLM/LLMAPIKeyStore.swift
└── ...
```

## Core Types — `LLMTypes.swift`

These are the provider-agnostic types that `AIAgentRunner` and `AIAgentService` work with.
Each provider translates to/from these internally.

```swift
// MARK: - Provider Identity

enum LLMProviderID: String, CaseIterable, Codable, Sendable {
    case openai
    case mistral
    case anthropic
    case ollama
}

struct LLMModelInfo: Sendable, Equatable, Codable, Identifiable {
    var id: String          // e.g. "gpt-5.1-codex-max", "mistral-large-latest"
    var displayName: String // e.g. "GPT-5.1 Codex Max", "Mistral Large"
    var providerID: LLMProviderID
    var supportsFunctionCalling: Bool
    var supportsStreaming: Bool
    var supportsReasoning: Bool  // only OpenAI o-series / claude sonnet extended thinking
}

// MARK: - Messages

enum LLMMessageRole: String, Sendable, Equatable, Codable {
    case system
    case developer  // OpenAI-specific, maps to system for others
    case user
    case assistant
}

struct LLMMessage: Sendable, Equatable {
    var role: LLMMessageRole
    var content: String
}

// MARK: - Tool Definitions

/// Provider-agnostic tool definition — JSON Schema based.
/// Each provider translates this into their wire format.
struct LLMToolDefinition: Sendable, Equatable {
    var name: String
    var description: String
    var parameters: LLMJSONValue  // JSON Schema object
    var strict: Bool?
}

// MARK: - Tool Call / Output

struct LLMToolCall: Sendable, Equatable {
    var id: String
    var name: String
    var arguments: String  // raw JSON string
}

struct LLMToolOutput: Sendable, Equatable {
    var callID: String
    var output: String
}

// MARK: - Request / Response

struct LLMRequest: Sendable {
    var messages: [LLMMessage]
    var tools: [LLMToolDefinition]
    var toolOutputs: [LLMToolOutput]

    /// Opaque provider-specific conversation handle.
    /// OpenAI stores a previousResponseID here. Others store serialized message history.
    var conversationState: LLMConversationState?
}

struct LLMResponse: Sendable {
    var text: String
    var toolCalls: [LLMToolCall]
    /// Updated conversation state to pass into the next request.
    var updatedConversationState: LLMConversationState
}

/// Opaque, provider-managed conversation state.
/// The agent runner stores this but never inspects it.
struct LLMConversationState: Sendable {
    /// Provider that created this state — prevents mixing states across providers.
    var providerID: LLMProviderID
    /// Opaque data. Encoded however the provider likes.
    var data: Data
}

// MARK: - Streaming

enum LLMStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case textDone(String)
    case reasoningDelta(String)
    case reasoningDone(String)
    case reasoningSummaryDelta(String)
    case reasoningSummaryDone(String)
}

// MARK: - Errors

enum LLMProviderError: LocalizedError, Equatable {
    case missingAPIKey(provider: String)
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case encodingFailure(String)
    case decodingFailure(String)
    case transportFailure(String)
    case providerNotConfigured(LLMProviderID)
    case modelNotSupported(model: String, provider: String)
    case conversationStateMismatch(expected: LLMProviderID, got: LLMProviderID)

    var errorDescription: String? {
        switch self {
        case let .missingAPIKey(provider):
            return "\(provider) API key is not configured. Add it in Settings > AI Assistant."
        case .invalidResponse:
            return "Provider returned an invalid response."
        case let .httpError(code, msg):
            return msg.isEmpty ? "Request failed (HTTP \(code))." : "Request failed (\(code)): \(msg)"
        case let .encodingFailure(msg):  return "Failed to encode request: \(msg)"
        case let .decodingFailure(msg):  return "Failed to decode response: \(msg)"
        case let .transportFailure(msg): return "Request failed: \(msg)"
        case let .providerNotConfigured(id):
            return "\(id.rawValue) is not configured."
        case let .modelNotSupported(model, provider):
            return "Model '\(model)' is not supported by \(provider)."
        case let .conversationStateMismatch(expected, got):
            return "Conversation state from \(got.rawValue) cannot be used with \(expected.rawValue)."
        }
    }
}

// MARK: - JSON Value (reuse existing pattern, just rename)

/// Same as existing OpenAIJSONValue but without the OpenAI prefix.
/// Can typealias during migration: `typealias OpenAIJSONValue = LLMJSONValue`
enum LLMJSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LLMJSONValue])
    case array([LLMJSONValue])
    case null
    // ... (same Codable implementation as existing OpenAIJSONValue)
}
```

## Core Protocol — `LLMProvider.swift`

```swift
/// The contract every LLM provider implements.
/// Provider internals (HTTP clients, wire formats) stay private.
@MainActor
protocol LLMProvider: Sendable {
    var providerID: LLMProviderID { get }
    var displayName: String { get }
    var availableModels: [LLMModelInfo] { get }
    var isConfigured: Bool { get }  // has API key / endpoint reachable

    /// Non-streaming request.
    func sendRequest(
        _ request: LLMRequest,
        model: String
    ) async throws -> LLMResponse

    /// Streaming request. Default implementation falls back to non-streaming.
    func sendRequestStreaming(
        _ request: LLMRequest,
        model: String,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> LLMResponse

    /// Reset any cached conversation state.
    func resetConversationState()
}

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
```

## Provider Registry — `LLMProviderRegistry.swift`

```swift
@MainActor
final class LLMProviderRegistry: ObservableObject {
    @Published private(set) var activeProviderID: LLMProviderID
    @Published private(set) var activeModelID: String

    private var providers: [LLMProviderID: any LLMProvider] = [:]

    /// UserDefaults keys
    private static let providerKey = "ai.provider.active"
    private static let modelKey = "ai.model.active"

    init() {
        self.activeProviderID = LLMProviderID(
            rawValue: UserDefaults.standard.string(forKey: Self.providerKey) ?? ""
        ) ?? .mistral  // default to Mistral since Kevin has credits
        self.activeModelID = UserDefaults.standard.string(forKey: Self.modelKey)
            ?? "mistral-large-latest"
    }

    func register(_ provider: any LLMProvider) {
        providers[provider.providerID] = provider
    }

    var activeProvider: (any LLMProvider)? {
        providers[activeProviderID]
    }

    func provider(for id: LLMProviderID) -> (any LLMProvider)? {
        providers[id]
    }

    func setActiveProvider(_ id: LLMProviderID, model: String) {
        activeProviderID = id
        activeModelID = model
        UserDefaults.standard.set(id.rawValue, forKey: Self.providerKey)
        UserDefaults.standard.set(model, forKey: Self.modelKey)
    }

    var configuredProviders: [any LLMProvider] {
        LLMProviderID.allCases.compactMap { id in
            guard let p = providers[id], p.isConfigured else { return nil }
            return p
        }
    }

    var allProviders: [any LLMProvider] {
        LLMProviderID.allCases.compactMap { providers[$0] }
    }
}
```

## Generic API Key Store — `LLMAPIKeyStore.swift`

Replaces `OpenAIAPIKeyStore.swift`. Same Keychain logic, parameterized by provider.

```swift
protocol LLMAPIKeyStoring: Sendable {
    func loadAPIKey(for provider: LLMProviderID) async throws -> String?
    func saveAPIKey(_ apiKey: String, for provider: LLMProviderID) async throws
    func deleteAPIKey(for provider: LLMProviderID) async throws
}

protocol LLMAPIKeyProviding: Sendable {
    func apiKey(for provider: LLMProviderID) async -> String?
}

actor KeychainLLMAPIKeyStore: LLMAPIKeyStoring {
    /// Each provider gets its own Keychain service identifier.
    private func service(for provider: LLMProviderID) -> String {
        "nl.budgetsoft.ProSSHMac.llm.\(provider.rawValue)"
    }

    private let account = "api-key"

    func loadAPIKey(for provider: LLMProviderID) throws -> String? {
        // Same Keychain read logic as existing KeychainOpenAIAPIKeyStore,
        // but using service(for: provider)
    }

    func saveAPIKey(_ apiKey: String, for provider: LLMProviderID) throws {
        // Same Keychain write logic, parameterized
    }

    func deleteAPIKey(for provider: LLMProviderID) throws {
        // Same Keychain delete logic, parameterized
    }
}

/// Migration helper: reads from old "nl.budgetsoft.ProSSHV2.openai" service
/// and copies to new "nl.budgetsoft.ProSSHMac.llm.openai" on first launch.
```

## Provider Implementations

### MistralProvider (first target)

Mistral uses the Chat Completions format. Wire format is nearly identical to OpenAI
Chat Completions, so we share a `ChatCompletionsClient`.

```swift
@MainActor
final class MistralProvider: LLMProvider {
    let providerID = LLMProviderID.mistral
    let displayName = "Mistral AI"

    let availableModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "mistral-large-latest", displayName: "Mistral Large",
            providerID: .mistral, supportsFunctionCalling: true,
            supportsStreaming: true, supportsReasoning: false
        ),
        LLMModelInfo(
            id: "mistral-medium-latest", displayName: "Mistral Medium",
            providerID: .mistral, supportsFunctionCalling: true,
            supportsStreaming: true, supportsReasoning: false
        ),
        LLMModelInfo(
            id: "codestral-latest", displayName: "Codestral",
            providerID: .mistral, supportsFunctionCalling: true,
            supportsStreaming: true, supportsReasoning: false
        ),
    ]

    private let client: ChatCompletionsClient
    private let apiKeyProvider: any LLMAPIKeyProviding

    var isConfigured: Bool {
        // check key availability synchronously via cached state, or just return true
        // and let sendRequest throw .missingAPIKey if needed
        true
    }

    init(apiKeyProvider: any LLMAPIKeyProviding) {
        self.apiKeyProvider = apiKeyProvider
        self.client = ChatCompletionsClient(
            endpointURL: URL(string: "https://api.mistral.ai/v1/chat/completions")!
        )
    }

    func sendRequest(_ request: LLMRequest, model: String) async throws -> LLMResponse {
        guard let apiKey = await apiKeyProvider.apiKey(for: .mistral), !apiKey.isEmpty else {
            throw LLMProviderError.missingAPIKey(provider: displayName)
        }
        let chatRequest = ChatCompletionsRequest(from: request, model: model)
        let chatResponse = try await client.send(chatRequest, apiKey: apiKey)
        return chatResponse.toLLMResponse(providerID: providerID)
    }

    func resetConversationState() { /* no-op, stateless */ }
}
```

### ChatCompletionsClient (shared by Mistral + Ollama)

```swift
/// Shared HTTP client for any provider that speaks the Chat Completions wire format.
/// Mistral and Ollama both use this. OpenAI Chat Completions could too if you switch
/// away from Responses API.
///
/// Each provider configures its own endpoint URL and auth header.
final class ChatCompletionsClient: Sendable {
    let endpointURL: URL
    let session: URLSession

    init(endpointURL: URL, session: URLSession = .shared) {
        self.endpointURL = endpointURL
        self.session = session
    }

    func send(_ request: ChatCompletionsRequest, apiKey: String) async throws -> ChatCompletionsResponse { ... }
    func sendStreaming(_ request: ChatCompletionsRequest, apiKey: String,
                       onEvent: ...) async throws -> ChatCompletionsResponse { ... }
}

// Chat Completions wire types — these are internal to the client, never exposed to AIAgentRunner
struct ChatCompletionsRequest: Encodable { ... }
struct ChatCompletionsResponse: Decodable { ... }
```

### OllamaProvider

```swift
@MainActor
final class OllamaProvider: LLMProvider {
    let providerID = LLMProviderID.ollama
    let displayName = "Ollama (Local)"

    var isConfigured: Bool {
        // Could ping http://localhost:11434/api/tags to check
        true
    }

    /// Dynamically fetched from Ollama's /api/tags endpoint
    var availableModels: [LLMModelInfo] = []

    private let client: ChatCompletionsClient

    init() {
        // Ollama's OpenAI-compatible endpoint
        self.client = ChatCompletionsClient(
            endpointURL: URL(string: "http://localhost:11434/v1/chat/completions")!
        )
    }

    func refreshModels() async {
        // GET http://localhost:11434/api/tags → parse model list
    }

    func sendRequest(_ request: LLMRequest, model: String) async throws -> LLMResponse {
        // Ollama doesn't need an API key (local)
        let chatRequest = ChatCompletionsRequest(from: request, model: model)
        let chatResponse = try await client.send(chatRequest, apiKey: "")
        return chatResponse.toLLMResponse(providerID: providerID)
    }

    func resetConversationState() { }
}
```

### OpenAIProvider (wraps existing code)

```swift
@MainActor
final class OpenAIProvider: LLMProvider {
    let providerID = LLMProviderID.openai
    let displayName = "OpenAI"

    let availableModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max",
            providerID: .openai, supportsFunctionCalling: true,
            supportsStreaming: true, supportsReasoning: true
        ),
        // ... other models
    ]

    /// The existing OpenAIResponsesService, now used as an internal implementation detail.
    private let responsesService: OpenAIResponsesService

    var isConfigured: Bool { true }

    init(responsesService: OpenAIResponsesService) {
        self.responsesService = responsesService
    }

    func sendRequest(_ request: LLMRequest, model: String) async throws -> LLMResponse {
        // Translate LLMRequest → OpenAIResponsesRequest
        let oaiRequest = translateToResponsesAPI(request)
        let oaiResponse = try await responsesService.createResponse(oaiRequest)
        return translateFromResponsesAPI(oaiResponse)
    }

    func sendRequestStreaming(
        _ request: LLMRequest,
        model: String,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> LLMResponse {
        let oaiRequest = translateToResponsesAPI(request)
        let oaiResponse = try await responsesService.createResponseStreaming(oaiRequest) { event in
            // Translate OpenAIResponsesStreamEvent → LLMStreamEvent
            switch event {
            case .outputTextDelta(let d):           onEvent(.textDelta(d))
            case .outputTextDone(let t):            onEvent(.textDone(t))
            case .reasoningTextDelta(let d):        onEvent(.reasoningDelta(d))
            case .reasoningTextDone(let t):         onEvent(.reasoningDone(t))
            case .reasoningSummaryTextDelta(let d):  onEvent(.reasoningSummaryDelta(d))
            case .reasoningSummaryTextDone(let t):   onEvent(.reasoningSummaryDone(t))
            }
        }
        return translateFromResponsesAPI(oaiResponse)
    }

    // MARK: - Translation layer (OpenAI Responses API ↔ LLM generic types)

    private func translateToResponsesAPI(_ request: LLMRequest) -> OpenAIResponsesRequest {
        // LLMMessage → OpenAIResponsesMessage
        // LLMToolDefinition → OpenAIResponsesToolDefinition
        // LLMConversationState → previousResponseID extraction
        // ...
    }

    private func translateFromResponsesAPI(_ response: OpenAIResponsesResponse) -> LLMResponse {
        // OpenAI response.text → LLMResponse.text
        // OpenAI response.toolCalls → [LLMToolCall]
        // OpenAI response.id → packed into LLMConversationState
    }

    func resetConversationState() { }
}
```

### AnthropicProvider (implemented)

Full implementation in `Services/LLM/Providers/AnthropicProvider.swift` (~500 lines). Single file containing all Anthropic-specific code: wire types (request, response, streaming SSE), provider class, request building, response translation, conversation history management, and helpers. Uses `x-api-key` header auth, `anthropic-version: 2023-06-01`, `input_schema` for tool definitions, and polymorphic `AnthropicContent` encoding (string or content block array). Extended thinking enabled for reasoning-capable models with `budget_tokens: 10000`.

## Agent Service Refactor

The existing `OpenAIAgentService` becomes `AIAgentService`, using `LLMProviderRegistry`
instead of directly holding an `OpenAIResponsesServicing`.

### Key change in AIAgentRunner

```swift
// BEFORE (in AIAgentRunner.run):
let response = try await responsesService.createResponseStreaming(request) { ... }

// AFTER:
guard let provider = service.providerRegistry.activeProvider else {
    throw LLMProviderError.providerNotConfigured(service.providerRegistry.activeProviderID)
}
let model = service.providerRegistry.activeModelID
let response = try await provider.sendRequestStreaming(request, model: model, onEvent: { ... })
```

### Conversation State Handling

The `LLMConversationState` is opaque — the agent runner stores it per session and passes
it back into the next request. Each provider packs whatever it needs:

- **OpenAI**: packs the `previousResponseID` string
- **Mistral/Ollama**: packs the accumulated message history as JSON
- **Anthropic**: packs message history (Anthropic doesn't have response chaining either)

```swift
// In AIConversationContext — change from storing responseID to storing LLMConversationState
final class AIConversationContext {
    private var stateBySession: [UUID: LLMConversationState] = [:]

    func state(for sessionID: UUID) -> LLMConversationState? {
        stateBySession[sessionID]
    }

    func update(state: LLMConversationState, for sessionID: UUID) {
        stateBySession[sessionID] = state
    }

    func clear(sessionID: UUID) {
        stateBySession.removeValue(forKey: sessionID)
    }
}
```

## Settings UI

Replace `OpenAISettingsViewModel` with `AIProviderSettingsViewModel`:

```swift
@MainActor
final class AIProviderSettingsViewModel: ObservableObject {
    @Published var selectedProvider: LLMProviderID
    @Published var selectedModel: String
    @Published var apiKeyInput = ""
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var storedKeyHint: String?

    let registry: LLMProviderRegistry
    private let apiKeyStore: any LLMAPIKeyStoring

    var currentProvider: (any LLMProvider)? { registry.provider(for: selectedProvider) }
    var modelsForCurrentProvider: [LLMModelInfo] { currentProvider?.availableModels ?? [] }

    // Show API key section only for providers that need one
    var requiresAPIKey: Bool { selectedProvider != .ollama }

    func saveAPIKey() async { ... }  // saves to LLMAPIKeyStore for selectedProvider
    func removeAPIKey() async { ... }
    func applySelection() { registry.setActiveProvider(selectedProvider, model: selectedModel) }
}
```

## Migration Strategy — Phased Todo Checklist

Pre-built files originally lived in `FilesForMultiProvider/` and were copied/moved into place during each phase. That directory was deleted in Phase 5.

---

### Phase 1: Introduce Abstraction Layer (no behavior change) — COMPLETED (2026-03-02)

**Goal:** Insert the provider abstraction between `AIAgentRunner` and OpenAI. Everything still routes to OpenAI — zero behavior change.

- [x] **1.1** Create directory `ProSSHMac/Services/LLM/` and `ProSSHMac/Services/LLM/Providers/`
- [x] **1.2** Copy foundation files: `LLMTypes.swift`, `LLMProvider.swift`, `LLMProviderRegistry.swift`, `LLMAPIKeyStore.swift`
- [x] **1.3** Remove duplicate `OpenAIJSONValue` enum from `OpenAIResponsesTypes.swift` (resolves through `typealias OpenAIJSONValue = LLMJSONValue`)
- [x] **1.4** Rename agent-layer types: `OpenAIAgentServicing` → `AIAgentServicing`, `OpenAIAgentReply` → `AIAgentReply`, `OpenAIAgentStreamEvent` → `AIAgentStreamEvent`, `OpenAIAgentServiceError` → `AIAgentServiceError`, `OpenAIAgentSessionProviding` → `AIAgentSessionProviding`
- [x] **1.5** Update tool definitions to return `[LLMToolDefinition]` (AIToolDefinitions, ApplyPatchTool, SendInputToolDefinition)
- [x] **1.6** Update `AIToolHandler` to use `LLMToolCall` and `LLMToolOutput`
- [x] **1.7** Update `AIConversationContext` to store `[UUID: LLMConversationState]`
- [x] **1.8** Add `OpenAIAgentService.sendProviderRequest()` translation bridge (`LLMRequest` ↔ `OpenAIResponsesRequest`)
- [x] **1.9** Refactor `AIAgentRunner` to use `LLMMessage`, `LLMRequest`, `LLMResponse`, `LLMConversationState`, calls `sendProviderRequest()`, catches `LLMProviderError`
- [x] **1.10** Rename `OpenAIJSONValue` → `LLMJSONValue` across all AI files
- [x] **1.11** Rename `OpenAIAgentServiceError` → `AIAgentServiceError` across all AI files
- [x] **1.12** Update `TerminalAIAssistantViewModel`, `AppDependencies`, `ProSSHMacApp`
- [x] **1.13** Remove backward-compat typealiases, update all tests
- [x] **1.14** Build & all AI tests pass

**Note:** OpenAI files were NOT moved to `Services/LLM/Providers/` (deferred to Phase 2). Translation lives in `OpenAIAgentService.sendProviderRequest()` rather than a separate `OpenAIProvider` class.

---

### Phase 2: Add Mistral + Multi-Provider Settings UI — COMPLETED (2026-03-02)

**Goal:** Mistral works as a selectable alternative. OpenAI still works. User can switch in Settings.

- [x] **2.1** Copy `FilesForMultiProvider/LLMAPIKeyStore.swift` → `Services/LLM/LLMAPIKeyStore.swift` *(done in Phase 1)*
  - `LLMAPIKeyStoring` protocol, `KeychainLLMAPIKeyStore` actor
  - Includes OpenAI key migration from old `nl.budgetsoft.ProSSHV2.openai` service
  - Includes `LLMToOpenAIKeyProviderBridge` for backward compat with `OpenAIResponsesService`
- [x] **2.2** Deprecate `OpenAIAPIKeyStore.swift`
  - Keep file but mark as deprecated; wire `OpenAIResponsesService` through `LLMToOpenAIKeyProviderBridge` instead
- [x] **2.3** Copy `FilesForMultiProvider/ChatCompletionsClient.swift` → `Services/LLM/Providers/ChatCompletionsClient.swift`
  - Shared HTTP client for Chat Completions wire format (Mistral, Ollama)
  - Wire types: `ChatCompletionsWireRequest`, `ChatCompletionsWireResponse` (made `Codable` for history packing)
  - SSE streaming support, `AuthStyle` (`.bearer` / `.none`)
  - Translation helpers: `LLMRequest` → wire request, wire response → `LLMResponse`
- [x] **2.4** Copy `FilesForMultiProvider/MistralProvider.swift` → `Services/LLM/Providers/MistralProvider.swift`
  - `@MainActor final class MistralProvider: LLMProvider`
  - Models: `mistral-large-latest`, `mistral-medium-latest`, `codestral-latest`, `mistral-small-latest`
  - Uses `ChatCompletionsClient` with endpoint `https://api.mistral.ai/v1/chat/completions`
  - Added full conversation history packing/unpacking via `[ChatCompletionsWireMessage]` in `LLMConversationState.data`
- [x] **2.5** Register `MistralProvider` in `AppDependencies.swift`
  - Create `MistralProvider(apiKeyProvider:)` and call `registry.register()`
  - Wired `LLMToOpenAIKeyProviderBridge` for OpenAI backward compat
  - Added `providerRegistry` to `OpenAIAgentService` init with provider-routing branch in `sendProviderRequest`
  - Added provider-mismatch detection in `AIAgentRunner`
- [x] **2.6** Create `AIProviderSettingsViewModel.swift` *(new file)*
  - `@MainActor final class AIProviderSettingsViewModel: ObservableObject`
  - Provider picker (`LLMProviderID` dropdown)
  - Model picker (per-provider model list, hardcoded OpenAI models)
  - Conditional API key field (hidden for Ollama)
  - `saveAPIKey()`, `removeAPIKey()`, `pasteFromClipboard()` methods
  - Replaces `OpenAISettingsViewModel` in environment injection
- [x] **2.7** Update `SettingsView.swift` — AI Assistant section
  - Provider dropdown (OpenAI + all registered providers)
  - Model picker (populated from selected provider's `availableModels`)
  - Conditional API key input (shown when `selectedProvider.requiresAPIKey`)
  - Key status indicator (stored / not stored)
- [x] **2.8** Update `TerminalAIAssistantPane.swift` — show active provider/model in header
- [x] **2.9** Build & verify — all 209 tests pass (2 pre-existing unrelated failures)
- [x] **2.10** Tests verified — existing `OpenAIAgentServiceTests` pass with default `providerRegistry` parameter

**Note:** OpenAI stays on Responses API path via `sendProviderRequest` branch on `activeProviderID == .openai`. No `OpenAIProvider: LLMProvider` wrapper yet (deferred to Phase 5). `LLMProviderRegistry` defaults changed to `.openai` / `gpt-5.1-codex-max` for backward compatibility.

---

### Phase 3: Add Ollama (local inference) — COMPLETED (2026-03-02)

**Goal:** Ollama works for users running local models. No API key needed.

- [x] **3.1** Copy `FilesForMultiProvider/OllamaProvider.swift` → `Services/LLM/Providers/OllamaProvider.swift`
  - `@MainActor final class OllamaProvider: LLMProvider`
  - Uses `ChatCompletionsClient` with endpoint `http://localhost:11434/v1/chat/completions`
  - `authStyle: .none`, no API key required
  - Fallback models: `qwen2.5-coder:32b`, `llama3.1:70b`, `mistral:latest`
- [x] **3.2** Implement `refreshModels()` — dynamic model discovery (pre-built in file)
  - `GET http://localhost:11434/api/tags` → parse `OllamaTagsResponse`
  - Populate `dynamicModels` with discovered models
  - Gracefully handle Ollama not running (keep fallback models)
- [x] **3.3** Register `OllamaProvider` in `AppDependencies.swift`
- [x] **3.4** Update Settings UI — Ollama-specific section
  - Hide API key field when Ollama selected (`requiresAPIKey` returns false for `.ollama`)
  - Show "Refresh Models" button to re-scan local models
  - Show connection status (Ollama running / not detected) with color-coded indicator
- [x] **3.5** Build & verify — Ollama works with local models, provider switching still works
- [x] **3.6** Added conversation history management (same pattern as MistralProvider)

**Note:** Conversation history packing was added during integration — the pre-built file lacked it. `extractPriorMessages`/`buildUpdatedHistory`/`toLLMResponse` helpers match MistralProvider exactly. Tests for OllamaProvider deferred (no mock Ollama endpoint available; existing agent tests cover the provider routing path).

---

### Phase 4: Add Anthropic — COMPLETED (2026-03-02)

**Goal:** Anthropic Claude models available as a provider option.

- [x] **4.1** Create `Services/LLM/Providers/AnthropicProvider.swift` *(new file, ~500 lines)*
  - `@MainActor final class AnthropicProvider: LLMProvider`
  - Custom HTTP client — different auth (`x-api-key` header, not Bearer)
  - Different tool calling format (`.input_schema` instead of `.parameters`)
  - Endpoint: `https://api.anthropic.com/v1/messages`
  - Models: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`
- [x] **4.2** Implement Anthropic Messages API wire types
  - Request: `messages[]` with `role`/`content`, `system` as top-level field
  - Response: `content[]` blocks (text + tool_use), `stop_reason`
  - Tool use: `tool_use` content blocks with `id`, `name`, `input`
  - Tool results: `tool_result` content blocks
  - Polymorphic `AnthropicContent` enum (string or array of blocks)
- [x] **4.3** Implement Anthropic streaming
  - SSE event types: `message_start`, `content_block_start`, `content_block_delta`, `message_delta`, `message_stop`
  - Map extended thinking → `reasoningDelta` / `reasoningDone` stream events
  - Per-block accumulation for tool_use input JSON (partial deltas)
  - Synthetic response assembly from accumulated stream data
- [x] **4.4** Register `AnthropicProvider` in `AppDependencies.swift`
- [x] **4.5** Build & verify — all four providers work, switching is seamless
- [ ] **4.6** Add tests for `AnthropicProvider` *(deferred — no mock Anthropic endpoint; existing agent tests cover provider routing)*

**Note:** Extended thinking enabled for Opus and Sonnet models (`supportsReasoning: true`), disabled for Haiku. Thinking blocks are streamed as `reasoningDelta`/`reasoningDone` events but excluded from persisted conversation history to avoid bloating state. `tool_use` input (parsed JSON object) is re-serialized to string via `AIToolDefinitions.jsonString(from:)` for `LLMToolCall.arguments` compatibility.

---

### Phase 5: Cleanup & Polish — COMPLETED (2026-03-02)

**Goal:** Remove migration scaffolding, delete deprecated files.

- [x] **5.1** Remove `typealias OpenAIJSONValue = LLMJSONValue` from `LLMTypes.swift`
  - Updated `OpenAIResponsesTypes.swift` to use `LLMJSONValue` directly
- [x] **5.2** Remove `LLMToOpenAIKeyProviderBridge` from `LLMAPIKeyStore.swift`
  - `OpenAIResponsesService` now uses `LLMAPIKeyProviding` natively (`.apiKey(for: .openai)`)
  - Removed `OpenAIAPIKeyProviding` stored property from `AppDependencies`
- [x] **5.3** Delete deprecated `OpenAIAPIKeyStore.swift`
- [x] **5.4** Delete deprecated `OpenAISettingsViewModel.swift` and `OpenAISettingsViewModelTests.swift`
- [x] **5.5** Delete `FilesForMultiProvider/` directory (7 reference copies, all integrated)
- [x] **5.6** Rename `OpenAIAgentServiceTests.swift` → `AIAgentServiceTests.swift` (class renamed too)
- [x] **5.7** Build succeeds, all tests pass (0 new failures)

## Tool Definition Compatibility

All four providers support JSON Schema-based function calling. The translation is:

| Generic LLMToolDefinition | OpenAI Responses | Mistral | Anthropic | Ollama |
|---|---|---|---|---|
| `.name` | `.name` | `.function.name` | `.name` | `.function.name` |
| `.description` | `.description` | `.function.description` | `.description` | `.function.description` |
| `.parameters` | `.parameters` | `.function.parameters` | `.input_schema` | `.function.parameters` |
| `.strict` | `.strict` | n/a | n/a | n/a |

The key insight: **your existing `AIToolDefinitions.swift` already builds tool schemas
as JSON Schema objects** — these are portable across all providers with minimal translation.

## What NOT to Change

- `AIToolHandler.swift` and all extensions — these execute tools against SSH sessions.
  Completely provider-agnostic. Don't touch them.
- `AIToolDefinitions.swift` — the tool schemas work across all providers.
  Only change: output type from `[OpenAIResponsesToolDefinition]` → `[LLMToolDefinition]`
- `TerminalAIAssistantViewModel.swift` — only change the type it depends on
  from `OpenAIAgentServicing` → renamed `AIAgentServicing`
