// Extracted from SSHTransport.swift
// swiftlint:disable file_length
import Foundation

#if DEBUG

nonisolated struct ActiveMockSession {
    var host: Host
    var details: SSHConnectionDetails
    var isAuthenticated: Bool
    var remoteNodes: [String: MockRemoteNode]
}

nonisolated struct MockRemoteNode {
    var isDirectory: Bool
    var data: Data
    var modifiedAt: Date
}

nonisolated enum MockServerProfile {
    case modern
    case legacyOnly

    nonisolated static func resolve(for host: Host) -> MockServerProfile {
        let lowered = host.hostname.lowercased()
        if lowered.contains("legacy") || lowered.contains("ios-old") || lowered.contains("router-old") {
            return .legacyOnly
        }
        return .modern
    }
}

actor MockSSHTransport: SSHTransporting {
    private var activeSessions: [UUID: ActiveMockSession] = [:]

    func connect(sessionID: UUID, to host: Host, jumpHostConfig: JumpHostConfig?) async throws -> SSHConnectionDetails {
        if let jumpConfig = jumpHostConfig {
            try await Task.sleep(for: .milliseconds(200))

            if jumpConfig.host.hostname.lowercased() == "refuse.local" {
                throw SSHTransportError.jumpHostConnectionFailed(
                    jumpHostname: jumpConfig.host.label,
                    message: "Connection refused by jump host."
                )
            }
            if jumpConfig.host.username.lowercased() == "invalid" {
                throw SSHTransportError.jumpHostAuthenticationFailed(
                    jumpHostname: jumpConfig.host.label
                )
            }
        }

        try await Task.sleep(for: .milliseconds(350))

        if host.hostname.lowercased() == "refuse.local" {
            throw SSHTransportError.connectionRefused
        }

        let profile = MockServerProfile.resolve(for: host)
        let details = try negotiate(for: host, profile: profile)
        activeSessions[sessionID] = ActiveMockSession(
            host: host,
            details: details,
            isAuthenticated: false,
            remoteNodes: makeInitialRemoteNodes(for: host)
        )
        return details
    }

    func authenticate(sessionID: UUID, to host: Host, passwordOverride: String?, keyPassphraseOverride: String?) async throws {
        guard var session = activeSessions[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }
        if host.username.lowercased() == "invalid" {
            throw SSHTransportError.authenticationFailed
        }

        session.isAuthenticated = true
        activeSessions[sessionID] = session
    }

    func openShell(sessionID: UUID, pty: PTYConfiguration, enableAgentForwarding: Bool) async throws -> any SSHShellChannel {
        guard let state = activeSessions[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }
        guard state.isAuthenticated else {
            throw SSHTransportError.authenticationFailed
        }

        return await MockSSHShellChannel(host: state.host, details: state.details, pty: pty)
    }

    func listDirectory(sessionID: UUID, path: String) async throws -> [SFTPDirectoryEntry] {
        guard let session = activeSessions[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }
        guard session.isAuthenticated else {
            throw SSHTransportError.authenticationFailed
        }

        let directoryPath = Self.normalizeRemotePath(path)
        guard let node = session.remoteNodes[directoryPath], node.isDirectory else {
            throw SSHTransportError.transportFailure(message: "Remote directory does not exist: \(directoryPath)")
        }

        let prefix = directoryPath == "/" ? "/" : "\(directoryPath)/"
        var entriesByPath: [String: SFTPDirectoryEntry] = [:]

        for (path, node) in session.remoteNodes where path.hasPrefix(prefix) && path != directoryPath {
            let remainder = String(path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }

            guard let firstComponent = remainder.split(separator: "/", maxSplits: 1).first else {
                continue
            }

            let name = String(firstComponent)
            let childPath = Self.joinRemotePath(directoryPath, name)

            if remainder.contains("/") {
                if entriesByPath[childPath] == nil {
                    entriesByPath[childPath] = SFTPDirectoryEntry(
                        path: childPath,
                        name: name,
                        isDirectory: true,
                        size: 0,
                        permissions: 0o755,
                        modifiedAt: nil
                    )
                }
                continue
            }

            entriesByPath[childPath] = SFTPDirectoryEntry(
                path: childPath,
                name: name,
                isDirectory: node.isDirectory,
                size: node.isDirectory ? 0 : Int64(node.data.count),
                permissions: node.isDirectory ? 0o755 : 0o644,
                modifiedAt: node.modifiedAt
            )
        }

        return entriesByPath.values.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func uploadFile(sessionID: UUID, localPath: String, remotePath: String) async throws -> SFTPTransferResult {
        guard var session = activeSessions[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }
        guard session.isAuthenticated else {
            throw SSHTransportError.authenticationFailed
        }

        let localURL = URL(fileURLWithPath: localPath)
        let payload = try Data(contentsOf: localURL)
        let baseRemotePath = Self.normalizeRemotePath(remotePath)

        let finalRemotePath: String
        if remotePath.hasSuffix("/") || (session.remoteNodes[baseRemotePath]?.isDirectory == true) {
            finalRemotePath = Self.joinRemotePath(baseRemotePath, localURL.lastPathComponent)
        } else {
            finalRemotePath = baseRemotePath
        }

        ensureParentDirectoriesExist(for: finalRemotePath, in: &session.remoteNodes)
        session.remoteNodes[finalRemotePath] = MockRemoteNode(
            isDirectory: false,
            data: payload,
            modifiedAt: .now
        )
        activeSessions[sessionID] = session

        return SFTPTransferResult(
            bytesTransferred: Int64(payload.count),
            totalBytes: Int64(payload.count)
        )
    }

    func downloadFile(sessionID: UUID, remotePath: String, localPath: String) async throws -> SFTPTransferResult {
        guard let session = activeSessions[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }
        guard session.isAuthenticated else {
            throw SSHTransportError.authenticationFailed
        }

        let normalizedRemotePath = Self.normalizeRemotePath(remotePath)
        guard let remoteNode = session.remoteNodes[normalizedRemotePath], !remoteNode.isDirectory else {
            throw SSHTransportError.transportFailure(message: "Remote file does not exist: \(normalizedRemotePath)")
        }

        let localURL = URL(fileURLWithPath: localPath)
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try remoteNode.data.write(to: localURL, options: .atomic)

        return SFTPTransferResult(
            bytesTransferred: Int64(remoteNode.data.count),
            totalBytes: Int64(remoteNode.data.count)
        )
    }

    func openForwardChannel(sessionID: UUID, remoteHost: String, remotePort: UInt16, sourceHost: String, sourcePort: UInt16) async throws -> any SSHForwardChannel {
        guard let session = activeSessions[sessionID], session.isAuthenticated else {
            throw SSHTransportError.sessionNotFound
        }
        return await MockSSHForwardChannel()
    }

    func sendKeepalive(sessionID: UUID) async -> Bool {
        return activeSessions[sessionID] != nil
    }

    func disconnect(sessionID: UUID) async {
        activeSessions.removeValue(forKey: sessionID)
    }

    private func negotiate(for host: Host, profile: MockServerProfile) throws -> SSHConnectionDetails {
        switch profile {
        case .modern:
            return SSHConnectionDetails(
                negotiatedKEX: SSHAlgorithmPolicy.modern.keyExchange[0],
                negotiatedCipher: SSHAlgorithmPolicy.modern.ciphers[0],
                negotiatedHostKeyType: SSHAlgorithmPolicy.modern.hostKeys[0],
                negotiatedHostFingerprint: "mock-fingerprint-modern",
                usedLegacyAlgorithms: false,
                securityAdvisory: nil,
                backend: .mock
            )
        case .legacyOnly:
            guard host.legacyModeEnabled else {
                throw SSHTransportError.legacyAlgorithmsRequired(
                    host: host.label,
                    required: [.keyExchange, .cipher, .hostKey]
                )
            }

            return SSHConnectionDetails(
                negotiatedKEX: SSHAlgorithmPolicy.legacy.keyExchange[0],
                negotiatedCipher: SSHAlgorithmPolicy.legacy.ciphers[0],
                negotiatedHostKeyType: SSHAlgorithmPolicy.legacy.hostKeys[0],
                negotiatedHostFingerprint: "mock-fingerprint-legacy",
                usedLegacyAlgorithms: true,
                securityAdvisory: "This session uses legacy cryptography for compatibility with older infrastructure.",
                backend: .mock
            )
        }
    }

    private func makeInitialRemoteNodes(for host: Host) -> [String: MockRemoteNode] {
        let now = Date()
        var nodes: [String: MockRemoteNode] = [
            "/": MockRemoteNode(isDirectory: true, data: Data(), modifiedAt: now),
            "/etc": MockRemoteNode(isDirectory: true, data: Data(), modifiedAt: now),
            "/var": MockRemoteNode(isDirectory: true, data: Data(), modifiedAt: now),
            "/home": MockRemoteNode(isDirectory: true, data: Data(), modifiedAt: now),
            "/home/\(host.username)": MockRemoteNode(isDirectory: true, data: Data(), modifiedAt: now)
        ]

        nodes["/etc/motd"] = MockRemoteNode(
            isDirectory: false,
            data: Data("Welcome to ProSSH mock SFTP.\n".utf8),
            modifiedAt: now
        )
        nodes["/home/\(host.username)/readme.txt"] = MockRemoteNode(
            isDirectory: false,
            data: Data("This is a simulated remote filesystem.\n".utf8),
            modifiedAt: now
        )
        nodes["/var/log"] = MockRemoteNode(isDirectory: true, data: Data(), modifiedAt: now)
        nodes["/var/log/system.log"] = MockRemoteNode(
            isDirectory: false,
            data: Data("mock log line 1\nmock log line 2\n".utf8),
            modifiedAt: now
        )
        return nodes
    }

    private func ensureParentDirectoriesExist(
        for remoteFilePath: String,
        in nodes: inout [String: MockRemoteNode]
    ) {
        var current = Self.parentRemotePath(of: remoteFilePath)
        while let path = current {
            if nodes[path] == nil {
                nodes[path] = MockRemoteNode(isDirectory: true, data: Data(), modifiedAt: .now)
            }
            current = Self.parentRemotePath(of: path)
        }
    }

    nonisolated private static func normalizeRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }

        var parts = trimmed.split(separator: "/").map(String.init)
        parts.removeAll(where: { $0.isEmpty || $0 == "." })
        let normalized = "/" + parts.joined(separator: "/")
        if normalized.count > 1 && normalized.hasSuffix("/") {
            return String(normalized.dropLast())
        }
        return normalized
    }

    nonisolated private static func parentRemotePath(of path: String) -> String? {
        let normalized = normalizeRemotePath(path)
        guard normalized != "/" else {
            return nil
        }
        guard let slash = normalized.lastIndex(of: "/") else {
            return "/"
        }
        if slash == normalized.startIndex {
            return "/"
        }
        return String(normalized[..<slash])
    }

    nonisolated private static func joinRemotePath(_ base: String, _ name: String) -> String {
        let normalizedBase = normalizeRemotePath(base)
        if normalizedBase == "/" {
            return "/\(name)"
        }
        return "\(normalizedBase)/\(name)"
    }
}

