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

### AnthropicProvider (stub for later)

```swift
@MainActor
final class AnthropicProvider: LLMProvider {
    let providerID = LLMProviderID.anthropic
    let displayName = "Anthropic"

    let availableModels: [LLMModelInfo] = [
        LLMModelInfo(
            id: "claude-sonnet-4-5-20250929", displayName: "Claude Sonnet 4.5",
            providerID: .anthropic, supportsFunctionCalling: true,
            supportsStreaming: true, supportsReasoning: true  // extended thinking
        ),
    ]

    var isConfigured: Bool { false }  // flip when ready

    func sendRequest(_ request: LLMRequest, model: String) async throws -> LLMResponse {
        // Anthropic Messages API:
        // POST https://api.anthropic.com/v1/messages
        // x-api-key header (not Bearer token)
        // Different tool calling format
        throw LLMProviderError.providerNotConfigured(.anthropic)
    }

    func resetConversationState() { }
}
```

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

## Migration Strategy

### Phase 1: Introduce abstraction (no behavior change)
1. Create `LLM/` directory with `LLMTypes.swift`, `LLMProvider.swift`, `LLMProviderRegistry.swift`
2. Create `OpenAIProvider.swift` that wraps existing code — pure adapter
3. Move OpenAI files into `LLM/Providers/` (git preserves history with `git mv`)
4. Wire up `LLMProviderRegistry` in `ProSSHMacApp.swift`
5. Refactor `AIAgentRunner` to go through `LLMProvider` protocol
6. **Ship**: everything works exactly as before, just through the new abstraction

### Phase 2: Add Mistral (your first new provider)
1. Create `ChatCompletionsClient.swift` — shared HTTP client
2. Create `MistralProvider.swift`
3. Create `LLMAPIKeyStore.swift` + migrate OpenAI key store
4. Build `AIProviderSettingsViewModel` + Settings UI with provider picker
5. **Ship**: Mistral works, OpenAI still works

### Phase 3: Add Ollama
1. Create `OllamaProvider.swift` — reuses `ChatCompletionsClient`, no API key needed
2. Add dynamic model discovery from `localhost:11434/api/tags`
3. **Ship**: local inference works

### Phase 4: Add Anthropic (when budget allows)
1. Create `AnthropicProvider.swift` — needs custom HTTP client (different auth, different format)
2. Handle extended thinking → maps to `reasoningDelta`/`reasoningDone` stream events
3. **Ship**

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
