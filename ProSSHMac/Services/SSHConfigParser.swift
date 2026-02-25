// swiftlint:disable file_length
// SSHConfigParser.swift
// SSH config import/export for ProSSHMac
//
// Parses ~/.ssh/config into intermediate SSHConfigEntry values,
// maps them to ProSSHMac Host models, and exports Hosts back to
// SSH config format. Pure value types — no side effects, fully testable.

import Foundation

// MARK: - Parsed Intermediate Representation

/// A single directive from an SSH config file (e.g., `HostName 10.0.0.1`).
struct SSHConfigDirective: Equatable, Sendable {
    let keyword: String          // Lowercased canonical form
    let originalKeyword: String  // Preserves original casing for export
    let arguments: String        // Raw argument string (not split)
    let lineNumber: Int
}

/// One `Host` or `Match` block from an SSH config file, plus all its directives.
/// Wildcard-only blocks (e.g., `Host *`) are captured as global defaults.
struct SSHConfigEntry: Equatable, Sendable {
    /// The pattern(s) from the `Host` line, e.g., ["web-*", "db-*"] or ["*"].
    let patterns: [String]

    /// Whether this came from a `Match` block (vs. a `Host` block).
    let isMatchBlock: Bool

    /// All directives within this block, in file order.
    let directives: [SSHConfigDirective]

    /// The line number where this block's Host/Match keyword appeared.
    let startLine: Int

    /// True if this is a `Host *` block (global defaults).
    var isGlobalDefaults: Bool {
        !isMatchBlock && patterns == ["*"]
    }

    /// Look up the first directive matching a keyword (case-insensitive).
    /// SSH config uses first-match semantics — the first value wins.
    func firstValue(for keyword: String) -> String? {
        let key = keyword.lowercased()
        return directives.first(where: { $0.keyword == key })?.arguments
    }

    /// Look up all directives matching a keyword (for multi-value keys like LocalForward).
    func allValues(for keyword: String) -> [String] {
        let key = keyword.lowercased()
        return directives.filter { $0.keyword == key }.map(\.arguments)
    }
}

/// Result of parsing an entire SSH config file.
struct SSHConfigParseResult: Sendable {
    /// All Host/Match blocks, in file order.
    let entries: [SSHConfigEntry]

    /// Lines that couldn't be parsed (with line numbers and reason).
    let warnings: [SSHConfigWarning]

    /// Global defaults (`Host *` block), if present.
    var globalDefaults: SSHConfigEntry? {
        entries.first(where: \.isGlobalDefaults)
    }

    /// Concrete host entries (excludes wildcards and Match blocks).
    var concreteHosts: [SSHConfigEntry] {
        entries.filter { entry in
            !entry.isMatchBlock
            && !entry.isGlobalDefaults
            && entry.patterns.allSatisfy { !$0.contains("*") && !$0.contains("?") }
        }
    }
}

struct SSHConfigWarning: Sendable {
    let lineNumber: Int
    let line: String
    let reason: String
}

// MARK: - Parser

/// Parses `~/.ssh/config` format into structured `SSHConfigEntry` values.
///
/// Handles:
/// - Host blocks with single or multiple patterns
/// - Match blocks (captured but not expanded)
/// - Quoted arguments (`"my key file"`)
/// - Inline comments (`# ...`)
/// - Continuation of global scope before any Host/Match block
/// - Case-insensitive keyword matching (SSH config is case-insensitive for keywords)
///
/// Does NOT handle:
/// - `Include` directive expansion (returns a warning; caller should expand before parsing)
/// - Token expansion (`%h`, `%u`, `%p`, etc.) — done at mapping stage
/// - `Match` condition evaluation — blocks are captured verbatim
struct SSHConfigParser: Sendable {

