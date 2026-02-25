// Extracted from SSHConfigParser.swift
import Foundation

// MARK: - Mapping: SSHConfigEntry → Host

/// Maps parsed SSH config entries to ProSSHMac `Host` models.
///
/// This is where the SSH config semantics meet ProSSHMac's data model.
/// The mapper handles:
/// - Directive → Host field mapping
/// - Token expansion in paths and hostnames
/// - LocalForward parsing → PortForwardingRule
/// - ProxyJump → jumpHost resolution (by label or hostname)
/// - IdentityFile → keyReference resolution (by path suffix matching)
/// - Algorithm preferences mapping
/// - Global defaults inheritance (SSH first-match-wins semantics)
struct SSHConfigMapper: Sendable {

    /// Context needed for resolving cross-references during import.
    struct ResolutionContext: Sendable {
        /// Existing hosts in ProSSHMac (for jump host resolution by label/hostname).
        let existingHosts: [Host]

        /// Existing SSH keys in ProSSHMac (for IdentityFile → key reference resolution).
        let existingKeys: [StoredSSHKey]

        /// Hosts being imported in this batch (for ProxyJump referencing other imported hosts).
        /// Populated incrementally during multi-entry import.
        var importedHosts: [Host]

        init(existingHosts: [Host] = [], existingKeys: [StoredSSHKey] = [], importedHosts: [Host] = []) {
            self.existingHosts = existingHosts
            self.existingKeys = existingKeys
            self.importedHosts = importedHosts
        }
    }

    /// Result of mapping one SSHConfigEntry to a Host.
    struct MappingResult: Sendable {
        let host: Host
        let notes: [String]  // Informational notes about what was/wasn't mapped
    }

    private let tokenExpander = SSHConfigTokenExpander()