actor MockSSHShellChannel: SSHShellChannel {
    nonisolated let rawOutput: AsyncStream<Data>

    private var rawContinuation: AsyncStream<Data>.Continuation
    private let prompt: String
    private let dateFormatter: DateFormatter
    private var isClosed = false

    init(host: Host, details: SSHConnectionDetails, pty: PTYConfiguration) {
        var capturedRawContinuation: AsyncStream<Data>.Continuation?
        self.rawOutput = AsyncStream<Data> { continuation in
            capturedRawContinuation = continuation
        }
        guard let rawContinuation = capturedRawContinuation else {
            fatalError("Failed to create shell raw continuation")
        }

        self.rawContinuation = rawContinuation
        self.prompt = "\(host.username)@\(host.hostname) $"
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        rawContinuation.yield(Data("Connected with \(details.negotiatedCipher) over \(details.negotiatedKEX)".utf8))
        rawContinuation.yield(Data("PTY allocated: \(pty.terminalType) \(pty.columns)x\(pty.rows)".utf8))
        if let advisory = details.securityAdvisory {
            rawContinuation.yield(Data("SECURITY WARNING: \(advisory)".utf8))
        }
        rawContinuation.yield(Data(prompt.utf8))
    }

    func send(_ input: String) async throws {
        if isClosed {
            return
        }

        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            yield(prompt)
            return
        }

        if normalized == "help" {
            yield("Commands: help, whoami, date, uname -a, show version, exit")
            yield(prompt)
            return
        }

        if normalized == "whoami" {
            if let username = prompt.split(separator: "@").first {
                yield(String(username))
            }
            yield(prompt)
            return
        }

        if normalized == "date" {
            yield(dateFormatter.string(from: .now))
            yield(prompt)
            return
        }

        if normalized == "uname -a" {
            yield("Linux prossh-sim 6.6.0 arm64 GNU/Linux")
            yield(prompt)
            return
        }

        if normalized == "show version" {
            yield("ProSSH Mock Network Device 15.2(7)E")
            yield(prompt)
            return
        }

        if normalized == "exit" {
            yield("Connection closed by remote host.")
            await close()
            return
        }

        yield("Executed: \(normalized)")
        yield(prompt)
    }

    func resizePTY(columns: Int, rows: Int) async throws {
        // Mock: no-op (no real PTY to resize)
    }

    func close() async {
        if isClosed {
            return
        }

        isClosed = true
        rawContinuation.finish()
    }

    private func yield(_ text: String) {
        rawContinuation.yield(Data(text.utf8))
    }
}

actor MockSSHForwardChannel: SSHForwardChannel {
    private var isClosed = false

    init() {}

    func read() async throws -> Data? {
        if isClosed { return nil }
        try await Task.sleep(for: .milliseconds(50))
        return nil
    }

    func write(_ data: Data) async throws {
        if isClosed {
            throw SSHTransportError.transportFailure(message: "Forward channel is closed.")
        }
    }

    var isOpen: Bool {
        !isClosed
    }

    func close() async {
        isClosed = true
    }
}

#endif
