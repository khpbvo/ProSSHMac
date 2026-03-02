// Extracted from OpenAIAgentService.swift
import Foundation

@MainActor final class AIConversationContext {
    private(set) var stateBySessionID: [UUID: LLMConversationState] = [:]

    init() {}
    nonisolated deinit {}

    func state(for sessionID: UUID) -> LLMConversationState? {
        stateBySessionID[sessionID]
    }

    func update(state: LLMConversationState?, for sessionID: UUID) {
        stateBySessionID[sessionID] = state
    }

    func clear(sessionID: UUID) {
        stateBySessionID.removeValue(forKey: sessionID)
    }
}
