// Extracted from OpenAIAgentService.swift
import Foundation

@MainActor final class AIConversationContext {
    private(set) var previousResponseIDBySessionID: [UUID: String] = [:]

    init() {}
    nonisolated deinit {}

    func responseID(for sessionID: UUID) -> String? {
        previousResponseIDBySessionID[sessionID]
    }

    func update(responseID: String?, for sessionID: UUID) {
        previousResponseIDBySessionID[sessionID] = responseID
    }

    func clear(sessionID: UUID) {
        previousResponseIDBySessionID.removeValue(forKey: sessionID)
    }
}