    /// Map a single SSHConfigEntry to a ProSSHMac Host.
    ///
    /// - Parameters:
    ///   - entry: The parsed config entry.
    ///   - globalDefaults: The `Host *` entry (applied as fallback for missing directives).
    ///   - context: Resolution context for cross-references.
    /// - Returns: A `MappingResult` with the mapped host and any informational notes.
    func mapEntry(
        _ entry: SSHConfigEntry,
        globalDefaults: SSHConfigEntry?,
        context: ResolutionContext
    ) -> MappingResult {
        var notes: [String] = []

        // Helper: resolve a directive with fallback to global defaults.
        func resolve(_ keyword: String) -> String? {
            entry.firstValue(for: keyword) ?? globalDefaults?.firstValue(for: keyword)
        }

        func resolveAll(_ keyword: String) -> [String] {
            let local = entry.allValues(for: keyword)
            return local.isEmpty
                ? (globalDefaults?.allValues(for: keyword) ?? [])
                : local
        }

        // --- Core fields ---

        let label = entry.patterns.first ?? "Unnamed Host"
        let rawHostname = resolve("hostname") ?? label  // SSH falls back to the Host alias
        let username = resolve("user") ?? NSUserName()   // SSH falls back to local user
        let port = resolve("port").flatMap(UInt16.init) ?? 22

        // Build token expansion context.
        let expandCtx = SSHConfigTokenExpander.Context(
            hostname: rawHostname,
            username: username,
            port: port
        )

        let hostname = tokenExpander.expand(rawHostname, context: expandCtx)

        // --- Auth method + key reference ---

        var authMethod: AuthMethod = .publicKey  // Default for SSH
        var keyReference: UUID?

        let identityFiles = resolveAll("identityfile")
        if !identityFiles.isEmpty {
            let expandedPaths = identityFiles.map { tokenExpander.expand($0, context: expandCtx) }
            keyReference = resolveKeyReference(paths: expandedPaths, keys: context.existingKeys)

            if keyReference == nil && !expandedPaths.isEmpty {
                notes.append("IdentityFile \(expandedPaths.joined(separator: ", ")) — no matching key found in ProSSHMac KeyForge. Import the key separately.")
            }

            authMethod = .publicKey
        }

        // If PreferredAuthentications is set, try to pick the best match.
        if let prefAuth = resolve("preferredauthentications") {
            let methods = prefAuth.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if let first = methods.first {
                switch first {
                case "password":             authMethod = .password
                case "publickey":            authMethod = .publicKey
                case "keyboard-interactive": authMethod = .keyboardInteractive
                default: break
                }
            }
        }

        // --- Agent forwarding ---

        let agentForwarding = resolve("forwardagent")
            .map { $0.lowercased() == "yes" }
            ?? false

        // --- Port forwarding rules ---

        let localForwards = resolveAll("localforward")
        let portForwardingRules = localForwards.compactMap { parseLocalForward($0) }

        let remoteForwards = resolveAll("remoteforward")
        if !remoteForwards.isEmpty {
            notes.append("RemoteForward rules found (\(remoteForwards.count)) — ProSSHMac currently supports local forwards only. Remote forwards were skipped.")
        }

        // --- Jump host (ProxyJump) ---

        var jumpHostID: UUID?
        if let proxyJump = resolve("proxyjump") {
            // ProxyJump can be a comma-separated chain; we take the first hop.
            let firstHop = proxyJump.split(separator: ",").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? proxyJump

            jumpHostID = resolveJumpHost(firstHop, context: context)

            if jumpHostID == nil {
                notes.append("ProxyJump '\(firstHop)' — no matching host found. Create the jump host in ProSSHMac first, then set it manually.")
            }

            if proxyJump.contains(",") {
                notes.append("ProxyJump chain detected (\(proxyJump)). ProSSHMac supports single-hop jump hosts. Only the first hop was mapped.")
            }
        }

        // Fallback: check ProxyCommand for a simple `ssh -W` jump pattern.
        if jumpHostID == nil, let proxyCommand = resolve("proxycommand") {
            if let parsed = parseProxyCommandJump(proxyCommand) {
                jumpHostID = resolveJumpHost(parsed, context: context)
                if jumpHostID != nil {
                    notes.append("ProxyCommand parsed as jump host: '\(parsed)'")
                }
            }
        }

        // --- Algorithm preferences ---

        var algPrefs: AlgorithmPreferences?
        let kex = resolve("kexalgorithms")
        let hostKeys = resolve("hostkeyalgorithms")
        let ciphers = resolve("ciphers")
        let macs = resolve("macs")

        if kex != nil || ciphers != nil || macs != nil {
            algPrefs = AlgorithmPreferences(
                keyExchange: splitAlgorithmList(kex),
                hostKeys: splitAlgorithmList(hostKeys),
                ciphers: splitAlgorithmList(ciphers),
                macs: splitAlgorithmList(macs)
            )
        }

        let pinnedHostKeyAlgs = splitAlgorithmList(hostKeys)

        // --- Legacy mode detection ---

        // Heuristic: if they're forcing old ciphers or KEX, enable legacy mode.
        let legacyIndicators: Set<String> = [
            "diffie-hellman-group1-sha1",
            "diffie-hellman-group-exchange-sha1",
            "3des-cbc",
            "aes128-cbc",
            "aes256-cbc",
            "ssh-rsa",
            "ssh-dss"
        ]
        let allConfiguredAlgs = (splitAlgorithmList(kex) + splitAlgorithmList(ciphers) + splitAlgorithmList(hostKeys))
        let legacyMode = allConfiguredAlgs.contains(where: legacyIndicators.contains)

        // --- Folder (from Host pattern grouping heuristic) ---

        // If the label contains a slash or dash prefix that looks like a group,
        // extract it as a folder. E.g., "prod/web-01" → folder: "prod", label: "web-01"
        let (folder, cleanLabel) = extractFolderFromLabel(label)

        // --- Tags ---

        // No SSH config equivalent, but we can infer from patterns.
        var tags: [String] = []
        if entry.patterns.count > 1 {
            // Multiple patterns on one Host line — use extra patterns as tags.
            tags = Array(entry.patterns.dropFirst())
            notes.append("Additional Host patterns mapped as tags: \(tags.joined(separator: ", "))")
        }

        // --- Unsupported directives → notes ---

        let unsupportedKeywords: Set<String> = [
            "sendenv", "setenv", "requesttty", "permitlocalcommand",
            "localcommand", "visualhostkey", "pubkeyacceptedalgorithms",
            "addkeystoagent", "identitiesonly", "userknownhostsfile",
            "globalknownhostsfile", "stricthostkeychecking",
            "updatehostkeys", "canonicalizehostname",
            "dynamicforward", "gatewayports", "compression",
            "serveralivecountmax", "serveraliveinterval",
            "connectionattempts", "connecttimeout",
            "controlmaster", "controlpath", "controlpersist"
        ]

        let presentUnsupported = entry.directives
            .map(\.keyword)
            .filter { unsupportedKeywords.contains($0) }
        let uniqueUnsupported = Array(Set(presentUnsupported)).sorted()
        if !uniqueUnsupported.isEmpty {
            notes.append("Skipped directives: \(uniqueUnsupported.joined(separator: ", "))")
        }

        // --- Build the Host ---

        let host = Host(
            id: UUID(),
            label: cleanLabel,
            folder: folder,
            hostname: hostname,
            port: port,
            username: username,
            authMethod: authMethod,
            keyReference: keyReference,
            certificateReference: nil,
            passwordReference: nil,
            jumpHost: jumpHostID,
            algorithmPreferences: algPrefs,
            pinnedHostKeyAlgorithms: pinnedHostKeyAlgs,
            agentForwardingEnabled: agentForwarding,
            portForwardingRules: portForwardingRules,
            legacyModeEnabled: legacyMode,
            tags: tags,
            notes: notes.isEmpty ? nil : notes.joined(separator: "\n"),
            lastConnected: nil,
            createdAt: .now
        )

        return MappingResult(host: host, notes: notes)
    }

