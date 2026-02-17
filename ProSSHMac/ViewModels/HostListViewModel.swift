import Foundation
import Combine

struct PendingHostVerification: Identifiable, Equatable {
    var host: Host
    var challenge: KnownHostVerificationChallenge
    var passwordOverride: String?

    var id: String {
        "\(host.id.uuidString)-\(challenge.id)"
    }

    var title: String {
        challenge.isMismatch ? "Host Key Changed" : "Verify Host Key"
    }

    var message: String {
        var lines: [String] = [
            "\(host.hostname):\(host.port)",
            "Type: \(challenge.hostKeyType)",
            "Presented: \(challenge.presentedFingerprint)"
        ]

        if let expected = challenge.expectedFingerprint {
            lines.append("Expected: \(expected)")
            lines.append("The host key has changed. Trust only if you verified this out-of-band.")
        } else {
            lines.append("First time connecting to this host. Verify fingerprint before trusting.")
        }

        return lines.joined(separator: "\n")
    }
}

struct PendingLegacyAdvisory: Identifiable, Equatable {
    var host: Host
    var requiredClasses: [SSHAlgorithmClass]
    var passwordOverride: String?

    var id: UUID {
        host.id
    }

    var title: String {
        "Legacy Algorithms Required"
    }

    var message: String {
        let classes = requiredClasses.map(\.displayTitle).joined(separator: ", ")
        let lines: [String] = [
            "\(host.hostname):\(host.port)",
            "This server only supports deprecated SSH algorithms.",
            "Required algorithm classes: \(classes).",
            "Enable legacy mode only for trusted infrastructure after verifying host identity."
        ]
        return lines.joined(separator: "\n")
    }
}

struct PendingSavePasswordPrompt: Identifiable, Equatable {
    let hostID: UUID
    let hostLabel: String
    let password: String

    var id: UUID { hostID }
}

struct PendingSavePassphrasePrompt: Identifiable, Equatable {
    let hostID: UUID
    let hostLabel: String
    let passphrase: String

    var id: UUID { hostID }
}

@MainActor
final class HostListViewModel: ObservableObject {
    @Published private(set) var hosts: [Host] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var pendingHostVerification: PendingHostVerification?
    @Published var pendingLegacyAdvisory: PendingLegacyAdvisory?
    @Published var pendingSavePasswordPrompt: PendingSavePasswordPrompt?
    @Published var pendingSavePassphrasePrompt: PendingSavePassphrasePrompt?

    private let hostStore: any HostStoreProtocol
    private let sessionManager: SessionManager
    private let auditLogManager: AuditLogManager?
    private let searchIndexer: (any HostSearchIndexing)?
    private let biometricPasswordStore: (any BiometricPasswordStoring)?
    private let biometricPassphraseStore: (any BiometricPasswordStoring)?
    private var hasLoaded = false

    init(
        hostStore: any HostStoreProtocol,
        sessionManager: SessionManager,
        auditLogManager: AuditLogManager? = nil,
        searchIndexer: (any HostSearchIndexing)? = nil,
        biometricPasswordStore: (any BiometricPasswordStoring)? = nil,
        biometricPassphraseStore: (any BiometricPasswordStoring)? = nil
    ) {
        self.hostStore = hostStore
        self.sessionManager = sessionManager
        self.auditLogManager = auditLogManager
        self.searchIndexer = searchIndexer
        self.biometricPasswordStore = biometricPasswordStore
        self.biometricPassphraseStore = biometricPassphraseStore
    }

    func loadHostsIfNeeded() async {
        guard !hasLoaded else { return }
        await loadHosts()
    }

