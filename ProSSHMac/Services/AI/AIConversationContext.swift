import Foundation

struct AIConversationState: Sendable, Equatable {
    var turns: [[AITranscriptMessage]] = []
    var lastModelID: String?
    /// The provider's prefix fingerprint on the last request that had one.
    var lastPrefixFingerprint: String?

    /// A model switch drops OpenRouter reasoning. Claude's thinking blocks stay: the API drops
    /// those the new model can't read, and stripping them itself can make a request invalid.
    mutating func prepare(for modelID: String) {
        if let lastModelID, lastModelID != modelID {
            turns = turns.map { $0.map(Self.removingOpenRouterReasoning) }
        }
        lastModelID = modelID
    }

    /// The history for the next request. Fits it to the context budget, then, when that dropped
    /// turns or the prefix fingerprint changed (another system prompt or tool set), strips Claude's
    /// thinking blocks from every turn, including the current one: they are bound to the old
    /// prefix and can never be valid again.
    mutating func requestHistory(
        currentTurn: inout [AITranscriptMessage],
        prefixFingerprint: String?,
        contextLength: Int,
        size: ([AITranscriptMessage]) -> Int
    ) throws -> [AITranscriptMessage] {
        let turnCount = turns.count
        var history = try fittedHistory(currentTurn: currentTurn, contextLength: contextLength, size: size)
        let trimmed = turns.count < turnCount
        let prefixChanged = prefixFingerprint != nil
            && lastPrefixFingerprint != nil
            && prefixFingerprint != lastPrefixFingerprint
        if trimmed || prefixChanged {
            turns = turns.map { $0.map(Self.removingAnthropicThinking) }
            currentTurn = currentTurn.map(Self.removingAnthropicThinking)
            history = turns.flatMap { $0 } + currentTurn
        }
        if let prefixFingerprint { lastPrefixFingerprint = prefixFingerprint }
        return history
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

    private static func removingOpenRouterReasoning(_ message: AITranscriptMessage) -> AITranscriptMessage {
        guard case var .assistant(turn) = message, case .openRouter? = turn.reasoning else { return message }
        turn.reasoning = nil
        return .assistant(turn)
    }

    private static func removingAnthropicThinking(_ message: AITranscriptMessage) -> AITranscriptMessage {
        guard case var .assistant(turn) = message, case let .anthropic(blocks)? = turn.reasoning else { return message }
        turn.reasoning = .anthropic(blocks: blocks.filter { !$0.isThinking })
        return .assistant(turn)
    }
}

/// Conversation state per chat (conversation id), not per terminal session.
@MainActor final class AIConversationContext {
    private(set) var stateByConversationID: [UUID: AIConversationState] = [:]

    func state(for conversationID: UUID) -> AIConversationState? {
        stateByConversationID[conversationID]
    }

    func update(state: AIConversationState?, for conversationID: UUID) {
        stateByConversationID[conversationID] = state
    }

    func clear(conversationID: UUID) {
        stateByConversationID.removeValue(forKey: conversationID)
    }
}
