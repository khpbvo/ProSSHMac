import Foundation

struct AIConversationState: Sendable, Equatable {
    var turns: [[AITranscriptMessage]] = []
    var lastModelID: String?

    mutating func prepare(for modelID: String) {
        if let lastModelID, lastModelID != modelID {
            turns = turns.map { $0.map(Self.removingReasoning) }
        }
        lastModelID = modelID
    }

    /// The history to send this request: earlier turns followed by `currentTurn`. Drops whole
    /// oldest turns until `size` fits the context budget, so a tool call is never split from its
    /// result.
    mutating func fittedHistory(
        currentTurn: [AITranscriptMessage],
        contextLength: Int,
        size: ([AITranscriptMessage]) -> Int
    ) throws -> [AITranscriptMessage] {
        // Two UTF-8 bytes per estimated token, with 30% of context reserved for output.
        let byteBudget = Int(Double(max(1, contextLength)) * 1.4)
        func messages() -> [AITranscriptMessage] {
            turns.flatMap { $0 } + currentTurn
        }
        var result = messages()
        while size(result) > byteBudget && !turns.isEmpty {
            turns.removeFirst()
            result = messages()
        }
        guard size(result) <= byteBudget else { throw OpenRouterError.contextTooLarge }
        return result
    }

    mutating func appendTurn(_ messages: [AITranscriptMessage]) {
        guard !messages.isEmpty else { return }
        turns.append(messages)
    }

    private static func removingReasoning(_ message: AITranscriptMessage) -> AITranscriptMessage {
        guard case var .assistant(turn) = message else { return message }
        turn.reasoning = nil
        return .assistant(turn)
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