    /// Parse the contents of an SSH config file.
    ///
    /// - Parameter contents: The full text of `~/.ssh/config`.
    /// - Returns: A `SSHConfigParseResult` with all parsed entries and any warnings.
    func parse(_ contents: String) -> SSHConfigParseResult {
        let lines = contents.components(separatedBy: .newlines)
        var entries: [SSHConfigEntry] = []
        var warnings: [SSHConfigWarning] = []

        // Directives before the first Host/Match line are implicitly `Host *`.
        var currentPatterns: [String] = ["*"]
        var currentIsMatch = false
        var currentStartLine = 1
        var currentDirectives: [SSHConfigDirective] = []
        var hasExplicitBlock = false

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = stripComment(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blank lines.
            if trimmed.isEmpty { continue }

            // Split into keyword + arguments.
            guard let (keyword, arguments) = splitDirective(trimmed) else {
                warnings.append(SSHConfigWarning(
                    lineNumber: lineNumber,
                    line: rawLine,
                    reason: "Could not parse directive"
                ))
                continue
            }

            let keyLower = keyword.lowercased()

            // Handle block-starting keywords.
            if keyLower == "host" || keyLower == "match" {
                // Flush the previous block.
                if hasExplicitBlock || !currentDirectives.isEmpty {
                    entries.append(SSHConfigEntry(
                        patterns: currentPatterns,
                        isMatchBlock: currentIsMatch,
                        directives: currentDirectives,
                        startLine: currentStartLine
                    ))
                }

                currentPatterns = keyLower == "host"
                    ? splitHostPatterns(arguments)
                    : [arguments]  // Match keeps the full condition string
                currentIsMatch = (keyLower == "match")
                currentStartLine = lineNumber
                currentDirectives = []
                hasExplicitBlock = true

                if keyLower == "match" {
                    warnings.append(SSHConfigWarning(
                        lineNumber: lineNumber,
                        line: rawLine,
                        reason: "Match blocks are captured but conditions are not evaluated"
                    ))
                }
                continue
            }

            // Handle Include — warn but don't expand.
            if keyLower == "include" {
                warnings.append(SSHConfigWarning(
                    lineNumber: lineNumber,
                    line: rawLine,
                    reason: "Include directive not expanded; resolve includes before parsing"
                ))
                continue
            }

            // Regular directive — add to current block.
            currentDirectives.append(SSHConfigDirective(
                keyword: keyLower,
                originalKeyword: keyword,
                arguments: arguments,
                lineNumber: lineNumber
            ))
        }

        // Flush the last block.
        if hasExplicitBlock || !currentDirectives.isEmpty {
            entries.append(SSHConfigEntry(
                patterns: currentPatterns,
                isMatchBlock: currentIsMatch,
                directives: currentDirectives,
                startLine: currentStartLine
            ))
        }

        return SSHConfigParseResult(entries: entries, warnings: warnings)
    }

    // MARK: - Private Helpers

    /// Strip inline comments. Respects quoted strings — `#` inside quotes is literal.
    private func stripComment(_ line: String) -> String {
        var inQuote = false
        var result: [Character] = []

        for char in line {
            if char == "\"" { inQuote.toggle() }
            if char == "#" && !inQuote { break }
            result.append(char)
        }

        return String(result)
    }

