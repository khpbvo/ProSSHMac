import Foundation

/// The AI assistant. A conversation is one chat: its memory follows the chat, not the focused
/// session. `sessionID` is the session focused when the prompt was sent (the tools' default
/// target and the screen snapshot's source).
@MainActor
protocol AIAgentServicing {
    var toolDefinitions: [LLMToolDefinition] { get }
    func clearConversation(conversationID: UUID)
    func generateReply(
        conversationID: UUID,
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]?,
        streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)?
    ) async throws -> AIAgentReply
}

extension AIAgentServicing {
    /// A conversation of its own per session (the session id is the conversation id).
    func clearConversation(sessionID: UUID) {
        clearConversation(conversationID: sessionID)
    }

    /// A conversation of its own per session (the session id is the conversation id).
    func generateReply(
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]? = nil,
        streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)? = nil
    ) async throws -> AIAgentReply {
        try await generateReply(
            conversationID: sessionID,
            sessionID: sessionID,
            prompt: prompt,
            broadcastSessionIDs: broadcastSessionIDs,
            streamHandler: streamHandler
        )
    }
}

struct AIActiveModel {
    let provider: any AIChatProviding
    let modelID: String
    let contextLength: Int
}

struct AIAgentReply: Sendable, Equatable {
    var text: String
    var toolCallsExecuted: Int
}

enum AIAgentStreamEvent: Sendable, Equatable {
    case assistantTextDelta(String)
    case assistantTextDone(String)
    case reasoningTextDelta(String)
    case reasoningTextDone(String)
    case reasoningSummaryDelta(String)
    case reasoningSummaryDone(String)
}

enum AIAgentServiceError: LocalizedError, Equatable {
    case sessionNotFound
    case emptyPrompt
    case requestTimedOut(seconds: Int)
    case toolLoopExceeded(limit: Int)
    case invalidToolArguments(toolName: String, message: String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "No active session is selected for AI tools."
        case .emptyPrompt:
            return "Prompt cannot be empty."
        case let .requestTimedOut(seconds):
            return "AI request timed out after \(seconds) seconds."
        case let .toolLoopExceeded(limit):
            return "AI tool loop exceeded \(limit) iterations."
        case let .invalidToolArguments(toolName, message):
            return "Tool '\(toolName)' received invalid arguments: \(message)"
        }
    }
}

@MainActor
protocol AIAgentSessionProviding: AnyObject {
    var sessions: [Session] { get }
    var shellBuffers: [UUID: [String]] { get }
    var workingDirectoryBySessionID: [UUID: String] { get }
    var bytesReceivedBySessionID: [UUID: Int64] { get }
    var bytesSentBySessionID: [UUID: Int64] { get }

    func recentCommandBlocks(sessionID: UUID, limit: Int) async -> [CommandBlock]
    func searchCommandHistory(sessionID: UUID, query: String, limit: Int) async -> [CommandBlock]
    func commandOutput(sessionID: UUID, blockID: UUID) async -> String?
    func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool) async
    func sendRawShellInput(sessionID: UUID, input: String) async
    func executeCommandAndWait(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CommandExecutionResult
    func executeCLICommand(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CLICommandResult
}

struct CommandExecutionResult: Sendable {
    var output: String
    var exitCode: Int?
    var timedOut: Bool
    var blockID: UUID?
    /// The command stopped at a password prompt and waited for the user to answer it.
    var waitedForCredential = false
    /// The user declined the password prompt; the command was interrupted with Ctrl+C.
    var declinedCredential = false
}

/// One command run at a device CLI prompt (`run_cli_command`).
struct CLICommandResult: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case completed
        case awaitingInput(String)
        case timedOut
        case superseded
        case failed
        /// The user declined the password prompt; the command was interrupted with Ctrl+C.
        case declined
    }

    var output: String
    var status: Status
    var finalPrompt: String?
    var pagesAdvanced = 0
    /// The command stopped at a password prompt and waited for the user to answer it.
    var waitedForCredential = false
}

extension SessionManager: AIAgentSessionProviding {}

@MainActor
final class AIAgentService: AIAgentServicing {
    var toolDefinitions: [LLMToolDefinition] {
        AIToolDefinitions.buildToolDefinitions(patchToolEnabled: patchToolEnabled)
    }

    let openRouterClient: any OpenRouterServicing
    let sessionProvider: any AIAgentSessionProviding
    let modelStore: OpenRouterModelStore
    let anthropicClient: (any AnthropicServicing)?
    let anthropicModelStore: AnthropicModelStore?
    let providerSelection: AIProviderSelection?
    let requestTimeoutSeconds: Int
    let maxToolIterations: Int
    let persistConversationContext: Bool
    /// Where each new chat loads its skills; `.empty` unless the app passes `.standard`.
    let skillLibrary: AISkillLibrary
    private let defaults: UserDefaults
    let conversationContext = AIConversationContext()
    let toolHandler = AIToolHandler()
    let agentRunner = AIAgentRunner()
    let patchApprovalTracker = PatchApprovalTracker()

