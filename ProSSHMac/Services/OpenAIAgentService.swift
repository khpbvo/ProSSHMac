import Foundation

@MainActor
protocol OpenAIAgentServicing {
    var toolDefinitions: [OpenAIResponsesToolDefinition] { get }
    func clearConversation(sessionID: UUID)
    func generateReply(
        sessionID: UUID,
        prompt: String
    ) async throws -> OpenAIAgentReply
}

struct OpenAIAgentReply: Sendable, Equatable {
    var text: String
    var responseID: String
    var toolCallsExecuted: Int
}

enum OpenAIAgentServiceError: LocalizedError, Equatable {
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
protocol OpenAIAgentSessionProviding: AnyObject {
    var sessions: [Session] { get }
    var shellBuffers: [UUID: [String]] { get }
    var workingDirectoryBySessionID: [UUID: String] { get }
    var bytesReceivedBySessionID: [UUID: Int64] { get }
    var bytesSentBySessionID: [UUID: Int64] { get }

    func recentCommandBlocks(sessionID: UUID, limit: Int) async -> [CommandBlock]
    func searchCommandHistory(sessionID: UUID, query: String, limit: Int) async -> [CommandBlock]
    func commandOutput(sessionID: UUID, blockID: UUID) async -> String?
    func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool) async
    func executeCommandAndWait(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CommandExecutionResult
}

struct CommandExecutionResult: Sendable {
    var output: String
    var exitCode: Int?
    var timedOut: Bool
    var blockID: UUID?
}

extension SessionManager: OpenAIAgentSessionProviding {}

@MainActor
final class OpenAIAgentService: OpenAIAgentServicing {
    var toolDefinitions: [OpenAIResponsesToolDefinition] {
        AIToolDefinitions.buildToolDefinitions(patchToolEnabled: patchToolEnabled)
    }

    let responsesService: any OpenAIResponsesServicing
    let sessionProvider: any OpenAIAgentSessionProviding
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
        sessionProvider: any OpenAIAgentSessionProviding,
        requestTimeoutSeconds: Int = 60,
        maxToolIterations: Int = 50,
        persistConversationContext: Bool = true
    ) {
        self.responsesService = responsesService
        self.sessionProvider = sessionProvider
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
        prompt: String
    ) async throws -> OpenAIAgentReply {
        return try await agentRunner.run(sessionID: sessionID, prompt: prompt)
    }

}
