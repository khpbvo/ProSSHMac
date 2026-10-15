import Foundation
import os.log

@MainActor final class AIAgentRunner {
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.AgentRunner")
    weak var service: AIAgentService?

    init() {}
    nonisolated deinit {}

    // MARK: - Agent Loop

    func run(
        sessionID: UUID,
        prompt: String,
        broadcastContext: BroadcastContext? = nil,
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

        // Snapshot the provider and model so a Settings change cannot split one tool loop
        // across two models. The next user turn may continue with the new selection.
        let activeModel = try await service.activeModel()
        let provider = activeModel.provider
        let modelID = activeModel.modelID
        let directActionMode = AIToolDefinitions.isDirectActionPrompt(trimmedPrompt)
        // A provider that binds reasoning to the tool set keeps all tools; direct-action mode
        // then only caps the iterations.
        let activeToolDefinitions = directActionMode && !provider.requiresStableToolSet
            ? AIToolDefinitions.directActionToolDefinitions(from: service.toolDefinitions)
            : service.toolDefinitions
        let iterationLimit = directActionMode
            ? min(service.maxToolIterations, 15)
            : service.maxToolIterations
        Self.logger.debug(
            "[\(traceID, privacy: .public)] turn_mode direct_action=\(directActionMode) tools=\(activeToolDefinitions.count) iteration_limit=\(iterationLimit)"
        )

        var conversationState = service.persistConversationContext
            ? service.conversationContext.state(for: sessionID) ?? AIConversationState()
            : AIConversationState()
        let priorModelID = conversationState.lastModelID
        conversationState.prepare(for: modelID)
        if service.persistConversationContext, priorModelID != nil, priorModelID != modelID {
            service.conversationContext.update(state: conversationState, for: sessionID)
        }

        let screenLines = service.sessionProvider.shellBuffers[sessionID] ?? []
        let screenSnapshot = screenLines.suffix(20).joined(separator: "\n")

        // Build session map context for broadcast mode
        var broadcastPreamble = ""
        if let ctx = broadcastContext, ctx.isBroadcasting {
            let sessionMap = ctx.allSessionIDs.map { id in
                let label = ctx.sessionLabels[id] ?? "Unknown"
                let isPrimary = id == ctx.primarySessionID ? " (primary)" : ""
                return "  - \(id.uuidString): \(label)\(isPrimary)"
            }.joined(separator: "\n")
            broadcastPreamble = "[Active broadcast sessions — \(ctx.allSessionIDs.count) sessions]\n\(sessionMap)\n\n"
        }

        let userMessageText: String
        if !screenSnapshot.isEmpty {
            userMessageText = broadcastPreamble + "[Current terminal screen — use this to identify the environment, OS, device type, and current path/mode before acting]\n```\n\(screenSnapshot)\n```\n\n\(trimmedPrompt)"
        } else {
            userMessageText = broadcastPreamble + trimmedPrompt
        }

        let systemPrompt = AIToolDefinitions.developerPrompt()
        let prefixFingerprint = provider.prefixFingerprint(systemPrompt: systemPrompt, tools: activeToolDefinitions)
        var currentTurn: [AITranscriptMessage] = [.user(userMessageText)]
        var totalToolCalls = 0

        for iteration in 1...iterationLimit {
            let iterationStart = DispatchTime.now().uptimeNanoseconds
            let messages = try conversationState.requestHistory(
                currentTurn: &currentTurn,
                prefixFingerprint: prefixFingerprint,
                contextLength: activeModel.contextLength
            ) {
                provider.estimatedRequestBytes(systemPrompt: systemPrompt, messages: $0, tools: activeToolDefinitions)
            }
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_start i=\(iteration) model=\(modelID, privacy: .public) messages=\(messages.count + 1)"
            )

            let assistantTurn = try await runWithTimeout(timeoutSeconds: service.requestTimeoutSeconds) {
                try await provider.complete(
                    model: modelID,
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: activeToolDefinitions
                ) { event in
                    Self.forward(streamEvent: event, to: streamHandler)
                }
            }
            try Task.checkCancellation()
            let responseMs = AIToolDefinitions.elapsedMillis(since: iterationStart)
            currentTurn.append(.assistant(assistantTurn))
            let toolCalls = assistantTurn.toolCalls
            let replyText = assistantTurn.text ?? ""
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_response i=\(iteration) response_ms=\(responseMs) tool_calls=\(toolCalls.count) text_chars=\(replyText.count)"
            )
            guard !toolCalls.isEmpty else {
                conversationState.appendTurn(currentTurn)
                if service.persistConversationContext {
                    service.conversationContext.update(state: conversationState, for: sessionID)
                }
                let totalMs = AIToolDefinitions.elapsedMillis(since: turnStart)
                Self.logger.info(
                    "[\(traceID, privacy: .public)] turn_complete session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public) iterations=\(iteration) tool_calls=\(totalToolCalls) total_ms=\(totalMs) reply_chars=\(replyText.count)"
                )
                return AIAgentReply(
                    text: replyText,
                    toolCallsExecuted: totalToolCalls
                )
            }

            totalToolCalls += toolCalls.count
            let toolStart = DispatchTime.now().uptimeNanoseconds
            let toolOutputs = await service.toolHandler.executeToolCalls(
                sessionID: sessionID,
                broadcastContext: broadcastContext,
                toolCalls: toolCalls,
                traceID: traceID
            )
            currentTurn += toolOutputs.map { .toolResult($0) }
            if service.persistConversationContext {
                var persisted = conversationState
                persisted.appendTurn(currentTurn)
                service.conversationContext.update(state: persisted, for: sessionID)
            }
            try Task.checkCancellation()
            let toolMs = AIToolDefinitions.elapsedMillis(since: toolStart)
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_tools i=\(iteration) tool_calls=\(toolCalls.count) tool_ms=\(toolMs)"
            )
        }

        let totalMs = AIToolDefinitions.elapsedMillis(since: turnStart)
        Self.logger.error(
            "[\(traceID, privacy: .public)] turn_failed_tool_loop session=\(AIToolDefinitions.shortSessionID(sessionID), privacy: .public) limit=\(iterationLimit) total_ms=\(totalMs)"
        )
        throw AIAgentServiceError.toolLoopExceeded(limit: iterationLimit)
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