    /// Import all concrete entries from a parse result into Host models.
    ///
    /// Processes entries in order, building up the resolution context incrementally
    /// so that later entries can reference earlier ones as jump hosts.
    func importAll(
        from parseResult: SSHConfigParseResult,
        existingHosts: [Host] = [],
        existingKeys: [StoredSSHKey] = []
    ) -> [MappingResult] {
        var context = ResolutionContext(
            existingHosts: existingHosts,
            existingKeys: existingKeys
        )

        let globalDefaults = parseResult.globalDefaults

        var results: [MappingResult] = []

        for entry in parseResult.concreteHosts {
            let result = mapEntry(entry, globalDefaults: globalDefaults, context: context)
            context.importedHosts.append(result.host)
            results.append(result)
        }

        return results
    }

    // MARK: - Private Resolution Helpers

    /// Resolve an IdentityFile path to a key UUID by matching the filename against stored keys.
    ///
    /// Matching strategy (first match wins):
    /// 1. Exact path match against `importedFrom`
    /// 2. Filename match (e.g., `id_ed25519` matches a key imported from `~/.ssh/id_ed25519`)
    /// 3. Label match (e.g., key labeled "id_ed25519")
    private func resolveKeyReference(paths: [String], keys: [StoredSSHKey]) -> UUID? {
        for path in paths {
            let filename = (path as NSString).lastPathComponent

            // 1. Exact importedFrom match.
            if let match = keys.first(where: { $0.metadata.importedFrom == path }) {
                return match.metadata.id
            }

            // 2. Filename suffix match on importedFrom.
            if let match = keys.first(where: {
                ($0.metadata.importedFrom as NSString?)?.lastPathComponent == filename
            }) {
                return match.metadata.id
            }

            // 3. Label match.
            if let match = keys.first(where: {
                $0.metadata.label.lowercased() == filename.lowercased()
            }) {
                return match.metadata.id
            }
        }
        return nil
    }

