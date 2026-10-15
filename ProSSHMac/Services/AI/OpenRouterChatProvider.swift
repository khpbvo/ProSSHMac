import Foundation

/// Adapts `OpenRouterServicing` to the provider-neutral agent loop: maps the transcript to Chat
/// Completions messages and the completion back to an `AIAssistantTurn`.
@MainActor
struct OpenRouterChatProvider: AIChatProviding {
    let client: any OpenRouterServicing

    func estimatedRequestBytes(
        systemPrompt: String,
        messages: [AITranscriptMessage],
        tools: [LLMToolDefinition]
    ) -> Int {
        let toolBytes = tools.reduce(0) { count, tool in
            count + tool.name.utf8.count + tool.description.utf8.count
                + ((try? JSONEncoder().encode(tool.parameters).count) ?? 0)
        }
        let wire = Self.wireMessages(systemPrompt: systemPrompt, messages: messages)
        return ((try? JSONEncoder().encode(wire).count) ?? Int.max) + toolBytes
    }

    func complete(
        model: String,
        systemPrompt: String,
        messages: [AITranscriptMessage],
        tools: [LLMToolDefinition],
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> AIAssistantTurn {
        let completion = try await client.complete(
            model: model,
            messages: Self.wireMessages(systemPrompt: systemPrompt, messages: messages),
            tools: tools,
            onEvent: onEvent
        )
        guard let choice = completion.choices.first else { throw OpenRouterError.invalidResponse }
        return Self.assistantTurn(from: choice.message)
    }

    // MARK: - Mapping

    static func wireMessages(systemPrompt: String, messages: [AITranscriptMessage]) -> [OpenRouterMessage] {
        [.system(systemPrompt)] + messages.map(wireMessage)
    }

    static func wireMessage(_ message: AITranscriptMessage) -> OpenRouterMessage {
        switch message {
        case let .user(text):
            return .user(text)
        case let .toolResult(output):
            return .tool(output.output, callID: output.callID)
        case let .assistant(turn):
            var details: [LLMJSONValue]?
            var reasoning: String?
            if case let .openRouter(storedDetails, storedText)? = turn.reasoning {
                details = storedDetails
                reasoning = storedText
            }
            return OpenRouterMessage(
                role: "assistant",
                content: turn.text,
                toolCalls: turn.toolCalls.isEmpty ? nil : turn.toolCalls.map {
                    OpenRouterToolCall(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments))
                },
                reasoningDetails: details,
                reasoning: reasoning
            )
        }
    }

    static func assistantTurn(from message: OpenRouterMessage) -> AIAssistantTurn {
        let hasReasoning = message.reasoningDetails != nil || message.reasoning != nil
        return AIAssistantTurn(
            text: message.content,
            toolCalls: (message.toolCalls ?? []).map {
                LLMToolCall(id: $0.id, name: $0.function.name, arguments: $0.function.arguments)
            },
            reasoning: hasReasoning
                ? .openRouter(details: message.reasoningDetails, text: message.reasoning)
                : nil
        )
    }
}
