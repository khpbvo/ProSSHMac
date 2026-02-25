// Extracted from SSHConfigParser.swift
import Foundation

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