    // Callbacks wired by TerminalAIAssistantViewModel after init.
    var patchApprovalCallback: ((PatchOperation, String) async -> (approved: Bool, remember: Bool))?
    var patchResultCallback: ((PatchOperation, PatchResult) -> Void)?

    // Computed — read UserDefaults live so SettingsView toggles take effect immediately.
    var patchToolEnabled: Bool {
        defaults.object(forKey: "ai.patchTool.enabled") as? Bool ?? true
    }
    var patchApprovalRequired: Bool {
        defaults.object(forKey: "ai.patchTool.requireApproval") as? Bool ?? true
    }
    var patchAllowDelete: Bool {
        defaults.bool(forKey: "ai.patchTool.allowDelete")
    }

    func requestPatchApproval(
        operation: PatchOperation, fingerprint: String
    ) async -> (approved: Bool, remember: Bool) {
        guard let callback = patchApprovalCallback else { return (true, true) }
        return await callback(operation, fingerprint)
    }

    init(
        openRouterClient: any OpenRouterServicing,
        sessionProvider: any AIAgentSessionProviding,
        modelStore: OpenRouterModelStore,
        requestTimeoutSeconds: Int = 60,
        maxToolIterations: Int = 50,
        persistConversationContext: Bool = true,
        anthropicClient: (any AnthropicServicing)? = nil,
        anthropicModelStore: AnthropicModelStore? = nil,
        providerSelection: AIProviderSelection? = nil,
        skillLibrary: AISkillLibrary = .empty,
        defaults: UserDefaults = .standard
    ) {
        self.openRouterClient = openRouterClient
        self.sessionProvider = sessionProvider
        self.modelStore = modelStore
        self.anthropicClient = anthropicClient
        self.anthropicModelStore = anthropicModelStore
        self.providerSelection = providerSelection
        self.requestTimeoutSeconds = max(10, requestTimeoutSeconds)
        self.maxToolIterations = max(1, maxToolIterations)
        self.persistConversationContext = persistConversationContext
        self.skillLibrary = skillLibrary
        self.defaults = defaults
        toolHandler.service = self
        agentRunner.service = self
    }

    func clearConversation(conversationID: UUID) {
        conversationContext.clear(conversationID: conversationID)
    }

    /// The provider and model for the next user turn. The runner resolves this once per turn,
    /// so a Settings change can't split one tool loop across two models.
    func activeModel() async throws -> AIActiveModel {
        switch providerSelection?.provider ?? .openRouter {
        case .openRouter:
            let modelID = try modelStore.requireSelection()
            return AIActiveModel(
                provider: OpenRouterChatProvider(client: openRouterClient),
                modelID: modelID,
                contextLength: modelStore.contextLength(for: modelID)
            )
        case .anthropic:
            guard let anthropicClient, let anthropicModelStore else { throw AnthropicError.missingAPIKey }
            // Load the catalog before the first turn, so the model's limits and its refusal
            // fallback are known. After a failed refresh, Settings retries; turns use defaults.
            if anthropicModelStore.models.isEmpty, anthropicModelStore.catalogError == nil {
                await anthropicModelStore.refresh()
            }
            let modelID = try anthropicModelStore.requireSelection()
            return AIActiveModel(
                provider: AnthropicChatProvider(client: anthropicClient, modelStore: anthropicModelStore),
                modelID: modelID,
                contextLength: anthropicModelStore.contextLength(for: modelID)
            )
        }
    }

    func generateReply(
        conversationID: UUID,
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]?,
        streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)?
    ) async throws -> AIAgentReply {
        let broadcastContext = buildBroadcastContext(
            primarySessionID: sessionID,
            broadcastSessionIDs: broadcastSessionIDs
        )
        return try await agentRunner.run(
            conversationID: conversationID,
            sessionID: sessionID,
            prompt: prompt,
            broadcastContext: broadcastContext,
            streamHandler: streamHandler
        )
    }

    private func buildBroadcastContext(
        primarySessionID: UUID,
        broadcastSessionIDs: [UUID]?
    ) -> BroadcastContext? {
        guard let ids = broadcastSessionIDs, ids.count > 1 else { return nil }
        var labels: [UUID: String] = [:]
        for id in ids {
            if let session = sessionProvider.sessions.first(where: { $0.id == id }) {
                labels[id] = session.isLocal
                    ? "Local Shell"
                    : "\(session.username)@\(session.hostname)"
            }
        }
        return BroadcastContext(
            primarySessionID: primarySessionID,
            allSessionIDs: ids,
            sessionLabels: labels
        )
    }

}
