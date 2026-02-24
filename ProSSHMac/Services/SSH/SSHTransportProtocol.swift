// Extracted from SSHTransport.swift
import Foundation

protocol SSHShellChannel: AnyObject, Sendable {
    var rawOutput: AsyncStream<Data> { get }
    func send(_ input: String) async throws
    func resizePTY(columns: Int, rows: Int) async throws
    func close() async
}

protocol SSHForwardChannel: AnyObject, Sendable {
    func read() async throws -> Data?
    func write(_ data: Data) async throws
    var isOpen: Bool { get async }
    func close() async
}

protocol SSHTransporting: Sendable {
    func connect(sessionID: UUID, to host: Host, jumpHostConfig: JumpHostConfig?) async throws -> SSHConnectionDetails
    func authenticate(sessionID: UUID, to host: Host, passwordOverride: String?, keyPassphraseOverride: String?) async throws
    func openShell(sessionID: UUID, pty: PTYConfiguration, enableAgentForwarding: Bool) async throws -> any SSHShellChannel
    func listDirectory(sessionID: UUID, path: String) async throws -> [SFTPDirectoryEntry]
    func uploadFile(sessionID: UUID, localPath: String, remotePath: String) async throws -> SFTPTransferResult
    func downloadFile(sessionID: UUID, remotePath: String, localPath: String) async throws -> SFTPTransferResult
    func openForwardChannel(sessionID: UUID, remoteHost: String, remotePort: UInt16, sourceHost: String, sourcePort: UInt16) async throws -> any SSHForwardChannel
    func sendKeepalive(sessionID: UUID) async -> Bool
    func disconnect(sessionID: UUID) async
}

extension SSHTransporting {
    func connect(sessionID: UUID, to host: Host) async throws -> SSHConnectionDetails {
        try await connect(sessionID: sessionID, to: host, jumpHostConfig: nil)
    }

    func authenticate(sessionID: UUID, to host: Host) async throws {
        try await authenticate(sessionID: sessionID, to: host, passwordOverride: nil, keyPassphraseOverride: nil)
    }

    func openShell(sessionID: UUID, pty: PTYConfiguration) async throws -> any SSHShellChannel {
        try await openShell(sessionID: sessionID, pty: pty, enableAgentForwarding: false)
    }
}
