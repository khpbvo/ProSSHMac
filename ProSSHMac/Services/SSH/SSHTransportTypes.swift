// Extracted from SSHTransport.swift
import Foundation

enum SSHBackendKind: String, Codable, Sendable {
    case libssh
    case mock
}

enum SSHAlgorithmClass: String, Sendable {
    case keyExchange
    case cipher
    case hostKey
    case mac
}

struct PTYConfiguration: Sendable, Equatable {
    var columns: Int
    var rows: Int
    var terminalType: String

    static let `default` = PTYConfiguration(columns: 120, rows: 40, terminalType: "xterm-256color")
}

struct SSHConnectionDetails: Sendable {
    var negotiatedKEX: String
    var negotiatedCipher: String
    var negotiatedHostKeyType: String
    var negotiatedHostFingerprint: String
    var usedLegacyAlgorithms: Bool
    var securityAdvisory: String?
    var backend: SSHBackendKind
}

struct SFTPDirectoryEntry: Identifiable, Sendable, Hashable {
    var path: String
    var name: String
    var isDirectory: Bool
    var size: Int64
    var permissions: UInt32
    var modifiedAt: Date?

    var id: String {
        path
    }
}

struct SFTPTransferResult: Sendable, Hashable {
    var bytesTransferred: Int64
    var totalBytes: Int64
}

struct JumpHostConfig: Sendable {
    let host: Host
    let expectedFingerprint: String
}

enum SSHTransportError: LocalizedError, Sendable {
    case connectionRefused
    case authenticationFailed
    case sessionNotFound
    case legacyAlgorithmsRequired(host: String, required: [SSHAlgorithmClass])
    case transportFailure(message: String)
    case jumpHostVerificationFailed(jumpHostname: String, actualFingerprint: String)
    case jumpHostAuthenticationFailed(jumpHostname: String)
    case jumpHostConnectionFailed(jumpHostname: String, message: String)

    var errorDescription: String? {
        switch self {
        case .connectionRefused:
            return "The remote host refused the SSH connection."
        case .authenticationFailed:
            return "Authentication failed. Check credentials and try again."
        case .sessionNotFound:
            return "No active SSH session was found for this operation."
        case let .legacyAlgorithmsRequired(host, required):
            let requiredClasses = required.map(\.rawValue).joined(separator: ", ")
            return "\(host) requires legacy SSH algorithms (\(requiredClasses)). Enable Legacy Mode for this host to continue."
        case let .transportFailure(message):
            return message
        case let .jumpHostVerificationFailed(jumpHostname, actualFingerprint):
            return "Jump host '\(jumpHostname)' presented unrecognized fingerprint: \(actualFingerprint). Trust it first by connecting directly."
        case let .jumpHostAuthenticationFailed(jumpHostname):
            return "Authentication to jump host '\(jumpHostname)' failed. Verify credentials."
        case let .jumpHostConnectionFailed(jumpHostname, message):
            return "Connection via jump host '\(jumpHostname)' failed: \(message)"
        }
    }
}

nonisolated struct UncheckedOpaquePointer: @unchecked Sendable {
    let raw: OpaquePointer
}

enum SSHTransportFactory {
    static func makePreferredTransport() -> any SSHTransporting {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PROSSH_FORCE_MOCK"] == "1" {
            return MockSSHTransport()
        }
        #endif
        return LibSSHTransport()
    }
}
