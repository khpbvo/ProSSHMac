// Extracted from SessionManager.swift
import Foundation

@MainActor final class SessionSFTPCoordinator {
    weak var manager: SessionManager?

    init() {}

    nonisolated deinit {}

    func listRemoteDirectory(sessionID: UUID, path: String) async throws -> [SFTPDirectoryEntry] {
        guard let manager else { throw SSHTransportError.sessionNotFound }
        guard manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            throw SSHTransportError.sessionNotFound
        }
        return try await manager.transport.listDirectory(sessionID: sessionID, path: path)
    }

    func uploadFile(sessionID: UUID, localPath: String, remotePath: String) async throws -> SFTPTransferResult {
        guard let manager else { throw SSHTransportError.sessionNotFound }
        guard manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            throw SSHTransportError.sessionNotFound
        }
        return try await manager.transport.uploadFile(sessionID: sessionID, localPath: localPath, remotePath: remotePath)
    }

    func downloadFile(sessionID: UUID, remotePath: String, localPath: String) async throws -> SFTPTransferResult {
        guard let manager else { throw SSHTransportError.sessionNotFound }
        guard manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            throw SSHTransportError.sessionNotFound
        }
        return try await manager.transport.downloadFile(sessionID: sessionID, remotePath: remotePath, localPath: localPath)
    }
}
