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
        streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)? = nil
    ) async throws -> AIAgentReply {
        guard let service else {
            throw AIAgentServiceError.sessionNotFound
        }

        let traceID = AIToolDefinitions.shortTraceID()
        let turnStart = DispatchTime.now().uptimeNanoseconds
        guard service.sessionProvider.sessions.contains(where: { $0.id == sessionID }) else {
            Self.logger.error("[\(traceID, privacy: .public)] session_not_found session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public)")
            throw AIAgentServiceError.sessionNotFound
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            Self.logger.error("[\(traceID, privacy: .public)] empty_prompt session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public)")
            throw AIAgentServiceError.emptyPrompt
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

        var conversationState: LLMConversationState? = service.persistConversationContext
            ? service.conversationContext.state(for: sessionID)
            : nil

        // Clear conversation state if provider changed mid-conversation
        if let existingState = conversationState,
           existingState.providerID != service.providerRegistry.activeProviderID {
            Self.logger.warning(
                "[\(traceID, privacy: .public)] provider_mismatch state_provider=\(existingState.providerID.rawValue, privacy: .public) active_provider=\(service.providerRegistry.activeProviderID.rawValue, privacy: .public) — clearing state"
            )
            conversationState = nil
            service.conversationContext.clear(sessionID: sessionID)
        }

        let screenLines = service.sessionProvider.shellBuffers[sessionID] ?? []
        let screenSnapshot = screenLines.suffix(20).joined(separator: "\n")
        let userMessageText: String
        if !screenSnapshot.isEmpty {
            userMessageText = "[Current terminal screen — use this to identify the environment, OS, device type, and current path/mode before acting]\n```\n\(screenSnapshot)\n```\n\n\(trimmedPrompt)"
        } else {
            userMessageText = trimmedPrompt
        }

        var pendingMessages: [LLMMessage] = [
            LLMMessage(role: .developer, content: AIToolDefinitions.developerPrompt()),
            LLMMessage(role: .user, content: userMessageText),
        ]
        var pendingToolOutputs: [LLMToolOutput] = []
        var totalToolCalls = 0

        for iteration in 1...iterationLimit {
            let iterationStart = DispatchTime.now().uptimeNanoseconds
            let request = LLMRequest(
                messages: pendingMessages,
                tools: activeToolDefinitions,
                toolOutputs: pendingToolOutputs,
                conversationState: conversationState
            )
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_start i=\(iteration) prev_id_present=\(request.conversationState != nil) pending_messages=\(request.messages.count) pending_tool_outputs=\(request.toolOutputs.count)"
            )

            let response = try await createResponseWithRecovery(
                request: request,
                conversationState: &conversationState,
                traceID: traceID,
                streamHandler: streamHandler
            )
            let responseMs = AIToolDefinitions.elapsedMillis(since: iterationStart)

            conversationState = response.updatedConversationState
            if service.persistConversationContext {
                service.conversationContext.update(state: response.updatedConversationState, for: sessionID)
            } else {
                service.conversationContext.clear(sessionID: sessionID)
            }

            let toolCalls = response.toolCalls
            let responseIDString = response.updatedConversationState.stringValue ?? ""
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_response i=\(iteration) response_ms=\(responseMs) response_id=\(responseIDString, privacy: .public) tool_calls=\(toolCalls.count) text_chars=\(response.text.count)"
            )
            guard !toolCalls.isEmpty else {
                let totalMs = AIToolDefinitions.elapsedMillis(since: turnStart)
                Self.logger.info(
                    "[\(traceID, privacy: .public)] turn_complete session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public) iterations=\(iteration) tool_calls=\(totalToolCalls) total_ms=\(totalMs) reply_chars=\(response.text.count)"
                )
                return AIAgentReply(
                    text: response.text,
                    responseID: responseIDString,
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
        throw AIAgentServiceError.toolLoopExceeded(limit: iterationLimit)
    }

    // MARK: - Response Recovery

    private func createResponseWithRecovery(
        request: LLMRequest,
        conversationState: inout LLMConversationState?,
        traceID: String,
        streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)?
    ) async throws -> LLMResponse {
        guard let service else {
            throw AIAgentServiceError.sessionNotFound
        }
        let timeoutSeconds = service.requestTimeoutSeconds
        do {
            return try await runWithTimeout(timeoutSeconds: timeoutSeconds) {
                try await service.sendProviderRequest(request) { streamEvent in
                    Self.forward(streamEvent: streamEvent, to: streamHandler)
                }
            }
        } catch let error as LLMProviderError {
            guard case let .httpError(statusCode, message) = error,
                  statusCode == 400 || statusCode == 404,
                  request.conversationState != nil,
                  AIToolDefinitions.isPreviousResponseIDError(message: message) else {
                Self.logger.error(
                    "[\(traceID, privacy: .public)] response_failed status_recoverable=false error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }

            Self.logger.warning(
                "[\(traceID, privacy: .public)] previous_response_recovery triggered=true status=\(statusCode) message=\(message, privacy: .public)"
            )
            conversationState = nil
            let retryRequest = LLMRequest(
                messages: request.messages,
                tools: request.tools,
                toolOutputs: request.toolOutputs,
                conversationState: nil
            )
            return try await runWithTimeout(timeoutSeconds: timeoutSeconds) {
                try await service.sendProviderRequest(retryRequest) { streamEvent in
                    Self.forward(streamEvent: streamEvent, to: streamHandler)
                }
            }
        }
    }

    nonisolated private static func forward(
        streamEvent: LLMStreamEvent,
        to streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)?
    ) {
        guard let streamHandler else { return }
        switch streamEvent {
        case let .textDelta(delta):
            streamHandler(.assistantTextDelta(delta))
        case let .textDone(text):
            streamHandler(.assistantTextDone(text))
        case let .reasoningDelta(delta):
            streamHandler(.reasoningTextDelta(delta))
        case let .reasoningDone(text):
            streamHandler(.reasoningTextDone(text))
        case let .reasoningSummaryDelta(delta):
            streamHandler(.reasoningSummaryDelta(delta))
        case let .reasoningSummaryDone(text):
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
                throw AIAgentServiceError.requestTimedOut(seconds: timeoutSeconds)
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw AIAgentServiceError.requestTimedOut(seconds: timeoutSeconds)
            }
            group.cancelAll()
            return result
        }
    }
}
