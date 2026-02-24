// swiftlint:disable file_length
import Foundation






// safe: OpaquePointer is a C session handle owned exclusively
// by LibSSHTransport's actor-isolated `handles` dict; never shared across actors.
nonisolated private struct LibSSHConnectResult: @unchecked Sendable {
    let handle: OpaquePointer
    let details: SSHConnectionDetails
}

nonisolated private enum LibSSHConnectFailure: LocalizedError, Sendable {
    case failed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .failed(_, message):
            return message.isEmpty ? "SSH connection failed." : message
        }
    }
}

nonisolated private struct LibSSHAuthenticationMaterial: Sendable {
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



extension AuthMethod {
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
