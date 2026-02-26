// Extracted from OpenAIAgentService.swift
import Foundation
import os.log

@MainActor final class AIAgentRunner {
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.AgentRunner")
    weak var service: OpenAIAgentService?

    init() {}
    nonisolated deinit {}

    // MARK: - Agent Loop

    func run(
        sessionID: UUID,
        prompt: String,
        streamHandler: (@Sendable (OpenAIAgentStreamEvent) -> Void)? = nil
    ) async throws -> OpenAIAgentReply {
        guard let service else {
            throw OpenAIAgentServiceError.sessionNotFound
        }

        let traceID = AIToolDefinitions.shortTraceID()
        let turnStart = DispatchTime.now().uptimeNanoseconds
        guard service.sessionProvider.sessions.contains(where: { $0.id == sessionID }) else {
            Self.logger.error("[\(traceID, privacy: .public)] session_not_found session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public)")
            throw OpenAIAgentServiceError.sessionNotFound
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            Self.logger.error("[\(traceID, privacy: .public)] empty_prompt session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public)")
            throw OpenAIAgentServiceError.emptyPrompt
        }
        Self.logger.info(
            "[\(traceID, privacy: .public)] turn_start session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public) prompt_chars=\(trimmedPrompt.count) persist_context=\(service.persistConversationContext)"
        )

        let directActionMode = AIToolDefinitions.isDirectActionPrompt(trimmedPrompt)
        let activeToolDefinitions = directActionMode
            ? AIToolDefinitions.directActionToolDefinitions(from: service.toolDefinitions)
            : service.toolDefinitions
        let iterationLimit = directActionMode
            ? min(service.maxToolIterations, 15)
            : service.maxToolIterations
        Self.logger.debug(
            "[\(traceID, privacy: .public)] turn_mode direct_action=\(directActionMode) tools=\(activeToolDefinitions.count) iteration_limit=\(iterationLimit)"
        )

        var previousResponseID = service.persistConversationContext
            ? service.conversationContext.responseID(for: sessionID)
            : nil

        let screenLines = service.sessionProvider.shellBuffers[sessionID] ?? []
        let screenSnapshot = screenLines.suffix(20).joined(separator: "\n")
        let userMessageText: String
        if !screenSnapshot.isEmpty {
            userMessageText = "[Current terminal screen — use this to identify the environment, OS, device type, and current path/mode before acting]\n```\n\(screenSnapshot)\n```\n\n\(trimmedPrompt)"
        } else {
            userMessageText = trimmedPrompt
        }

        var pendingMessages: [OpenAIResponsesMessage] = [
            .init(role: .developer, text: AIToolDefinitions.developerPrompt()),
            .init(role: .user, text: userMessageText),
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
                traceID: traceID,
                streamHandler: streamHandler
            )
            let responseMs = AIToolDefinitions.elapsedMillis(since: iterationStart)

            previousResponseID = response.id
            if service.persistConversationContext {
                service.conversationContext.update(responseID: response.id, for: sessionID)
            } else {
                service.conversationContext.clear(sessionID: sessionID)
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
            pendingToolOutputs = await service.toolHandler.executeToolCalls(
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

    // MARK: - Response Recovery

    private func createResponseWithRecovery(
        request: OpenAIResponsesRequest,
        previousResponseID: inout String?,
        traceID: String,
        streamHandler: (@Sendable (OpenAIAgentStreamEvent) -> Void)?
    ) async throws -> OpenAIResponsesResponse {
        guard let service else {
            throw OpenAIAgentServiceError.sessionNotFound
        }
        let responsesService = service.responsesService
        let timeoutSeconds = service.requestTimeoutSeconds
        do {
            return try await runWithTimeout(timeoutSeconds: timeoutSeconds) {
                try await responsesService.createResponseStreaming(request) { streamEvent in
                    Self.forward(streamEvent: streamEvent, to: streamHandler)
                }
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
            return try await runWithTimeout(timeoutSeconds: timeoutSeconds) {
                try await responsesService.createResponseStreaming(retryRequest) { streamEvent in
                    Self.forward(streamEvent: streamEvent, to: streamHandler)
                }
            }
        }
    }

    nonisolated private static func forward(
        streamEvent: OpenAIResponsesStreamEvent,
        to streamHandler: (@Sendable (OpenAIAgentStreamEvent) -> Void)?
    ) {
        guard let streamHandler else { return }
        switch streamEvent {
        case let .outputTextDelta(delta):
            streamHandler(.assistantTextDelta(delta))
        case let .outputTextDone(text):
            streamHandler(.assistantTextDone(text))
        case let .reasoningTextDelta(delta):
            streamHandler(.reasoningTextDelta(delta))
        case let .reasoningTextDone(text):
            streamHandler(.reasoningTextDone(text))
        case let .reasoningSummaryTextDelta(delta):
            streamHandler(.reasoningSummaryDelta(delta))
        case let .reasoningSummaryTextDone(text):
            streamHandler(.reasoningSummaryDone(text))
        }
    }

    private func runWithTimeout<T: Sendable>(
        timeoutSeconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
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