    /// Resolve a jump host reference to a Host UUID.
    ///
    /// Matching strategy (first match wins):
    /// 1. Label match in imported hosts (this batch)
    /// 2. Label match in existing hosts
    /// 3. Hostname match in imported hosts
    /// 4. Hostname match in existing hosts
    private func resolveJumpHost(_ reference: String, context: ResolutionContext) -> UUID? {
        let ref = reference.trimmingCharacters(in: .whitespaces)

        // Parse `user@host:port` or just `host`.
        let hostPart: String
        if ref.contains("@") {
            hostPart = String(ref.split(separator: "@", maxSplits: 1).last ?? Substring(ref))
        } else {
            hostPart = ref
        }
        let cleanHost = hostPart.split(separator: ":").first.map(String.init) ?? hostPart

        let allHosts = context.importedHosts + context.existingHosts

        // 1. Label match.
        if let match = allHosts.first(where: { $0.label.lowercased() == ref.lowercased() }) {
            return match.id
        }

        // 2. Hostname match.
        if let match = allHosts.first(where: { $0.hostname.lowercased() == cleanHost.lowercased() }) {
            return match.id
        }

        return nil
    }

    /// Parse a `LocalForward` value into a `PortForwardingRule`.
    ///
    /// Formats:
    /// - `8080 remote.host:80`
    /// - `127.0.0.1:8080 remote.host:80`
    /// - `[::1]:8080 remote.host:80`
    private func parseLocalForward(_ value: String) -> PortForwardingRule? {
        let parts = value.split(separator: " ", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }

        // Parse local side.
        let localPort: UInt16
        let localPart = parts[0]
        if let port = UInt16(localPart) {
            localPort = port
        } else {
            // Has a bind address: `addr:port` or `[addr]:port`
            let portStr = localPart.split(separator: ":").last.map(String.init) ?? localPart
            guard let port = UInt16(portStr) else { return nil }
            localPort = port
        }

        // Parse remote side: `host:port`
        let remotePart = parts[1]
        let remoteComponents = remotePart.split(separator: ":", maxSplits: 1)
        guard remoteComponents.count == 2,
              let remotePort = UInt16(remoteComponents[1]) else { return nil }
        let remoteHost = String(remoteComponents[0])

        return PortForwardingRule(
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            label: "Imported: \(localPort) → \(remoteHost):\(remotePort)"
        )
    }

    /// Try to parse a `ProxyCommand` as a jump host reference.
    ///
    /// Matches the common pattern: `ssh -W %h:%p jumphost`
    private func parseProxyCommandJump(_ command: String) -> String? {
        let parts = command.split(separator: " ").map(String.init)
        guard parts.count >= 4,
              parts[0].hasSuffix("ssh"),
              parts[1] == "-W",
              parts[2].contains("%h") else { return nil }
        return parts[3]
    }

    /// Split a comma-separated algorithm list, stripping any `+` or `-` prefix modifiers.
    private func splitAlgorithmList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }

        // SSH config allows `+algo` (append), `-algo` (remove), `^algo` (prepend).
        // We strip the modifiers and return the raw algorithm names — ProSSHMac
        // doesn't support incremental algorithm modification.
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { alg in
                if alg.hasPrefix("+") || alg.hasPrefix("-") || alg.hasPrefix("^") {
                    return String(alg.dropFirst())
                }
                return alg
            }
            .filter { !$0.isEmpty }
    }

    /// Extract a folder from a label that uses slash or prefix grouping.
    ///
    /// Examples:
    /// - `"prod/web-01"` → folder: `"prod"`, label: `"web-01"`
    /// - `"web-01"` → folder: `nil`, label: `"web-01"`
    private func extractFolderFromLabel(_ label: String) -> (String?, String) {
        if let slashIndex = label.lastIndex(of: "/") {
            let folder = String(label[label.startIndex..<slashIndex])
                .trimmingCharacters(in: .whitespaces)
            let name = String(label[label.index(after: slashIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if !folder.isEmpty && !name.isEmpty {
                return (folder, name)
            }
        }
        return (nil, label)
    }
}