    func loadHosts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            hosts = try await hostStore.loadHosts().sorted(by: Self.sortHosts)
            hasLoaded = true
            await reindexHostsForSearch()
        } catch {
            errorMessage = "Failed to load hosts: \(error.localizedDescription)"
        }
    }

    func addHost(_ draft: HostDraft) async {
        guard draft.validationError == nil else {
            errorMessage = draft.validationError
            return
        }

        hosts.append(draft.toHost())
        hosts.sort(by: Self.sortHosts)
        await persist()
    }

    func updateHost(id: UUID, with draft: HostDraft) async {
        guard draft.validationError == nil else {
            errorMessage = draft.validationError
            return
        }
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }

        let existing = hosts[index]
        hosts[index] = draft.toHost(id: existing.id, createdAt: existing.createdAt, lastConnected: existing.lastConnected)
        hosts.sort(by: Self.sortHosts)
        await persist()
    }

    func deleteHosts(at offsets: IndexSet) async {
        for index in offsets.sorted(by: >) {
            cleanupKeychainForHost(hosts[index])
            hosts.remove(at: index)
        }
        await persist()
    }

    func deleteHosts(with offsets: IndexSet, in visibleHosts: [Host]) async {
        let idsToDelete = offsets.map { visibleHosts[$0].id }
        for id in idsToDelete {
            if let host = hosts.first(where: { $0.id == id }) {
                cleanupKeychainForHost(host)
            }
        }
        hosts.removeAll { idsToDelete.contains($0.id) }
        await persist()
    }

    func deleteHost(id: UUID) async {
        if let host = hosts.first(where: { $0.id == id }) {
            cleanupKeychainForHost(host)
        }
        hosts.removeAll { $0.id == id }
        await persist()
    }

    /// Attempts to connect using a biometrically cached password.
    /// Returns `true` if the connection was initiated, `false` if no cached password or biometric failed.
    func connectWithCachedPassword(to host: Host) async -> Bool {
        guard let store = biometricPasswordStore,
              host.hasSavedPassword else {
            return false
        }

        do {
            let password = try await store.retrieve(
                forHostID: host.id,
                reason: "Authenticate to connect to \(host.label)"
            )
            await connect(to: host, passwordOverride: password)
            return true
        } catch {
            return false
        }
    }

    func savePasswordForHost(hostID: UUID, password: String) async {
        guard let store = biometricPasswordStore else { return }

        do {
            try store.save(password: password, forHostID: hostID)
            if let index = hosts.firstIndex(where: { $0.id == hostID }) {
                hosts[index].passwordReference = hostID.uuidString
                await persist()
            }
        } catch {
            errorMessage = "Could not save password: \(error.localizedDescription)"
        }
    }

    func deletePasswordForHost(hostID: UUID) async {
        guard let store = biometricPasswordStore else { return }

        do {
            try store.delete(forHostID: hostID)
            if let index = hosts.firstIndex(where: { $0.id == hostID }) {
                hosts[index].passwordReference = nil
                await persist()
            }
        } catch {
            errorMessage = "Could not remove saved password: \(error.localizedDescription)"
        }
    }

    // MARK: - Biometric Key Passphrase

    /// Attempts to connect using a biometrically cached key passphrase.
    /// Returns `true` if the connection was initiated, `false` if no cached passphrase or biometric failed.
    func connectWithCachedPassphrase(to host: Host) async -> Bool {
        guard let store = biometricPassphraseStore,
              host.hasSavedPassphrase else {
            return false
        }

        do {
            let passphrase = try await store.retrieve(
                forHostID: host.id,
                reason: "Unlock key passphrase for \(host.label)"
            )
            await connect(to: host, keyPassphraseOverride: passphrase)
            return true
        } catch {
            return false
        }
    }

    func savePassphraseForHost(hostID: UUID, passphrase: String) async {
        guard let store = biometricPassphraseStore else { return }

        do {
            try store.save(password: passphrase, forHostID: hostID)
            if let index = hosts.firstIndex(where: { $0.id == hostID }) {
                hosts[index].passphraseReference = hostID.uuidString
                await persist()
            }
        } catch {
            errorMessage = "Could not save passphrase: \(error.localizedDescription)"
        }
    }

    func deletePassphraseForHost(hostID: UUID) async {
        guard let store = biometricPassphraseStore else { return }

        do {
            try store.delete(forHostID: hostID)
            if let index = hosts.firstIndex(where: { $0.id == hostID }) {
                hosts[index].passphraseReference = nil
                await persist()
            }
        } catch {
            errorMessage = "Could not remove saved passphrase: \(error.localizedDescription)"
        }
    }

    func connect(to host: Host, passwordOverride: String? = nil, keyPassphraseOverride: String? = nil) async {
        do {
            let resolvedJumpHost: Host? = host.jumpHost.flatMap { id in hosts.first { $0.id == id } }
            if host.jumpHost != nil && resolvedJumpHost == nil {
                errorMessage = "Jump host not found. It may have been deleted."
                return
            }
            _ = try await sessionManager.connect(to: host, jumpHost: resolvedJumpHost, passwordOverride: passwordOverride, keyPassphraseOverride: keyPassphraseOverride)
            markConnected(hostID: host.id)
            await persist()

            // After successful password-auth connect, offer to save password
            if host.authMethod == .password,
               let password = passwordOverride,
               !host.hasSavedPassword,
               let store = biometricPasswordStore,
               store.isBiometricsAvailable() {
                pendingSavePasswordPrompt = PendingSavePasswordPrompt(
                    hostID: host.id,
                    hostLabel: host.label,
                    password: password
                )
            }

            // After successful key-passphrase connect, offer to save passphrase
            if host.authMethod == .publicKey,
               let passphrase = keyPassphraseOverride,
               !passphrase.isEmpty,
               !host.hasSavedPassphrase,
               let store = biometricPassphraseStore,
               store.isBiometricsAvailable() {
                pendingSavePassphrasePrompt = PendingSavePassphrasePrompt(
                    hostID: host.id,
                    hostLabel: host.label,
                    passphrase: passphrase
                )
            }
        } catch let SessionConnectionError.hostVerificationRequired(challenge) {
            pendingHostVerification = PendingHostVerification(
                host: host,
                challenge: challenge,
                passwordOverride: passwordOverride
            )
            let expectation = challenge.expectedFingerprint ?? "none"
            await auditLogManager?.record(
                category: .hostVerification,
                action: "Host verification prompt displayed",
                outcome: .warning,
                host: host,
                details: "Presented=\(challenge.presentedFingerprint); expected=\(expectation)."
            )
        } catch let SSHTransportError.legacyAlgorithmsRequired(_, required) {
            pendingLegacyAdvisory = PendingLegacyAdvisory(
                host: host,
                requiredClasses: required,
                passwordOverride: passwordOverride
            )
            await auditLogManager?.record(
                category: .security,
                action: "Legacy mode required by remote host",
                outcome: .warning,
                host: host,
                details: "Required classes: \(required.map(\.displayTitle).joined(separator: ", "))."
            )
        } catch {
            errorMessage = "Connection failed for \(host.label): \(error.localizedDescription)"
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func host(withID id: UUID) -> Host? {
        hosts.first(where: { $0.id == id })
    }

    func host(matchingShortcutQuery query: String) -> Host? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if let exactLabel = hosts.first(where: { $0.label.lowercased() == normalized }) {
            return exactLabel
        }
        if let exactHost = hosts.first(where: { $0.hostname.lowercased() == normalized }) {
            return exactHost
        }
        if let containsLabel = hosts.first(where: { $0.label.lowercased().contains(normalized) }) {
            return containsLabel
        }
        return hosts.first(where: { $0.hostname.lowercased().contains(normalized) })
    }

    func confirmPendingHostVerification() async {
        guard let pending = pendingHostVerification else { return }
        pendingHostVerification = nil
        await trustAndConnect(pending: pending)
    }

    func trustAndConnect(pending: PendingHostVerification) async {
        do {
            await auditLogManager?.record(
                category: .hostVerification,
                action: "Host verification approved by user",
                outcome: .info,
                host: pending.host
            )
            try await sessionManager.trustKnownHost(challenge: pending.challenge)
            await connect(to: pending.host, passwordOverride: pending.passwordOverride)
        } catch {
            errorMessage = "Could not trust host key: \(error.localizedDescription)"
        }
    }

    func cancelPendingHostVerification() {
        if let pending = pendingHostVerification {
            let hostname = pending.host.hostname
            let port = pending.host.port
            Task { @MainActor [weak self] in
                await self?.auditLogManager?.record(
                    category: .hostVerification,
                    action: "Host verification declined by user",
                    outcome: .warning,
                    hostname: hostname,
                    port: port
                )
            }
        }
        pendingHostVerification = nil
    }

    func enableLegacyForPendingHostAndConnect() async {
        guard let pending = pendingLegacyAdvisory else { return }
        pendingLegacyAdvisory = nil

        guard let index = hosts.firstIndex(where: { $0.id == pending.host.id }) else {
            errorMessage = "Host could not be found to enable legacy mode."
            return
        }

        hosts[index].legacyModeEnabled = true
        await persist()

        await auditLogManager?.record(
            category: .security,
            action: "Legacy mode enabled by user",
            outcome: .warning,
            host: hosts[index],
            details: "Required classes: \(pending.requiredClasses.map(\.displayTitle).joined(separator: ", "))."
        )

        await connect(to: hosts[index], passwordOverride: pending.passwordOverride)
    }

    func cancelPendingLegacyAdvisory() {
        if let pending = pendingLegacyAdvisory {
            Task { @MainActor [weak self] in
                await self?.auditLogManager?.record(
                    category: .security,
                    action: "Legacy mode declined by user",
                    outcome: .info,
                    host: pending.host
                )
            }
        }
        pendingLegacyAdvisory = nil
    }

    func exportSSHConfig() -> String {
        var lines: [String] = [
            "# ProSSH v2 host export",
            "# Generated: \(ISO8601DateFormatter().string(from: .now))",
            ""
        ]

        for host in hosts.sorted(by: Self.sortHosts) {
            let alias = host.label.replacingOccurrences(of: " ", with: "_")
            lines.append("Host \(alias)")
            lines.append("    HostName \(host.hostname)")
            lines.append("    User \(host.username)")
            lines.append("    Port \(host.port)")
            if let folder = host.folder, !folder.isEmpty {
                lines.append("    # Folder: \(folder)")
            }
            if !host.tags.isEmpty {
                lines.append("    # Tags: \(host.tags.joined(separator: ", "))")
            }
            if host.legacyModeEnabled {
                lines.append("    # LegacyMode: true")
            }
            if !host.pinnedHostKeyAlgorithms.isEmpty {
                lines.append("    # PinnedHostKeyAlgorithms: \(host.pinnedHostKeyAlgorithms.joined(separator: ", "))")
            }
            if host.agentForwardingEnabled {
                lines.append("    ForwardAgent yes")
            }
            if let jumpHostID = host.jumpHost,
               let jumpHost = hosts.first(where: { $0.id == jumpHostID }) {
                lines.append("    ProxyJump \(jumpHost.username)@\(jumpHost.hostname):\(jumpHost.port)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    func importSSHConfig(_ configText: String) async -> Int {
        let imported = Self.parseSSHConfig(configText)
        guard !imported.isEmpty else {
            return 0
        }

        hosts.append(contentsOf: imported)
        hosts.sort(by: Self.sortHosts)
        await persist()
        return imported.count
    }

    private func cleanupKeychainForHost(_ host: Host) {
        if host.hasSavedPassword {
            try? biometricPasswordStore?.delete(forHostID: host.id)
        }
        if host.hasSavedPassphrase {
            try? biometricPassphraseStore?.delete(forHostID: host.id)
        }
    }

    private func markConnected(hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[index].lastConnected = .now
    }

    private func persist() async {
        do {
            try await hostStore.saveHosts(hosts)
            await reindexHostsForSearch()
        } catch {
            errorMessage = "Failed to save hosts: \(error.localizedDescription)"
        }
    }

    private func reindexHostsForSearch() async {
        await searchIndexer?.reindex(hosts: hosts)
    }

    private static func sortHosts(lhs: Host, rhs: Host) -> Bool {
        let leftFolder = lhs.folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rightFolder = rhs.folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let folderCompare = leftFolder.localizedCaseInsensitiveCompare(rightFolder)
        if folderCompare != .orderedSame {
            return folderCompare == .orderedAscending
        }

        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }

    private static func parseSSHConfig(_ configText: String) -> [Host] {
        struct PartialHost {
            var label = ""
            var folder: String?
            var hostname = ""
            var username = ""
            var port: UInt16 = 22
            var tags: [String] = []
            var legacyModeEnabled = false
            var pinnedHostKeyAlgorithms: [String] = []
            var agentForwardingEnabled = false
            var proxyJump: String?
        }

        var parsedHosts: [Host] = []
        var current: PartialHost?

        func finalizeCurrent() {
            guard let candidate = current else { return }
            guard !candidate.label.isEmpty, !candidate.hostname.isEmpty, !candidate.username.isEmpty else { return }

            var importNotes = "Imported from SSH config"
            if let proxyJump = candidate.proxyJump, !proxyJump.isEmpty {
                importNotes += "\nProxyJump: \(proxyJump)"
            }

            parsedHosts.append(
                Host(
                    id: UUID(),
                    label: candidate.label.replacingOccurrences(of: "_", with: " "),
                    folder: candidate.folder,
                    hostname: candidate.hostname,
                    port: candidate.port,
                    username: candidate.username,
                    authMethod: .publicKey,
                    keyReference: nil,
                    certificateReference: nil,
                    passwordReference: nil,
                    jumpHost: nil,
                    algorithmPreferences: nil,
                    pinnedHostKeyAlgorithms: candidate.pinnedHostKeyAlgorithms,
                    agentForwardingEnabled: candidate.agentForwardingEnabled,
                    legacyModeEnabled: candidate.legacyModeEnabled,
                    tags: candidate.tags,
                    notes: importNotes,
                    lastConnected: nil,
                    createdAt: .now
                )
            )
        }

        for rawLine in configText.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }

            if trimmed.hasPrefix("#") {
                guard var candidate = current else { continue }

                let comment = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                if comment.lowercased().hasPrefix("folder:") {
                    candidate.folder = comment.dropFirst("folder:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if comment.lowercased().hasPrefix("tags:") {
                    candidate.tags = comment.dropFirst("tags:".count)
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                } else if comment.lowercased().hasPrefix("legacymode:") {
                    let value = comment.dropFirst("legacymode:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    candidate.legacyModeEnabled = (value as NSString).boolValue
                } else if comment.lowercased().hasPrefix("pinnedhostkeyalgorithms:") {
                    candidate.pinnedHostKeyAlgorithms = comment.dropFirst("pinnedhostkeyalgorithms:".count)
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                current = candidate
                continue
            }

            if trimmed.lowercased().hasPrefix("host ") {
                finalizeCurrent()

                let alias = trimmed.dropFirst("host ".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if alias.contains("*") || alias.contains("?") {
                    current = nil
                    continue
                }

                current = PartialHost(label: alias)
                continue
            }

            guard var candidate = current else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "hostname":
                candidate.hostname = value
            case "user":
                candidate.username = value
            case "port":
                candidate.port = UInt16(value) ?? 22
            case "proxyjump":
                candidate.proxyJump = value
            case "forwardagent":
                let lowered = value.lowercased()
                candidate.agentForwardingEnabled = lowered == "yes" || lowered == "true" || lowered == "on" || lowered == "1"
            default:
                break
            }

            current = candidate
        }

        finalizeCurrent()
        return parsedHosts
    }
}

private extension SSHAlgorithmClass {
    var displayTitle: String {
        switch self {
        case .keyExchange:
            return "Key Exchange"
        case .cipher:
            return "Cipher"
        case .hostKey:
            return "Host Key"
        case .mac:
            return "MAC"
        }
    }
}