    /// Split a trimmed line into (keyword, arguments).
    /// SSH config allows both `Keyword value` (space) and `Keyword=value` (equals).
    private func splitDirective(_ trimmed: String) -> (String, String)? {
        // Try equals-separated first: `Keyword=value`
        if let eqIndex = trimmed.firstIndex(of: "=") {
            let keyword = String(trimmed[trimmed.startIndex..<eqIndex])
                .trimmingCharacters(in: .whitespaces)
            let arguments = String(trimmed[trimmed.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)
            guard !keyword.isEmpty else { return nil }
            return (keyword, stripQuotes(arguments))
        }

        // Space-separated: `Keyword value`
        guard let spaceIndex = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            // Keyword with no arguments (e.g., bare `Host` — malformed but don't crash).
            return (trimmed, "")
        }

        let keyword = String(trimmed[trimmed.startIndex..<spaceIndex])
        let arguments = String(trimmed[trimmed.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespaces)
        return (keyword, stripQuotes(arguments))
    }

    /// Remove surrounding quotes from a value if present.
    private func stripQuotes(_ value: String) -> String {
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Split `Host` patterns — multiple patterns on one `Host` line are space-separated.
    /// Handles quoted patterns: `Host "my server" other-server`
    private func splitHostPatterns(_ arguments: String) -> [String] {
        var patterns: [String] = []
        var current = ""
        var inQuote = false

        for char in arguments {
            if char == "\"" {
                inQuote.toggle()
                continue
            }
            if char.isWhitespace && !inQuote {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { patterns.append(trimmed) }
                current = ""
                continue
            }
            current.append(char)
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { patterns.append(trimmed) }

        return patterns.isEmpty ? ["*"] : patterns
    }
}

// MARK: - Token Expansion

/// Expands SSH config tokens (`%h`, `%u`, `%p`, etc.) in directive values.
///
/// Supported tokens:
/// - `%h` — remote hostname
/// - `%u` — remote username
/// - `%p` — remote port
/// - `%r` — remote username (alias for `%u` in most contexts)
/// - `%n` — original hostname as given on the command line (same as `%h` for us)
/// - `%l` — local hostname (short form)
/// - `%L` — local hostname (full FQDN)
/// - `%d` — local user's home directory
/// - `%%` — literal `%`
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

// MARK: - Exporter: Host → SSH Config Format

/// Exports ProSSHMac `Host` models back to `~/.ssh/config` format.
///
/// Generates clean, readable SSH config blocks with comments noting
/// which fields are ProSSHMac-specific (and thus informational only).
struct SSHConfigExporter: Sendable {

    struct ExportOptions: Sendable {
        /// Include a header comment with export metadata.
        var includeHeader: Bool = true

        /// Include ProSSHMac-specific fields as comments.
        var includeProSSHNotes: Bool = true

        /// Resolve jump host UUIDs back to labels.
        var allHosts: [Host] = []

        /// Resolve key UUIDs back to file paths.
        var allKeys: [StoredSSHKey] = []
    }

    func export(_ hosts: [Host], options: ExportOptions = ExportOptions()) -> String {
        var lines: [String] = []

        if options.includeHeader {
            lines.append("# SSH config exported from ProSSHMac")
            lines.append("# Generated: \(ISO8601DateFormatter().string(from: .now))")
            lines.append("# Hosts: \(hosts.count)")
            lines.append("")
        }

        for (index, host) in hosts.enumerated() {
            lines.append(contentsOf: exportHost(host, options: options))
            if index < hosts.count - 1 {
                lines.append("")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func exportHost(_ host: Host, options: ExportOptions) -> [String] {
        var lines: [String] = []

        // --- Host line ---
        lines.append("Host \(host.label)")

        // --- Core ---
        lines.append("    HostName \(host.hostname)")
        if !host.username.isEmpty {
            lines.append("    User \(host.username)")
        }
        if host.port != 22 {
            lines.append("    Port \(host.port)")
        }

        // --- Auth ---
        if let keyID = host.keyReference,
           let key = options.allKeys.first(where: { $0.metadata.id == keyID }) {
            let path = key.metadata.importedFrom ?? "~/.ssh/\(key.metadata.label)"
            lines.append("    IdentityFile \(path)")
        }

        if host.authMethod == .password {
            lines.append("    PreferredAuthentications password")
        } else if host.authMethod == .keyboardInteractive {
            lines.append("    PreferredAuthentications keyboard-interactive")
        }

        // --- Agent forwarding ---
        if host.agentForwardingEnabled {
            lines.append("    ForwardAgent yes")
        }

        // --- Jump host ---
        if let jumpID = host.jumpHost,
           let jumpHost = options.allHosts.first(where: { $0.id == jumpID }) {
            lines.append("    ProxyJump \(jumpHost.label)")
        }

        // --- Port forwarding ---
        for rule in host.portForwardingRules {
            lines.append("    LocalForward \(rule.localPort) \(rule.remoteHost):\(rule.remotePort)")
        }

        // --- Algorithm preferences ---
        if let algPrefs = host.algorithmPreferences {
            if !algPrefs.keyExchange.isEmpty {
                lines.append("    KexAlgorithms \(algPrefs.keyExchange.joined(separator: ","))")
            }
            if !algPrefs.ciphers.isEmpty {
                lines.append("    Ciphers \(algPrefs.ciphers.joined(separator: ","))")
            }
            if !algPrefs.macs.isEmpty {
                lines.append("    MACs \(algPrefs.macs.joined(separator: ","))")
            }
        }

        if !host.pinnedHostKeyAlgorithms.isEmpty {
            lines.append("    HostKeyAlgorithms \(host.pinnedHostKeyAlgorithms.joined(separator: ","))")
        }

        // --- ProSSHMac-specific notes (as comments) ---
        if options.includeProSSHNotes {
            if let folder = host.folder {
                lines.append("    # ProSSHMac folder: \(folder)")
            }
            if !host.tags.isEmpty {
                lines.append("    # ProSSHMac tags: \(host.tags.joined(separator: ", "))")
            }
            if host.legacyModeEnabled {
                lines.append("    # ProSSHMac legacy mode: enabled")
            }
            if host.shellIntegration.type != .none {
                lines.append("    # ProSSHMac shell integration: \(host.shellIntegration.type.rawValue)")
            }
            if let notes = host.notes, !notes.isEmpty {
                for noteLine in notes.components(separatedBy: .newlines) {
                    lines.append("    # Note: \(noteLine)")
                }
            }
        }

        return lines
    }
}

// MARK: - Import Service (Orchestrator)

/// High-level service that orchestrates the full SSH config import pipeline.
///
/// Usage:
/// ```swift
/// let service = SSHConfigImportService()
/// let preview = try service.preview(configText: contents, existingHosts: hosts, existingKeys: keys)
/// // User reviews preview...
/// let importedHosts = preview.results.map(\.host)
/// ```
struct SSHConfigImportService: Sendable {

    struct ImportPreview: Sendable {
        /// Parsed entries mapped to hosts, with per-host notes.
        let results: [SSHConfigMapper.MappingResult]

        /// Parser-level warnings (malformed lines, unsupported features).
        let parserWarnings: [SSHConfigWarning]

        /// Number of entries skipped (wildcards, Match blocks).
        let skippedEntries: Int

        /// Summary string for display.
        var summary: String {
            let imported = results.count
            let withNotes = results.filter { !$0.notes.isEmpty }.count
            var parts = ["\(imported) host\(imported == 1 ? "" : "s") ready to import"]
            if withNotes > 0 {
                parts.append("\(withNotes) with notes")
            }
            if skippedEntries > 0 {
                parts.append("\(skippedEntries) skipped (wildcards/match blocks)")
            }
            if !parserWarnings.isEmpty {
                parts.append("\(parserWarnings.count) parser warning\(parserWarnings.count == 1 ? "" : "s")")
            }
            return parts.joined(separator: ", ")
        }
    }

    private let parser = SSHConfigParser()
    private let mapper = SSHConfigMapper()

    /// Parse an SSH config string and produce an import preview.
    ///
    /// The preview contains mapped hosts ready for user review before committing the import.
    func preview(
        configText: String,
        existingHosts: [Host] = [],
        existingKeys: [StoredSSHKey] = []
    ) -> ImportPreview {
        let parseResult = parser.parse(configText)

        let totalEntries = parseResult.entries.count
        let concreteCount = parseResult.concreteHosts.count
        let skipped = totalEntries - concreteCount

        let results = mapper.importAll(
            from: parseResult,
            existingHosts: existingHosts,
            existingKeys: existingKeys
        )

        return ImportPreview(
            results: results,
            parserWarnings: parseResult.warnings,
            skippedEntries: skipped
        )
    }

    /// Read the default SSH config file from disk.
    ///
    /// - Returns: The file contents, or `nil` if the file doesn't exist.
    func readDefaultConfig() -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Read an SSH config file from an arbitrary path.
    func readConfig(at path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }
}

// MARK: - Duplicate Detection

extension SSHConfigImportService {

    /// Check for duplicates between import candidates and existing hosts.
    ///
    /// Returns pairs of (imported host, existing host) that match on hostname+username+port.
    func findDuplicates(
        imported: [Host],
        existing: [Host]
    ) -> [(imported: Host, existing: Host)] {
        imported.compactMap { candidate in
            let match = existing.first { existing in
                existing.hostname.lowercased() == candidate.hostname.lowercased()
                && existing.username.lowercased() == candidate.username.lowercased()
                && existing.port == candidate.port
            }
            return match.map { (imported: candidate, existing: $0) }
        }
    }
}
