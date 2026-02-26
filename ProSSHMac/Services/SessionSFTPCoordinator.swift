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
        try await uploadFile(sessionID: sessionID, localPath: localPath, remotePath: remotePath, progressHandler: nil)
    }

    func uploadFile(sessionID: UUID, localPath: String, remotePath: String, progressHandler: (@Sendable (Int64, Int64) -> Void)?) async throws -> SFTPTransferResult {
        guard let manager else { throw SSHTransportError.sessionNotFound }
        guard manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            throw SSHTransportError.sessionNotFound
        }
        return try await manager.transport.uploadFile(sessionID: sessionID, localPath: localPath, remotePath: remotePath, progressHandler: progressHandler)
    }

    func downloadFile(sessionID: UUID, remotePath: String, localPath: String) async throws -> SFTPTransferResult {
        try await downloadFile(sessionID: sessionID, remotePath: remotePath, localPath: localPath, progressHandler: nil)
    }

    func downloadFile(sessionID: UUID, remotePath: String, localPath: String, progressHandler: (@Sendable (Int64, Int64) -> Void)?) async throws -> SFTPTransferResult {
        guard let manager else { throw SSHTransportError.sessionNotFound }
        guard manager.sessions.contains(where: { $0.id == sessionID && $0.state == .connected }) else {
            throw SSHTransportError.sessionNotFound
        }
        return try await manager.transport.downloadFile(sessionID: sessionID, remotePath: remotePath, localPath: localPath, progressHandler: progressHandler)
    }
}
