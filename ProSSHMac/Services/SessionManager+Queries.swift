// Extracted from SessionManager.swift
import Foundation

extension SessionManager {
    func activeSession(for hostID: UUID) -> Session? {
        sessions.first(where: { $0.hostID == hostID && $0.state == .connected })
    }

    /// Returns the most relevant session for a host, prioritizing by state:
    /// connected > connecting > most-recently-ended (disconnected/failed).
    func mostRelevantSession(for hostID: UUID) -> Session? {
        let hostSessions = sessions.filter { $0.hostID == hostID }
        return hostSessions.first(where: { $0.state == .connected })
            ?? hostSessions.first(where: { $0.state == .connecting })
            ?? hostSessions
                .filter { $0.state == .disconnected || $0.state == .failed }
                .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
                .first
    }

    /// Total bytes received + sent for a session.
    func totalTraffic(for sessionID: UUID) -> (received: Int64, sent: Int64) {
        (
            received: bytesReceivedBySessionID[sessionID] ?? 0,
            sent: bytesSentBySessionID[sessionID] ?? 0
        )
    }

    func recentCommandBlocks(sessionID: UUID, limit: Int = 20) async -> [CommandBlock] {
        await terminalHistoryIndex.recentCommands(sessionID: sessionID, limit: limit)
    }

    func searchCommandHistory(sessionID: UUID, query: String, limit: Int = 20) async -> [CommandBlock] {
        await terminalHistoryIndex.searchCommands(sessionID: sessionID, query: query, limit: limit)
    }

    func commandOutput(sessionID: UUID, blockID: UUID) async -> String? {
        await terminalHistoryIndex.commandOutput(sessionID: sessionID, blockID: blockID)
    }
}
