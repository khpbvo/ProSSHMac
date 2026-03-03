import Foundation

@MainActor
protocol AIAgentServicing {
    var toolDefinitions: [LLMToolDefinition] { get }
    func clearConversation(sessionID: UUID)
    func generateReply(
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]?
    ) async throws -> AIAgentReply
    func generateReply(
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]?,
        streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)?
    ) async throws -> AIAgentReply
}

extension AIAgentServicing {
    func generateReply(
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]? = nil,
        streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)?
    ) async throws -> AIAgentReply {
        _ = streamHandler
        return try await generateReply(sessionID: sessionID, prompt: prompt, broadcastSessionIDs: broadcastSessionIDs)
    }
}

struct AIAgentReply: Sendable, Equatable {
    var text: String
    var responseID: String
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
}

struct CommandExecutionResult: Sendable {
    var output: String
    var exitCode: Int?
    var timedOut: Bool
    var blockID: UUID?
}

extension SessionManager: AIAgentSessionProviding {}

@MainActor
final class OpenAIAgentService: AIAgentServicing {
    var toolDefinitions: [LLMToolDefinition] {
        AIToolDefinitions.buildToolDefinitions(patchToolEnabled: patchToolEnabled)
    }

    let responsesService: any OpenAIResponsesServicing
    let sessionProvider: any AIAgentSessionProviding
    let providerRegistry: LLMProviderRegistry
    let requestTimeoutSeconds: Int
    let maxToolIterations: Int
    let persistConversationContext: Bool
    let conversationContext = AIConversationContext()
    let toolHandler = AIToolHandler()
    let agentRunner = AIAgentRunner()
    let patchApprovalTracker = PatchApprovalTracker()

    // Callbacks wired by TerminalAIAssistantViewModel after init.
    var patchApprovalCallback: ((PatchOperation, String) async -> (approved: Bool, remember: Bool))?
    var patchResultCallback: ((PatchOperation, PatchResult) -> Void)?

    // Computed — read UserDefaults live so SettingsView toggles take effect immediately.
    var patchToolEnabled: Bool {
        UserDefaults.standard.object(forKey: "ai.patchTool.enabled") as? Bool ?? true
    }
    var patchApprovalRequired: Bool {
        UserDefaults.standard.object(forKey: "ai.patchTool.requireApproval") as? Bool ?? true
    }
    var patchAllowDelete: Bool {
        UserDefaults.standard.bool(forKey: "ai.patchTool.allowDelete")
    }

    func requestPatchApproval(
        operation: PatchOperation, fingerprint: String
    ) async -> (approved: Bool, remember: Bool) {
        guard let callback = patchApprovalCallback else { return (true, true) }
        return await callback(operation, fingerprint)
    }

    init(
        responsesService: any OpenAIResponsesServicing,
        sessionProvider: any AIAgentSessionProviding,
        providerRegistry: LLMProviderRegistry = LLMProviderRegistry(),
        requestTimeoutSeconds: Int = 60,
        maxToolIterations: Int = 50,
        persistConversationContext: Bool = true
    ) {
        self.responsesService = responsesService
        self.sessionProvider = sessionProvider
        self.providerRegistry = providerRegistry
        self.requestTimeoutSeconds = max(10, requestTimeoutSeconds)
        self.maxToolIterations = max(1, maxToolIterations)
        self.persistConversationContext = persistConversationContext
        toolHandler.service = self
        agentRunner.service = self
    }

    func clearConversation(sessionID: UUID) {
        conversationContext.clear(sessionID: sessionID)
    }

    func generateReply(
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]? = nil
    ) async throws -> AIAgentReply {
        return try await generateReply(
            sessionID: sessionID,
            prompt: prompt,
            broadcastSessionIDs: broadcastSessionIDs,
            streamHandler: nil
        )
    }

    func generateReply(
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]? = nil,
        streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)?
    ) async throws -> AIAgentReply {
        let broadcastContext = buildBroadcastContext(
            primarySessionID: sessionID,
            broadcastSessionIDs: broadcastSessionIDs
        )
        return try await agentRunner.run(
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

    // MARK: - Provider Translation

    func sendProviderRequest(
        _ request: LLMRequest,
        streamHandler: (@Sendable (LLMStreamEvent) -> Void)?
    ) async throws -> LLMResponse {
        // Non-OpenAI providers go through LLMProvider protocol
        if providerRegistry.activeProviderID != .openai {
            guard let provider = providerRegistry.activeProvider else {
                throw LLMProviderError.providerNotConfigured(providerRegistry.activeProviderID)
            }
            let model = providerRegistry.activeModelID
            if let streamHandler {
                return try await provider.sendRequestStreaming(
                    request, model: model, onEvent: streamHandler
                )
            } else {
                return try await provider.sendRequest(request, model: model)
            }
        }

        // OpenAI path: translate LLMRequest → OpenAIResponsesRequest
        let messages = request.messages.map { msg in
            OpenAIResponsesMessage(
                role: {
                    switch msg.role {
                    case .system: return .system
                    case .developer: return .developer
                    case .user: return .user
                    case .assistant: return .assistant
                    }
                }(),
                text: msg.content
            )
        }

        let tools = request.tools.map { tool in
            OpenAIResponsesToolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters,
                strict: tool.strict
            )
        }

        let toolOutputs = request.toolOutputs.map { output in
            OpenAIResponsesToolOutput(callID: output.callID, output: output.output)
        }

        let previousResponseID = request.conversationState?.stringValue

        let openAIRequest = OpenAIResponsesRequest(
            messages: messages,
            previousResponseID: previousResponseID,
            tools: tools,
            toolOutputs: toolOutputs
        )

        do {
            let response: OpenAIResponsesResponse
            if let streamHandler {
                response = try await responsesService.createResponseStreaming(openAIRequest) { streamEvent in
                    // Translate OpenAIResponsesStreamEvent → LLMStreamEvent
                    switch streamEvent {
                    case let .outputTextDelta(delta):
                        streamHandler(.textDelta(delta))
                    case let .outputTextDone(text):
                        streamHandler(.textDone(text))
                    case let .reasoningTextDelta(delta):
                        streamHandler(.reasoningDelta(delta))
                    case let .reasoningTextDone(text):
                        streamHandler(.reasoningDone(text))
                    case let .reasoningSummaryTextDelta(delta):
                        streamHandler(.reasoningSummaryDelta(delta))
                    case let .reasoningSummaryTextDone(text):
                        streamHandler(.reasoningSummaryDone(text))
                    }
                }
            } else {
                response = try await responsesService.createResponse(openAIRequest)
            }

            // Translate OpenAIResponsesResponse → LLMResponse
            let llmToolCalls = response.toolCalls.map { tc in
                LLMToolCall(id: tc.id, name: tc.name, arguments: tc.arguments)
            }

            return LLMResponse(
                text: response.text,
                toolCalls: llmToolCalls,
                updatedConversationState: .string(response.id, provider: .openai)
            )
        } catch let error as OpenAIResponsesServiceError {
            // Re-throw as LLMProviderError
            switch error {
            case .missingAPIKey:
                throw LLMProviderError.missingAPIKey(provider: "OpenAI")
            case .invalidResponse:
                throw LLMProviderError.invalidResponse
            case let .httpError(statusCode, message):
                throw LLMProviderError.httpError(statusCode: statusCode, message: message)
            case let .encodingFailure(message):
                throw LLMProviderError.encodingFailure(message)
            case let .decodingFailure(message):
                throw LLMProviderError.decodingFailure(message)
            case let .transportFailure(message):
                throw LLMProviderError.transportFailure(message)
            }
        }
    }
}
