import Foundation

enum SSHBackendKind: String, Codable {
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

enum SSHTransportError: LocalizedError {
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

protocol SSHShellChannel: AnyObject, Sendable {
    var output: AsyncStream<String> { get }
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

struct SSHAlgorithmPolicy {
    let keyExchange: [String]
    let hostKeys: [String]
    let ciphers: [String]
    let macs: [String]

    nonisolated static let modern = SSHAlgorithmPolicy(
        keyExchange: ["curve25519-sha256", "ecdh-sha2-nistp256", "diffie-hellman-group14-sha256"],
        hostKeys: ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-256"],
        ciphers: ["chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com", "aes128-ctr"],
        macs: ["hmac-sha2-256-etm@openssh.com", "hmac-sha2-512"]
    )

    nonisolated static let legacy = SSHAlgorithmPolicy(
        keyExchange: ["diffie-hellman-group14-sha1", "diffie-hellman-group1-sha1"],
        hostKeys: ["ssh-rsa", "ssh-dss"],
        ciphers: ["aes128-cbc", "3des-cbc"],
        macs: ["hmac-sha1", "hmac-sha1-96"]
    )
}

enum SSHTransportFactory {
    static func makePreferredTransport() -> any SSHTransporting {
        if ProcessInfo.processInfo.environment["PROSSH_FORCE_MOCK"] == "1" {
            return MockSSHTransport()
        }
        return LibSSHTransport()
    }
}

nonisolated private struct ActiveMockSession {
    var host: Host
    var details: SSHConnectionDetails
    var isAuthenticated: Bool
    var remoteNodes: [String: MockRemoteNode]
}

nonisolated private struct MockRemoteNode {
    var isDirectory: Bool
    var data: Data
    var modifiedAt: Date
}

nonisolated struct UncheckedOpaquePointer: @unchecked Sendable {
    let raw: OpaquePointer
}

nonisolated private enum MockServerProfile {
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
    nonisolated let output: AsyncStream<String>
    nonisolated let rawOutput: AsyncStream<Data>

    private var continuation: AsyncStream<String>.Continuation
    private var rawContinuation: AsyncStream<Data>.Continuation
    private let prompt: String
    private let dateFormatter: DateFormatter
    private var isClosed = false

    init(host: Host, details: SSHConnectionDetails, pty: PTYConfiguration) {
        var capturedContinuation: AsyncStream<String>.Continuation?
        self.output = AsyncStream<String> { continuation in
            capturedContinuation = continuation
        }
        var capturedRawContinuation: AsyncStream<Data>.Continuation?
        self.rawOutput = AsyncStream<Data> { continuation in
            capturedRawContinuation = continuation
        }
        guard let continuation = capturedContinuation else {
            fatalError("Failed to create shell continuation")
        }
        guard let rawContinuation = capturedRawContinuation else {
            fatalError("Failed to create shell raw continuation")
        }

        self.continuation = continuation
        self.rawContinuation = rawContinuation
        self.prompt = "\(host.username)@\(host.hostname) $"
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        continuation.yield("Connected with \(details.negotiatedCipher) over \(details.negotiatedKEX)")
        rawContinuation.yield(Data("Connected with \(details.negotiatedCipher) over \(details.negotiatedKEX)".utf8))
        continuation.yield("PTY allocated: \(pty.terminalType) \(pty.columns)x\(pty.rows)")
        rawContinuation.yield(Data("PTY allocated: \(pty.terminalType) \(pty.columns)x\(pty.rows)".utf8))
        if let advisory = details.securityAdvisory {
            continuation.yield("SECURITY WARNING: \(advisory)")
            rawContinuation.yield(Data("SECURITY WARNING: \(advisory)".utf8))
        }
        continuation.yield(prompt)
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
        continuation.finish()
        rawContinuation.finish()
    }

    private func yield(_ text: String) {
        continuation.yield(text)
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

nonisolated private struct LibSSHConnectResult {
    let handle: OpaquePointer
    let details: SSHConnectionDetails
}

nonisolated private enum LibSSHConnectFailure: LocalizedError {
    case failed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .failed(_, message):
            return message.isEmpty ? "SSH connection failed." : message
        }
    }
}

nonisolated private struct LibSSHAuthenticationMaterial {
    var password: String? = nil
    var privateKey: String? = nil
    var certificate: String? = nil
    var keyPassphrase: String? = nil
}

actor LibSSHTransport: SSHTransporting {
    private var handles: [UUID: OpaquePointer] = [:]

    func connect(sessionID: UUID, to host: Host, jumpHostConfig: JumpHostConfig?) async throws -> SSHConnectionDetails {
        if let existing = handles.removeValue(forKey: sessionID) {
            prossh_libssh_destroy(existing)
        }

        if let jumpConfig = jumpHostConfig {
            return try connectViaJumpHost(sessionID: sessionID, host: host, jumpConfig: jumpConfig)
        }

        return try connectDirect(sessionID: sessionID, host: host)
    }

    private func connectDirect(sessionID: UUID, host: Host) throws -> SSHConnectionDetails {
        do {
            let modern = try connectWithPolicy(host: host, policy: .modern, marksLegacy: false)
            handles[sessionID] = modern.handle
            return modern.details
        } catch let modernError as LibSSHConnectFailure {
            // If the error is a network-level failure (no route, timeout, refused, DNS),
            // skip legacy probing — no algorithm set will help with a network issue.
            if isNetworkLevelError(modernError) {
                throw mapLibSSHFailure(modernError)
            }

            if host.legacyModeEnabled {
                do {
                    let legacy = try connectWithPolicy(host: host, policy: .legacy, marksLegacy: true)
                    handles[sessionID] = legacy.handle
                    return legacy.details
                } catch let legacyError as LibSSHConnectFailure {
                    throw mapLibSSHFailure(legacyError)
                }
            }

            if let probe = try? connectWithPolicy(host: host, policy: .legacy, marksLegacy: true) {
                prossh_libssh_destroy(probe.handle)
                throw SSHTransportError.legacyAlgorithmsRequired(host: host.label, required: [.keyExchange, .cipher, .hostKey])
            }

            throw mapLibSSHFailure(modernError)
        }
    }

    /// Returns true if the connection failure is a network-level error where retrying
    /// with different algorithms would not help (e.g., host unreachable, DNS failure, timeout).
    private func isNetworkLevelError(_ failure: LibSSHConnectFailure) -> Bool {
        switch failure {
        case let .failed(_, message):
            let lower = message.lowercased()
            return lower.contains("no route to host")
                || lower.contains("network is unreachable")
                || lower.contains("host is unreachable")
                || lower.contains("connection timed out")
                || lower.contains("connection refused")
                || lower.contains("name or service not known")
                || lower.contains("temporary failure in name resolution")
                || lower.contains("no address associated")
                || lower.contains("network is down")
        }
    }

    private func connectViaJumpHost(sessionID: UUID, host: Host, jumpConfig: JumpHostConfig) throws -> SSHConnectionDetails {
        guard let handle = prossh_libssh_create() else {
            throw SSHTransportError.transportFailure(message: "Failed to allocate libssh session handle.")
        }

        let jumpHost = jumpConfig.host
        let jumpMaterial = try resolveAuthenticationMaterial(for: jumpHost, passwordOverride: nil)
        let jumpPolicy: SSHAlgorithmPolicy = jumpHost.legacyModeEnabled ? .legacy : .modern
        let targetPolicy: SSHAlgorithmPolicy = host.legacyModeEnabled ? .legacy : .modern

        let jumpKex = jumpPolicy.keyExchange.joined(separator: ",")
        let jumpCiphers = jumpPolicy.ciphers.joined(separator: ",")
        let jumpHostKeys = jumpPolicy.hostKeys.joined(separator: ",")
        let jumpMacs = jumpPolicy.macs.joined(separator: ",")

        let targetKex = targetPolicy.keyExchange.joined(separator: ",")
        let targetCiphers = targetPolicy.ciphers.joined(separator: ",")
        let targetSelectedHostKeys = host.pinnedHostKeyAlgorithms.isEmpty ? targetPolicy.hostKeys : host.pinnedHostKeyAlgorithms
        let targetHostKeys = targetSelectedHostKeys.joined(separator: ",")
        let targetMacs = targetPolicy.macs.joined(separator: ",")

        var errorBuffer = [CChar](repeating: 0, count: 512)

        var jumpCConfig = ProSSHJumpHostConfig()
        let connectResult: Int32 = jumpHost.hostname.withCString { jumpHostnamePtr in
            jumpHost.username.withCString { jumpUsernamePtr in
                jumpKex.withCString { jumpKexPtr in
                    jumpCiphers.withCString { jumpCiphersPtr in
                        jumpHostKeys.withCString { jumpHostKeysPtr in
                            jumpMacs.withCString { jumpMacsPtr in
                                jumpConfig.expectedFingerprint.withCString { expectedFPPtr in
                                    Self.withOptionalCString(jumpMaterial.password) { jumpPasswordPtr in
                                        Self.withOptionalCString(jumpMaterial.privateKey) { jumpPrivKeyPtr in
                                            Self.withOptionalCString(jumpMaterial.certificate) { jumpCertPtr in
                                                Self.withOptionalCString(jumpMaterial.keyPassphrase) { jumpPassphrasePtr in
                                                    host.hostname.withCString { hostnamePtr in
                                                        host.username.withCString { usernamePtr in
                                                            targetKex.withCString { kexPtr in
                                                                targetCiphers.withCString { ciphersPtr in
                                                                    targetHostKeys.withCString { hostKeysPtr in
                                                                        targetMacs.withCString { macsPtr in
                                                                            jumpCConfig.jump_hostname = jumpHostnamePtr
                                                                            jumpCConfig.jump_username = jumpUsernamePtr
                                                                            jumpCConfig.jump_port = jumpHost.port
                                                                            jumpCConfig.kex = jumpKexPtr
                                                                            jumpCConfig.ciphers = jumpCiphersPtr
                                                                            jumpCConfig.hostkeys = jumpHostKeysPtr
                                                                            jumpCConfig.macs = jumpMacsPtr
                                                                            jumpCConfig.timeout_seconds = 10
                                                                            jumpCConfig.expected_fingerprint = expectedFPPtr
                                                                            jumpCConfig.auth_method = jumpHost.authMethod.libsshAuthMethod
                                                                            jumpCConfig.password = jumpPasswordPtr
                                                                            jumpCConfig.private_key = jumpPrivKeyPtr
                                                                            jumpCConfig.certificate = jumpCertPtr
                                                                            jumpCConfig.key_passphrase = jumpPassphrasePtr

                                                                            return prossh_libssh_connect_with_jump(
                                                                                handle,
                                                                                hostnamePtr,
                                                                                host.port,
                                                                                usernamePtr,
                                                                                kexPtr,
                                                                                ciphersPtr,
                                                                                hostKeysPtr,
                                                                                macsPtr,
                                                                                10,
                                                                                &jumpCConfig,
                                                                                &errorBuffer,
                                                                                errorBuffer.count
                                                                            )
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if connectResult != 0 {
            let errorMessage = errorBuffer.asString
            let actualFP = Self.extractCTupleString(&jumpCConfig.actual_fingerprint, capacity: 256)
            prossh_libssh_destroy(handle)

            switch connectResult {
            case -10:
                throw SSHTransportError.jumpHostVerificationFailed(
                    jumpHostname: jumpHost.hostname,
                    actualFingerprint: actualFP
                )
            case -11:
                throw SSHTransportError.jumpHostVerificationFailed(
                    jumpHostname: jumpHost.hostname,
                    actualFingerprint: actualFP
                )
            case -12:
                throw SSHTransportError.jumpHostAuthenticationFailed(jumpHostname: jumpHost.hostname)
            default:
                throw SSHTransportError.jumpHostConnectionFailed(
                    jumpHostname: jumpHost.hostname,
                    message: errorMessage.isEmpty ? "Connection via jump host failed." : errorMessage
                )
            }
        }

        handles[sessionID] = handle

        var kexBuffer = [CChar](repeating: 0, count: 128)
        var cipherBuffer = [CChar](repeating: 0, count: 128)
        var hostKeyBuffer = [CChar](repeating: 0, count: 128)
        var fingerprintBuffer = [CChar](repeating: 0, count: 256)

        _ = prossh_libssh_get_negotiated(
            handle,
            &kexBuffer, kexBuffer.count,
            &cipherBuffer, cipherBuffer.count,
            &hostKeyBuffer, hostKeyBuffer.count,
            &fingerprintBuffer, fingerprintBuffer.count
        )

        let usedLegacy = host.legacyModeEnabled
        return SSHConnectionDetails(
            negotiatedKEX: kexBuffer.asString,
            negotiatedCipher: cipherBuffer.asString,
            negotiatedHostKeyType: hostKeyBuffer.asString,
            negotiatedHostFingerprint: fingerprintBuffer.asString,
            usedLegacyAlgorithms: usedLegacy,
            securityAdvisory: usedLegacy ? "This session uses legacy cryptography for compatibility with older infrastructure." : nil,
            backend: .libssh
        )
    }

    func authenticate(sessionID: UUID, to host: Host, passwordOverride: String?, keyPassphraseOverride: String?) async throws {
        guard let handle = handles[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }

        let material = try resolveAuthenticationMaterial(for: host, passwordOverride: passwordOverride, keyPassphraseOverride: keyPassphraseOverride)
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let authResult = Self.withOptionalCString(material.password) { passwordPtr in
            Self.withOptionalCString(material.privateKey) { privateKeyPtr in
                Self.withOptionalCString(material.certificate) { certificatePtr in
                    Self.withOptionalCString(material.keyPassphrase) { keyPassphrasePtr in
                        prossh_libssh_authenticate(
                            handle,
                            host.authMethod.libsshAuthMethod,
                            passwordPtr,
                            privateKeyPtr,
                            certificatePtr,
                            keyPassphrasePtr,
                            &errorBuffer,
                            errorBuffer.count
                        )
                    }
                }
            }
        }

        if authResult != 0 {
            if authResult == -3 {
                throw SSHTransportError.authenticationFailed
            }
            let message = errorBuffer.asString
            throw SSHTransportError.transportFailure(message: message.isEmpty ? "SSH authentication failed." : message)
        }
    }

    func openShell(sessionID: UUID, pty: PTYConfiguration, enableAgentForwarding: Bool) async throws -> any SSHShellChannel {
        guard let handle = handles[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }

        return try await LibSSHShellChannel.create(
            handle: UncheckedOpaquePointer(raw: handle),
            pty: pty,
            enableAgentForwarding: enableAgentForwarding
        )
    }

    func listDirectory(sessionID: UUID, path: String) async throws -> [SFTPDirectoryEntry] {
        guard let handle = handles[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }

        var outputBuffer = [CChar](repeating: 0, count: 128 * 1024)
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let targetPath = Self.normalizeRemotePath(path)

        let result = targetPath.withCString { pathPtr in
            prossh_libssh_sftp_list_directory(
                handle,
                pathPtr,
                &outputBuffer,
                outputBuffer.count,
                &errorBuffer,
                errorBuffer.count
            )
        }

        if result != 0 {
            let message = errorBuffer.asString
            throw SSHTransportError.transportFailure(message: message.isEmpty ? "Failed to list remote directory." : message)
        }

        let listing = outputBuffer.asString
        return Self.parseSFTPListing(listing, basePath: targetPath)
    }

    func uploadFile(sessionID: UUID, localPath: String, remotePath: String) async throws -> SFTPTransferResult {
        guard let handle = handles[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }

        var bytesTransferred: Int64 = 0
        var totalBytes: Int64 = 0
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let targetPath = Self.normalizeRemotePath(remotePath)

        let result = localPath.withCString { localPtr in
            targetPath.withCString { remotePtr in
                prossh_libssh_sftp_upload_file(
                    handle,
                    localPtr,
                    remotePtr,
                    &bytesTransferred,
                    &totalBytes,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }

        if result != 0 {
            let message = errorBuffer.asString
            throw SSHTransportError.transportFailure(message: message.isEmpty ? "Failed to upload file via SFTP." : message)
        }

        return SFTPTransferResult(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
    }

    func downloadFile(sessionID: UUID, remotePath: String, localPath: String) async throws -> SFTPTransferResult {
        guard let handle = handles[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }

        var bytesTransferred: Int64 = 0
        var totalBytes: Int64 = 0
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let sourcePath = Self.normalizeRemotePath(remotePath)

        let result = sourcePath.withCString { remotePtr in
            localPath.withCString { localPtr in
                prossh_libssh_sftp_download_file(
                    handle,
                    remotePtr,
                    localPtr,
                    &bytesTransferred,
                    &totalBytes,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }

        if result != 0 {
            let message = errorBuffer.asString
            throw SSHTransportError.transportFailure(message: message.isEmpty ? "Failed to download file via SFTP." : message)
        }

        return SFTPTransferResult(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
    }

    func openForwardChannel(sessionID: UUID, remoteHost: String, remotePort: UInt16, sourceHost: String, sourcePort: UInt16) async throws -> any SSHForwardChannel {
        guard let handle = handles[sessionID] else {
            throw SSHTransportError.sessionNotFound
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let fwdPtr: OpaquePointer? = remoteHost.withCString { remoteHostPtr in
            sourceHost.withCString { sourceHostPtr in
                prossh_forward_channel_open(
                    handle,
                    remoteHostPtr,
                    remotePort,
                    sourceHostPtr,
                    sourcePort,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }

        guard let fwdPtr else {
            let message = errorBuffer.asString
            throw SSHTransportError.transportFailure(message: message.isEmpty ? "Failed to open forward channel." : message)
        }

        return LibSSHForwardChannel(pointer: UncheckedOpaquePointer(raw: fwdPtr))
    }

    func sendKeepalive(sessionID: UUID) async -> Bool {
        guard let handle = handles[sessionID] else {
            return false
        }
        let result = prossh_libssh_send_keepalive(handle)
        return result == 0
    }

    func disconnect(sessionID: UUID) async {
        guard let handle = handles.removeValue(forKey: sessionID) else {
            return
        }
        prossh_libssh_destroy(handle)
    }

    /// Forces the kernel to re-evaluate the route to a hostname by performing a throwaway
    /// UDP `connect()` + immediate close. This clears the kernel's negative route cache
    /// (EHOSTUNREACH memoization) that can persist within a process even after the network
    /// recovers, which is the root cause of "No route to host" errors surviving across
    /// manual reconnection attempts until the app process is restarted.
    nonisolated private func flushRouteCache(hostname: String, port: UInt16) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_family = AF_UNSPEC

        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)

        let status = getaddrinfo(hostname, portString, &hints, &result)
        guard status == 0, let addrList = result else {
            if let result { freeaddrinfo(result) }
            return
        }
        defer { freeaddrinfo(addrList) }

        // Try each resolved address — a brief UDP connect()+close forces the kernel
        // to re-evaluate reachability for this destination.
        var info: UnsafeMutablePointer<addrinfo>? = addrList
        while let ai = info {
            let sock = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if sock >= 0 {
                // Non-blocking connect to avoid delays; result doesn't matter.
                var flags = fcntl(sock, F_GETFL)
                if flags >= 0 {
                    flags |= O_NONBLOCK
                    _ = fcntl(sock, F_SETFL, flags)
                }
                _ = Darwin.connect(sock, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
                close(sock)
            }
            info = ai.pointee.ai_next
        }
    }

    private func connectWithPolicy(
        host: Host,
        policy: SSHAlgorithmPolicy,
        marksLegacy: Bool
    ) throws -> LibSSHConnectResult {
        // Flush the kernel's negative route cache before every TCP connection attempt.
        // This prevents stale EHOSTUNREACH from blocking reconnections.
        flushRouteCache(hostname: host.hostname, port: host.port)

        guard let handle = prossh_libssh_create() else {
            throw LibSSHConnectFailure.failed(code: -100, message: "Failed to allocate libssh session handle.")
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let keyExchange = policy.keyExchange.joined(separator: ",")
        let ciphers = policy.ciphers.joined(separator: ",")
        let selectedHostKeys = host.pinnedHostKeyAlgorithms.isEmpty ? policy.hostKeys : host.pinnedHostKeyAlgorithms
        let hostKeys = selectedHostKeys.joined(separator: ",")
        let macs = policy.macs.joined(separator: ",")

        let connectResult = host.hostname.withCString { hostnamePtr in
            host.username.withCString { usernamePtr in
                keyExchange.withCString { kexPtr in
                    ciphers.withCString { ciphersPtr in
                        hostKeys.withCString { hostKeysPtr in
                            macs.withCString { macsPtr in
                                prossh_libssh_connect(
                                    handle,
                                    hostnamePtr,
                                    host.port,
                                    usernamePtr,
                                    kexPtr,
                                    ciphersPtr,
                                    hostKeysPtr,
                                    macsPtr,
                                    10,
                                    &errorBuffer,
                                    errorBuffer.count
                                )
                            }
                        }
                    }
                }
            }
        }

        if connectResult != 0 {
            let errorMessage = errorBuffer.asString
            prossh_libssh_destroy(handle)
            throw LibSSHConnectFailure.failed(code: connectResult, message: errorMessage)
        }

        var kexBuffer = [CChar](repeating: 0, count: 128)
        var cipherBuffer = [CChar](repeating: 0, count: 128)
        var hostKeyBuffer = [CChar](repeating: 0, count: 128)
        var fingerprintBuffer = [CChar](repeating: 0, count: 256)

        _ = prossh_libssh_get_negotiated(
            handle,
            &kexBuffer,
            kexBuffer.count,
            &cipherBuffer,
            cipherBuffer.count,
            &hostKeyBuffer,
            hostKeyBuffer.count,
            &fingerprintBuffer,
            fingerprintBuffer.count
        )

        let details = SSHConnectionDetails(
            negotiatedKEX: kexBuffer.asString,
            negotiatedCipher: cipherBuffer.asString,
            negotiatedHostKeyType: hostKeyBuffer.asString,
            negotiatedHostFingerprint: fingerprintBuffer.asString,
            usedLegacyAlgorithms: marksLegacy,
            securityAdvisory: marksLegacy ? "This session uses legacy cryptography for compatibility with older infrastructure." : nil,
            backend: .libssh
        )

        return LibSSHConnectResult(handle: handle, details: details)
    }

    private func mapLibSSHFailure(_ failure: LibSSHConnectFailure) -> SSHTransportError {
        switch failure {
        case let .failed(code, message):
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedMessage = trimmedMessage.lowercased()

            if code == -2 {
                if normalizedMessage.contains("connection refused") {
                    return .connectionRefused
                }
                if !trimmedMessage.isEmpty {
                    return .transportFailure(message: trimmedMessage)
                }
                return .connectionRefused
            }
            if code == -3 {
                return .authenticationFailed
            }
            return .transportFailure(message: trimmedMessage.isEmpty ? "libssh transport failed." : trimmedMessage)
        }
    }

    nonisolated private func resolveAuthenticationMaterial(for host: Host, passwordOverride: String?, keyPassphraseOverride: String? = nil) throws -> LibSSHAuthenticationMaterial {
        switch host.authMethod {
        case .password:
            let normalizedPassword = passwordOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalizedPassword.isEmpty else {
                throw SSHTransportError.transportFailure(
                    message: "Password authentication requires entering a password before connecting."
                )
            }
            return LibSSHAuthenticationMaterial(password: normalizedPassword)
        case .keyboardInteractive:
            return LibSSHAuthenticationMaterial()
        case .publicKey:
            guard let keyReference = host.keyReference else {
                return LibSSHAuthenticationMaterial()
            }
            let privateKey = try resolvePrivateKey(reference: keyReference)
            let passphrase = keyPassphraseOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LibSSHAuthenticationMaterial(privateKey: privateKey, keyPassphrase: passphrase)
        case .certificate:
            guard let keyReference = host.keyReference else {
                throw SSHTransportError.transportFailure(
                    message: "Certificate authentication requires a host private key reference."
                )
            }
            guard let certificateReference = host.certificateReference else {
                throw SSHTransportError.transportFailure(
                    message: "Certificate authentication requires a host certificate reference."
                )
            }

            let privateKey = try resolvePrivateKey(reference: keyReference)
            let certificate = try resolveCertificate(reference: certificateReference)
            return LibSSHAuthenticationMaterial(
                privateKey: privateKey,
                certificate: certificate
            )
        }
    }

    nonisolated private func resolvePrivateKey(reference: UUID) throws -> String {
        let keys = try loadStoredKeys()
        guard let storedKey = keys.first(where: { $0.id == reference }) else {
            throw SSHTransportError.transportFailure(message: "Referenced SSH private key was not found.")
        }

        let privateKey = storedKey.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !privateKey.isEmpty else {
            throw SSHTransportError.transportFailure(
                message: "Referenced SSH key does not contain private key material."
            )
        }
        return privateKey
    }

    nonisolated private func resolveCertificate(reference: UUID) throws -> String {
        let certificates = try loadStoredCertificates()
        guard let certificate = certificates.first(where: { $0.id == reference }) else {
            throw SSHTransportError.transportFailure(message: "Referenced SSH certificate was not found.")
        }

        if let authorized = certificate.authorizedRepresentation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !authorized.isEmpty {
            return authorized
        }

        guard let keyType = Self.readSSHStringPrefix(from: certificate.rawCertificateData) else {
            throw SSHTransportError.transportFailure(
                message: "Referenced certificate is missing OpenSSH authorized representation."
            )
        }

        let base64 = certificate.rawCertificateData.base64EncodedString()
        let comment = certificate.keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        if comment.isEmpty {
            return "\(keyType) \(base64)"
        }
        return "\(keyType) \(base64) \(comment)"
    }

    nonisolated private func loadStoredKeys() throws -> [StoredSSHKey] {
        let fileURL = Self.applicationSupportFileURL(filename: "keys.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [StoredSSHKey].self,
            from: fileURL,
            fileManager: .default,
            decoder: decoder
        ) ?? []
    }

    nonisolated private func loadStoredCertificates() throws -> [SSHCertificate] {
        let fileURL = Self.applicationSupportFileURL(filename: "certificates.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [SSHCertificate].self,
            from: fileURL,
            fileManager: .default,
            decoder: decoder
        ) ?? []
    }

    nonisolated private static func applicationSupportFileURL(filename: String) -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return baseDirectory
            .appendingPathComponent("ProSSHV2", isDirectory: true)
            .appendingPathComponent(filename)
    }

    nonisolated private static func readSSHStringPrefix(from data: Data) -> String? {
        guard data.count >= 4 else {
            return nil
        }

        let length = data.prefix(4).reduce(0) { partial, byte in
            (partial << 8) | UInt32(byte)
        }

        guard length > 0 else {
            return nil
        }

        let requiredCount = 4 + Int(length)
        guard data.count >= requiredCount else {
            return nil
        }

        let stringData = data.subdata(in: 4..<requiredCount)
        return String(data: stringData, encoding: .utf8)
    }

    nonisolated private static func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let value else {
            return body(nil)
        }
        return value.withCString(body)
    }

    nonisolated private static func extractCTupleString<T>(_ tuple: inout T, capacity: Int) -> String {
        withUnsafeMutablePointer(to: &tuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { cPtr in
                String(cString: cPtr)
            }
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

    nonisolated private static func parseSFTPListing(_ listing: String, basePath: String) -> [SFTPDirectoryEntry] {
        let normalizedBase = normalizeRemotePath(basePath)
        var entries: [SFTPDirectoryEntry] = []

        for line in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 5 else {
                continue
            }

            let name = String(columns[0])
            let isDirectory = columns[1] == "1"
            let size = Int64(columns[2]) ?? 0
            let permissions = UInt32(columns[3]) ?? 0
            let mtime = TimeInterval(columns[4]) ?? 0

            let fullPath: String
            if normalizedBase == "/" {
                fullPath = "/\(name)"
            } else {
                fullPath = "\(normalizedBase)/\(name)"
            }

            entries.append(
                SFTPDirectoryEntry(
                    path: fullPath,
                    name: name,
                    isDirectory: isDirectory,
                    size: size,
                    permissions: permissions,
                    modifiedAt: mtime > 0 ? Date(timeIntervalSince1970: mtime) : nil
                )
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

nonisolated actor LibSSHShellChannel: SSHShellChannel {
    nonisolated let output: AsyncStream<String>
    nonisolated let rawOutput: AsyncStream<Data>

    private nonisolated(unsafe) let handle: OpaquePointer
    private nonisolated(unsafe) var continuation: AsyncStream<String>.Continuation
    private nonisolated(unsafe) var rawContinuation: AsyncStream<Data>.Continuation
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    private init(
        handle: OpaquePointer,
        continuation: AsyncStream<String>.Continuation,
        output: AsyncStream<String>,
        rawContinuation: AsyncStream<Data>.Continuation,
        rawOutput: AsyncStream<Data>
    ) {
        self.handle = handle
        self.continuation = continuation
        self.output = output
        self.rawContinuation = rawContinuation
        self.rawOutput = rawOutput
    }

    nonisolated static func create(
        handle: UncheckedOpaquePointer,
        pty: PTYConfiguration,
        enableAgentForwarding: Bool
    ) async throws -> LibSSHShellChannel {
        var capturedContinuation: AsyncStream<String>.Continuation?
        let output = AsyncStream<String> { continuation in
            capturedContinuation = continuation
        }
        var capturedRawContinuation: AsyncStream<Data>.Continuation?
        let rawOutput = AsyncStream<Data> { continuation in
            capturedRawContinuation = continuation
        }
        guard let continuation = capturedContinuation else {
            throw SSHTransportError.transportFailure(message: "Failed to initialize shell output stream.")
        }
        guard let rawContinuation = capturedRawContinuation else {
            throw SSHTransportError.transportFailure(message: "Failed to initialize shell raw output stream.")
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let openResult = pty.terminalType.withCString { termPtr in
            prossh_libssh_open_shell(
                handle.raw,
                Int32(pty.columns),
                Int32(pty.rows),
                termPtr,
                enableAgentForwarding,
                &errorBuffer,
                errorBuffer.count
            )
        }

        if openResult != 0 {
            throw SSHTransportError.transportFailure(message: errorBuffer.asString)
        }

        let channel = LibSSHShellChannel(
            handle: handle.raw,
            continuation: continuation,
            output: output,
            rawContinuation: rawContinuation,
            rawOutput: rawOutput
        )
        await channel.startReaderTask()
        return channel
    }

    private func startReaderTask() {
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func send(_ input: String) async throws {
        if isClosed {
            return
        }

        let payload = Array(input.utf8)
        if payload.isEmpty {
            return
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let writeResult = payload.withUnsafeBytes { bytes in
            let ptr = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
            return prossh_libssh_channel_write(
                handle,
                ptr,
                bytes.count,
                &errorBuffer,
                errorBuffer.count
            )
        }

        if writeResult != 0 {
            throw SSHTransportError.transportFailure(message: errorBuffer.asString)
        }
    }

    func resizePTY(columns: Int, rows: Int) async throws {
        guard !isClosed else { return }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let result = prossh_libssh_channel_resize_pty(
            handle,
            Int32(columns),
            Int32(rows),
            &errorBuffer,
            errorBuffer.count
        )

        if result != 0 {
            throw SSHTransportError.transportFailure(message: errorBuffer.asString)
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        readerTask?.cancel()
        readerTask = nil
        prossh_libssh_channel_close(handle)
        continuation.finish()
        rawContinuation.finish()
    }

    private func readLoop() async {
        while !Task.isCancelled && !isClosed {
            var buffer = [CChar](repeating: 0, count: 4096)
            var bytesRead = Int32(0)
            var isEOF = false
            var errorBuffer = [CChar](repeating: 0, count: 512)

            let readResult = prossh_libssh_channel_read(
                handle,
                &buffer,
                buffer.count,
                &bytesRead,
                &isEOF,
                &errorBuffer,
                errorBuffer.count
            )

            if readResult != 0 {
                let message = errorBuffer.asString
                if !message.isEmpty {
                    continuation.yield("I/O error: \(message)")
                }
                break
            }

            if bytesRead > 0 {
                let bytes = buffer.prefix(Int(bytesRead)).map { UInt8(bitPattern: $0) }
                rawContinuation.yield(Data(bytes))
                let chunk = String(decoding: bytes, as: UTF8.self)
                continuation.yield(chunk)
            }

            if isEOF {
                break
            }

            if bytesRead == 0 {
                try? await Task.sleep(for: .milliseconds(40))
            }
        }

        await close()
    }
}

nonisolated actor LibSSHForwardChannel: SSHForwardChannel {
    private nonisolated(unsafe) var pointer: OpaquePointer?

    init(pointer: UncheckedOpaquePointer) {
        self.pointer = pointer.raw
    }

    func read() async throws -> Data? {
        guard let ptr = pointer else { return nil }

        var buffer = [CChar](repeating: 0, count: 32768)
        var isEOF = false
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let bytesRead = prossh_forward_channel_read(
            ptr,
            &buffer,
            buffer.count,
            &isEOF,
            &errorBuffer,
            errorBuffer.count
        )

        if bytesRead < 0 {
            let message = errorBuffer.asString
            throw SSHTransportError.transportFailure(message: message)
        }

        if isEOF {
            return nil
        }

        if bytesRead == 0 {
            try await Task.sleep(for: .milliseconds(10))
            return Data()
        }

        let bytes = buffer.prefix(Int(bytesRead)).map { UInt8(bitPattern: $0) }
        return Data(bytes)
    }

    func write(_ data: Data) async throws {
        guard let ptr = pointer else {
            throw SSHTransportError.transportFailure(message: "Forward channel is closed.")
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let result = data.withUnsafeBytes { bytes -> Int32 in
            let basePtr = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
            return prossh_forward_channel_write(
                ptr,
                basePtr,
                bytes.count,
                &errorBuffer,
                errorBuffer.count
            )
        }

        if result != 0 {
            let message = errorBuffer.asString
            throw SSHTransportError.transportFailure(message: message)
        }
    }

    var isOpen: Bool {
        guard let ptr = pointer else { return false }
        return prossh_forward_channel_is_open(ptr) == 1
    }

    func close() async {
        guard let ptr = pointer else { return }
        prossh_forward_channel_close(ptr)
        pointer = nil
    }
}

private extension AuthMethod {
    nonisolated var libsshAuthMethod: ProSSHAuthMethod {
        switch self {
        case .password:
            return PROSSH_AUTH_PASSWORD
        case .publicKey:
            return PROSSH_AUTH_PUBLICKEY
        case .certificate:
            return PROSSH_AUTH_CERTIFICATE
        case .keyboardInteractive:
            return PROSSH_AUTH_KEYBOARD_INTERACTIVE
        }
    }
}

private extension Array where Element == CChar {
    nonisolated var asString: String {
        String(decoding: prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
