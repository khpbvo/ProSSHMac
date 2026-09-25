import Foundation

struct AIConversationState: Sendable, Equatable {
    var turns: [[OpenRouterMessage]] = []
    var lastModelID: String?

    mutating func prepare(for modelID: String) {
        if let lastModelID, lastModelID != modelID {
            turns = turns.map { $0.map { $0.removingReasoning() } }
        }
        lastModelID = modelID
    }

    mutating func replay(
        systemPrompt: String,
        currentTurn: [OpenRouterMessage],
        tools: [LLMToolDefinition],
        contextLength: Int
    ) throws -> [OpenRouterMessage] {
        let system = OpenRouterMessage.system(systemPrompt)
        let toolBytes = tools.reduce(0) { count, tool in
            count + tool.name.utf8.count + tool.description.utf8.count
                + ((try? JSONEncoder().encode(tool.parameters).count) ?? 0)
        }
        // Two UTF-8 bytes per estimated token, with 30% of context reserved for output.
        let byteBudget = Int(Double(max(1, contextLength)) * 1.4)
        func messages() -> [OpenRouterMessage] {
            [system] + turns.flatMap { $0 } + currentTurn
        }
        var result = messages()
        func size(_ messages: [OpenRouterMessage]) -> Int {
            ((try? JSONEncoder().encode(messages).count) ?? Int.max) + toolBytes
        }
        while size(result) > byteBudget && !turns.isEmpty {
            turns.removeFirst()
            result = messages()
        }
        guard size(result) <= byteBudget else { throw OpenRouterError.contextTooLarge }
        return result
    }

    mutating func appendTurn(_ messages: [OpenRouterMessage]) {
        guard !messages.isEmpty else { return }
        turns.append(messages)
    }
}

@MainActor final class AIConversationContext {
    private(set) var stateBySessionID: [UUID: AIConversationState] = [:]

    func state(for sessionID: UUID) -> AIConversationState? {
        stateBySessionID[sessionID]
    }

    func update(state: AIConversationState?, for sessionID: UUID) {
        stateBySessionID[sessionID] = state
    }

    func clear(sessionID: UUID) {
        stateBySessionID.removeValue(forKey: sessionID)
    }
}
