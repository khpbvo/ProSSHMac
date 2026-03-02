// LocalShellChannel.swift
// ProSSHMac
//
// Adapts LocalPTYProcess into the SSHShellChannel protocol used by SessionManager.

import Foundation
import Darwin

actor LocalShellChannel: SSHShellChannel {
    nonisolated let rawOutput: AsyncStream<Data>

    private let process: LocalPTYProcess

    // MARK: - Spawn

    static func spawn(
        columns: Int = 80,
        rows: Int = 24,
        shellPath: String? = nil,
        workingDirectory: String? = nil,
        shellIntegration: ShellIntegrationConfig = .init()
    ) async throws -> LocalShellChannel {
        let info = LocalShellBootstrap.resolveUserInfo()
        let resolvedShell = shellPath ?? info.shell

        guard FileManager.default.isExecutableFile(atPath: resolvedShell) else {
            throw LocalShellError.shellNotFound(resolvedShell)
        }

        let env = LocalShellBootstrap.buildEnvironment(shellPath: resolvedShell, shellIntegration: shellIntegration)
        let cwd = workingDirectory ?? info.home

        let process = try await LocalPTYProcess.spawn(
            columns: columns,
            rows: rows,
            shellPath: resolvedShell,
            environment: env,
            workingDirectory: cwd
        )

        return LocalShellChannel(process: process, rawOutput: process.rawOutput)
    }

    private init(process: LocalPTYProcess, rawOutput: AsyncStream<Data>) {
        self.process = process
        self.rawOutput = rawOutput
    }

    // MARK: - SSHShellChannel

    func send(_ input: String) async throws {
        try await process.send(bytes: Array(input.utf8))
    }

    func send(bytes: [UInt8]) async throws {
        try await process.send(bytes: bytes)
    }

    func resizePTY(columns: Int, rows: Int) async throws {
        try await process.resizePTY(columns: columns, rows: rows)
    }

    func close() async {
        await process.close()
    }
}

// MARK: - Errors

enum LocalShellError: LocalizedError {
    case ptyAllocationFailed
    case forkFailed
    case shellNotFound(String)
    case writeFailed(Int32)
    case resizeFailed(Int32)
    case platformUnsupported

    var errorDescription: String? {
        switch self {
        case .ptyAllocationFailed:
            return "Failed to allocate pseudo-terminal (PTY)."
        case .forkFailed:
            return "Failed to fork child process for local shell."
        case let .shellNotFound(path):
            return "Shell not found at path: \(path)"
        case let .writeFailed(code):
            return "Failed to write to PTY (\(code)): \(String(cString: strerror(code)))"
        case let .resizeFailed(code):
            return "Failed to resize PTY (\(code)): \(String(cString: strerror(code)))"
        case .platformUnsupported:
            return "Local terminal is not supported on this platform."
        }
    }
}
