// swiftlint:disable file_length
import Foundation
import os.log

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
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.Agent")
    let toolDefinitions: [OpenAIResponsesToolDefinition]

    let responsesService: any OpenAIResponsesServicing
    let sessionProvider: any OpenAIAgentSessionProviding
    let requestTimeoutSeconds: Int
    let maxToolIterations: Int
    let persistConversationContext: Bool
    let conversationContext = AIConversationContext()
    let toolHandler = AIToolHandler()

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
        self.toolDefinitions = AIToolDefinitions.buildToolDefinitions()
        toolHandler.service = self
    }

    func clearConversation(sessionID: UUID) {
        conversationContext.clear(sessionID: sessionID)
    }

    func generateReply(
        sessionID: UUID,
        prompt: String
    ) async throws -> OpenAIAgentReply {
        let traceID = AIToolDefinitions.shortTraceID()
        let turnStart = DispatchTime.now().uptimeNanoseconds
        guard sessionProvider.sessions.contains(where: { $0.id == sessionID }) else {
            Self.logger.error("[\(traceID, privacy: .public)] session_not_found session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public)")
            throw OpenAIAgentServiceError.sessionNotFound
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            Self.logger.error("[\(traceID, privacy: .public)] empty_prompt session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public)")
            throw OpenAIAgentServiceError.emptyPrompt
        }
        Self.logger.info(
            "[\(traceID, privacy: .public)] turn_start session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public) prompt_chars=\(trimmedPrompt.count) persist_context=\(self.persistConversationContext)"
        )

        let directActionMode = AIToolDefinitions.isDirectActionPrompt(trimmedPrompt)
        let activeToolDefinitions = directActionMode
            ? AIToolDefinitions.directActionToolDefinitions(from: toolDefinitions)
            : toolDefinitions
        let iterationLimit = directActionMode
            ? min(maxToolIterations, 15)
            : maxToolIterations
        Self.logger.debug(
            "[\(traceID, privacy: .public)] turn_mode direct_action=\(directActionMode) tools=\(activeToolDefinitions.count) iteration_limit=\(iterationLimit)"
        )

        var previousResponseID = persistConversationContext
            ? conversationContext.responseID(for: sessionID)
            : nil
        var pendingMessages: [OpenAIResponsesMessage] = [
            .init(role: .developer, text: AIToolDefinitions.developerPrompt()),
            .init(role: .user, text: trimmedPrompt),
        ]
        var pendingToolOutputs: [OpenAIResponsesToolOutput] = []
        var totalToolCalls = 0

        for iteration in 1...iterationLimit {
            let iterationStart = DispatchTime.now().uptimeNanoseconds
            let request = OpenAIResponsesRequest(
                messages: pendingMessages,
                previousResponseID: previousResponseID,
                tools: activeToolDefinitions,
                toolOutputs: pendingToolOutputs
            )
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_start i=\(iteration) prev_id_present=\(request.previousResponseID != nil) pending_messages=\(request.messages.count) pending_tool_outputs=\(request.toolOutputs.count)"
            )

            let response = try await createResponseWithRecovery(
                request: request,
                previousResponseID: &previousResponseID,
                traceID: traceID
            )
            let responseMs = AIToolDefinitions.elapsedMillis(since: iterationStart)

            previousResponseID = response.id
            if persistConversationContext {
                conversationContext.update(responseID: response.id, for: sessionID)
            } else {
                conversationContext.clear(sessionID: sessionID)
            }

            let toolCalls = response.toolCalls
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_response i=\(iteration) response_ms=\(responseMs) response_id=\(response.id, privacy: .public) tool_calls=\(toolCalls.count) text_chars=\(response.text.count)"
            )
            guard !toolCalls.isEmpty else {
                let totalMs = AIToolDefinitions.elapsedMillis(since: turnStart)
                Self.logger.info(
                    "[\(traceID, privacy: .public)] turn_complete session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public) iterations=\(iteration) tool_calls=\(totalToolCalls) total_ms=\(totalMs) reply_chars=\(response.text.count)"
                )
                return OpenAIAgentReply(
                    text: response.text,
                    responseID: response.id,
                    toolCallsExecuted: totalToolCalls
                )
            }

            totalToolCalls += toolCalls.count
            let toolStart = DispatchTime.now().uptimeNanoseconds
            pendingToolOutputs = await toolHandler.executeToolCalls(
                sessionID: sessionID,
                toolCalls: toolCalls,
                traceID: traceID
            )
            let toolMs = AIToolDefinitions.elapsedMillis(since: toolStart)
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_tools i=\(iteration) tool_calls=\(toolCalls.count) tool_ms=\(toolMs)"
            )
            pendingMessages = []
        }

        let totalMs = AIToolDefinitions.elapsedMillis(since: turnStart)
        Self.logger.error(
            "[\(traceID, privacy: .public)] turn_failed_tool_loop session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public) limit=\(iterationLimit) total_ms=\(totalMs)"
        )
        throw OpenAIAgentServiceError.toolLoopExceeded(limit: iterationLimit)
    }

    private func createResponseWithRecovery(
        request: OpenAIResponsesRequest,
        previousResponseID: inout String?,
        traceID: String
    ) async throws -> OpenAIResponsesResponse {
        let service = responsesService
        do {
            return try await runWithTimeout {
                try await service.createResponse(request)
            }
        } catch let error as OpenAIResponsesServiceError {
            guard case let .httpError(statusCode, message) = error,
                  statusCode == 400 || statusCode == 404,
                  request.previousResponseID != nil,
                  AIToolDefinitions.isPreviousResponseIDError(message: message) else {
                Self.logger.error(
                    "[\(traceID, privacy: .public)] response_failed status_recoverable=false error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }

            Self.logger.warning(
                "[\(traceID, privacy: .public)] previous_response_recovery triggered=true status=\(statusCode) message=\(message, privacy: .public)"
            )
            previousResponseID = nil
            let retryRequest = OpenAIResponsesRequest(
                messages: request.messages,
                previousResponseID: nil,
                tools: request.tools,
                toolOutputs: request.toolOutputs
            )
            return try await runWithTimeout {
                try await service.createResponse(retryRequest)
            }
        }
    }

    private func runWithTimeout<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutSeconds = requestTimeoutSeconds
        let timeoutNanoseconds = UInt64(timeoutSeconds) * 1_000_000_000
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw OpenAIAgentServiceError.requestTimedOut(seconds: timeoutSeconds)
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw OpenAIAgentServiceError.requestTimedOut(seconds: timeoutSeconds)
            }
            group.cancelAll()
            return result
        }
    }

}
