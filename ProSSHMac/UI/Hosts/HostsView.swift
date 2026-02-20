import SwiftUI

struct HostsView: View {
    @EnvironmentObject private var hostListViewModel: HostListViewModel
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var keyForgeViewModel: KeyForgeViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var showForm = false
    @State private var draft = HostDraft()
    @State private var editingHostID: UUID?
    @State private var operationMessage: String?
    @State private var passwordPromptHost: Host?
    @State private var passwordPromptValue = ""
    @State private var passphrasePromptHost: Host?
    @State private var passphrasePromptValue = ""

    private enum PresentedAlert: Identifiable {
        case hostVerification(PendingHostVerification)
        case legacyAdvisory(PendingLegacyAdvisory)
        case operationMessage(String)
        case issueMessage(String)

        var id: String {
            switch self {
            case let .hostVerification(pending):
                return "host-verification-\(pending.id)"
            case let .legacyAdvisory(pending):
                return "legacy-advisory-\(pending.id.uuidString)"
            case let .operationMessage(message):
                return "operation-\(message)"
            case let .issueMessage(message):
                return "issue-\(message)"
            }
        }
    }

    var body: some View {
        List {
            if hostListViewModel.isLoading {
                ProgressView("Loading hosts...")
            }

            ForEach(groupedHosts, id: \.folder) { group in
                Section(group.folder) {
                    ForEach(group.hosts) { host in
                        hostRow(host)
                    }
                    .onDelete { offsets in
                        Task {
                            await hostListViewModel.deleteHosts(with: offsets, in: group.hosts)
                        }
                    }
                }
            }
        }
        .navigationTitle("Hosts")
        .task {
            await hostListViewModel.loadHostsIfNeeded()
            await keyForgeViewModel.loadKeysIfNeeded()
        }
        .toolbar {
            ToolbarItem(placement: importExportToolbarPlacement) {
                Menu {
                    Button("Copy SSH Config Export", systemImage: "doc.on.doc") {
                        PlatformClipboard.writeString(hostListViewModel.exportSSHConfig())
                        operationMessage = "SSH config copied to clipboard."
                    }

                    Button("Import SSH Config From Clipboard", systemImage: "square.and.arrow.down") {
                        Task {
                            let clipboard = PlatformClipboard.readString() ?? ""
                            let importedCount = await hostListViewModel.importSSHConfig(clipboard)
                            operationMessage = importedCount == 0
                                ? "No valid SSH host entries found in clipboard."
                                : "Imported \(importedCount) host(s) from SSH config."
                        }
                    }
                } label: {
                    Label("Import / Export", systemImage: "arrow.up.arrow.down.circle")
                }
            }

            ToolbarItem(placement: addHostToolbarPlacement) {
                Button {
                    editingHostID = nil
                    draft = HostDraft()
                    showForm = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showForm) {
            HostFormView(
                title: editingHostID == nil ? "Add Host" : "Edit Host",
                draft: $draft,
                availableJumpHosts: hostListViewModel.hosts,
                availableKeys: keyForgeViewModel.keys,
                editingHostID: editingHostID
            ) { savedDraft in
                Task {
                    if let editingHostID {
                        await hostListViewModel.updateHost(id: editingHostID, with: savedDraft)
                    } else {
                        await hostListViewModel.addHost(savedDraft)
                    }
                    showForm = false
                }
            }
        }
        .sheet(item: $passwordPromptHost) { host in
            NavigationStack {
                Form {
                    Section("Password Required") {
                        Text("\(host.username)@\(host.hostname):\(host.port)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        SecureField("Password", text: $passwordPromptValue)
                    }
                }
                .navigationTitle("Connect \(host.label)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            passwordPromptHost = nil
                            passwordPromptValue = ""
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Connect") {
                            let password = passwordPromptValue
                            passwordPromptHost = nil
                            passwordPromptValue = ""
                            Task {
                                await hostListViewModel.connect(to: host, passwordOverride: password)
                            }
                        }
                        .disabled(passwordPromptValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(item: $passphrasePromptHost) { host in
            NavigationStack {
                Form {
                    Section("Key Passphrase Required") {
                        Text("\(host.username)@\(host.hostname):\(host.port)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let keyRef = host.keyReference,
                           let key = keyForgeViewModel.keys.first(where: { $0.id == keyRef }) {
                            Text("Key: \(key.metadata.label)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        SecureField("Passphrase", text: $passphrasePromptValue)
                    }
                }
                .navigationTitle("Connect \(host.label)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            passphrasePromptHost = nil
                            passphrasePromptValue = ""
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Connect") {
                            let passphrase = passphrasePromptValue
                            passphrasePromptHost = nil
                            passphrasePromptValue = ""
                            Task {
                                await hostListViewModel.connect(to: host, keyPassphraseOverride: passphrase)
                            }
                        }
                        .disabled(passphrasePromptValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .alert(item: presentedAlertBinding) { alert in
            switch alert {
            case let .hostVerification(pending):
                return Alert(
                    title: Text(pending.title),
                    message: Text(pending.message),
                    primaryButton: .default(Text("Trust")) {
                        let captured = pending
                        Task {
                            await hostListViewModel.trustAndConnect(pending: captured)
                        }
                    },
                    secondaryButton: .cancel(Text("Cancel")) {
                        hostListViewModel.cancelPendingHostVerification()
                    }
                )
            case let .legacyAdvisory(pending):
                return Alert(
                    title: Text(pending.title),
                    message: Text(pending.message),
                    primaryButton: .default(Text("Enable Legacy + Connect")) {
                        Task {
                            await hostListViewModel.enableLegacyForPendingHostAndConnect()
                        }
                    },
                    secondaryButton: .cancel(Text("Cancel")) {
                        hostListViewModel.cancelPendingLegacyAdvisory()
                    }
                )
            case let .operationMessage(message):
                return Alert(
                    title: Text("Host Config"),
                    message: Text(message),
                    dismissButton: .default(Text("OK")) {
                        operationMessage = nil
                    }
                )
            case let .issueMessage(message):
                return Alert(
                    title: Text("Issue"),
                    message: Text(message),
                    dismissButton: .default(Text("OK")) {
                        hostListViewModel.clearError()
                    }
                )
            }
        }
        .confirmationDialog(
            "Save Password",
            isPresented: savePasswordDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Save with Face ID / Touch ID") {
                if let prompt = hostListViewModel.pendingSavePasswordPrompt {
                    Task {
                        await hostListViewModel.savePasswordForHost(
                            hostID: prompt.hostID,
                            password: prompt.password
                        )
                    }
                }
                hostListViewModel.pendingSavePasswordPrompt = nil
            }
            Button("Not Now", role: .cancel) {
                hostListViewModel.pendingSavePasswordPrompt = nil
            }
        } message: {
            if let prompt = hostListViewModel.pendingSavePasswordPrompt {
                Text("Save the password for \(prompt.hostLabel) so you can connect with biometrics next time?")
            }
        }
        .confirmationDialog(
            "Save Passphrase",
            isPresented: savePassphraseDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Save with Face ID / Touch ID") {
                if let prompt = hostListViewModel.pendingSavePassphrasePrompt {
                    Task {
                        await hostListViewModel.savePassphraseForHost(
                            hostID: prompt.hostID,
                            passphrase: prompt.passphrase
                        )
                    }
                }
                hostListViewModel.pendingSavePassphrasePrompt = nil
            }
            Button("Not Now", role: .cancel) {
                hostListViewModel.pendingSavePassphrasePrompt = nil
            }
        } message: {
            if let prompt = hostListViewModel.pendingSavePassphrasePrompt {
                Text("Save the passphrase for \(prompt.hostLabel) so you can connect with biometrics next time?")
            }
        }
    }

    @ViewBuilder
    private func hostRow(_ host: Host) -> some View {
        let relevantSession = sessionManager.mostRelevantSession(for: host.id)
        let sessionState = relevantSession?.state

        HStack(spacing: 0) {
            // Left accent bar — colored by connection state
            RoundedRectangle(cornerRadius: 2)
                .fill(hostStateColor(sessionState))
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(host.label)
                        .font(.headline)

                    Spacer()

                    if host.legacyModeEnabled {
                        Label("Legacy", systemImage: "shield.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }

                    if let relevantSession, relevantSession.usesLegacyCrypto {
                        Label("Legacy Session", systemImage: "exclamationmark.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }

                    // Status indicator
                    if let state = sessionState {
                        hostStatusBadge(state: state, session: relevantSession)
                    }
                }

                HStack {
                    Text("\(host.username)@\(host.hostname):\(host.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Traffic counters for connected sessions
                    if let session = relevantSession, session.state == .connected {
                        let traffic = sessionManager.totalTraffic(for: session.id)
                        if traffic.received > 0 || traffic.sent > 0 {
                            Text("↓ \(formatBytes(traffic.received))  ↑ \(formatBytes(traffic.sent))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                HStack {
                    if let folder = host.folder, !folder.isEmpty {
                        Text(folder)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(chipBackground(.blue), in: Capsule())
                    }

                    if !host.pinnedHostKeyAlgorithms.isEmpty {
                        Text("Pinned HostKey")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(chipBackground(.orange), in: Capsule())
                    }

                    if host.agentForwardingEnabled {
                        Label("Agent Fwd", systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(chipBackground(.teal), in: Capsule())
                    }

                    if !host.portForwardingRules.isEmpty {
                        let enabledCount = host.portForwardingRules.filter(\.isEnabled).count
                        Label("\(enabledCount) forward\(enabledCount == 1 ? "" : "s")", systemImage: "arrow.right.arrow.left")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(chipBackground(.green), in: Capsule())
                    }

                    if let jumpHostID = host.jumpHost {
                        if let jumpHost = hostListViewModel.hosts.first(where: { $0.id == jumpHostID }) {
                            Label("via \(jumpHost.label)", systemImage: "arrow.triangle.branch")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(chipBackground(.purple), in: Capsule())
                        } else {
                            Label("Jump host missing", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(chipBackground(.red, elevated: false), in: Capsule())
                        }
                    }

                    Text(host.authMethod.title)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())

                    if host.hasSavedPassword {
                        Label("Saved Password", systemImage: "faceid")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(chipBackground(.indigo), in: Capsule())
                    }

                    if host.hasSavedPassphrase {
                        Label("Saved Passphrase", systemImage: "faceid")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(chipBackground(.indigo), in: Capsule())
                    }

                    if let lastConnected = host.lastConnected {
                        Text("Last: \(lastConnected, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if host.legacyModeEnabled {
                    Text("Legacy algorithms are enabled for this host.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.leading, 10)
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(hostStateBackgroundColor(sessionState))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        )
        .swipeActions(edge: .trailing) {
            Button {
                connectHost(host)
            } label: {
                Label("Connect", systemImage: "terminal")
            }
            .tint(.green)

            Button {
                editingHostID = host.id
                draft = HostDraft(from: host)
                showForm = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                connectHost(host)
            } label: {
                Label("Connect", systemImage: "terminal")
            }

            Button {
                editingHostID = host.id
                draft = HostDraft(from: host)
                showForm = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            if host.hasSavedPassword {
                Button(role: .destructive) {
                    Task {
                        await hostListViewModel.deletePasswordForHost(hostID: host.id)
                    }
                } label: {
                    Label("Remove Saved Password", systemImage: "key.slash")
                }
            }

            if host.hasSavedPassphrase {
                Button(role: .destructive) {
                    Task {
                        await hostListViewModel.deletePassphraseForHost(hostID: host.id)
                    }
                } label: {
                    Label("Remove Saved Passphrase", systemImage: "key.slash")
                }
            }

            Button(role: .destructive) {
                Task {
                    await hostListViewModel.deleteHost(id: host.id)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var groupedHosts: [(folder: String, hosts: [Host])] {
        let groups = Dictionary(grouping: hostListViewModel.hosts) { host in
            let trimmed = host.folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "Ungrouped" : trimmed
        }

        return groups
            .map { (folder: $0.key, hosts: $0.value.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }) }
            .sorted { lhs, rhs in
                lhs.folder.localizedCaseInsensitiveCompare(rhs.folder) == .orderedAscending
            }
    }

    private var importExportToolbarPlacement: ToolbarItemPlacement {
        return .automatic
    }

    private var addHostToolbarPlacement: ToolbarItemPlacement {
        return .primaryAction
    }

    private var presentedAlertBinding: Binding<PresentedAlert?> {
        Binding(
            get: {
                if let pending = hostListViewModel.pendingHostVerification {
                    return .hostVerification(pending)
                }
                if let pending = hostListViewModel.pendingLegacyAdvisory {
                    return .legacyAdvisory(pending)
                }
                if let message = operationMessage {
                    return .operationMessage(message)
                }
                if let message = hostListViewModel.errorMessage {
                    return .issueMessage(message)
                }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if hostListViewModel.pendingHostVerification != nil {
                    hostListViewModel.cancelPendingHostVerification()
                    return
                }
                if hostListViewModel.pendingLegacyAdvisory != nil {
                    hostListViewModel.cancelPendingLegacyAdvisory()
                    return
                }
                if operationMessage != nil {
                    operationMessage = nil
                    return
                }
                if hostListViewModel.errorMessage != nil {
                    hostListViewModel.clearError()
                }
            }
        )
    }

    private var savePasswordDialogBinding: Binding<Bool> {
        Binding(
            get: { hostListViewModel.pendingSavePasswordPrompt != nil },
            set: { newValue in
                if !newValue {
                    hostListViewModel.pendingSavePasswordPrompt = nil
                }
            }
        )
    }

    private var savePassphraseDialogBinding: Binding<Bool> {
        Binding(
            get: { hostListViewModel.pendingSavePassphrasePrompt != nil },
            set: { newValue in
                if !newValue {
                    hostListViewModel.pendingSavePassphrasePrompt = nil
                }
            }
        )
    }

    private func hostNeedsPassphrase(_ host: Host) -> Bool {
        guard host.authMethod == .publicKey,
              let keyRef = host.keyReference,
              let key = keyForgeViewModel.keys.first(where: { $0.id == keyRef }) else {
            return false
        }
        return key.metadata.isPassphraseProtected
    }

    private func connectHost(_ host: Host) {
        if host.authMethod == .password {
            if host.hasSavedPassword {
                Task {
                    let success = await hostListViewModel.connectWithCachedPassword(to: host)
                    if !success {
                        passwordPromptValue = ""
                        passwordPromptHost = host
                    }
                }
            } else {
                passwordPromptValue = ""
                passwordPromptHost = host
            }
        } else if hostNeedsPassphrase(host) {
            if host.hasSavedPassphrase {
                Task {
                    let success = await hostListViewModel.connectWithCachedPassphrase(to: host)
                    if !success {
                        passphrasePromptValue = ""
                        passphrasePromptHost = host
                    }
                }
            } else {
                passphrasePromptValue = ""
                passphrasePromptHost = host
            }
        } else {
            Task {
                await hostListViewModel.connect(to: host)
            }
        }
    }

    private func chipBackground(_ color: Color, elevated: Bool = true) -> Color {
        let baseOpacity = colorScheme == .dark ? (elevated ? 0.26 : 0.2) : (elevated ? 0.14 : 0.1)
        return color.opacity(baseOpacity)
    }

    // MARK: - Connection State Colors

    private func hostStateColor(_ state: SessionState?) -> Color {
        guard let state else { return .clear }
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private func hostStateBackgroundColor(_ state: SessionState?) -> Color {
        guard let state else { return .clear }
        let darkOpacity: Double
        let lightOpacity: Double
        switch state {
        case .connected:
            darkOpacity = 0.12
            lightOpacity = 0.06
        case .connecting:
            darkOpacity = 0.10
            lightOpacity = 0.06
        case .failed:
            darkOpacity = 0.10
            lightOpacity = 0.05
        case .disconnected:
            darkOpacity = 0.06
            lightOpacity = 0.03
        }
        let opacity = colorScheme == .dark ? darkOpacity : lightOpacity
        return hostStateColor(state).opacity(opacity)
    }

    // MARK: - Status Badge

    @ViewBuilder
    private func hostStatusBadge(state: SessionState, session: Session?) -> some View {
        let color = hostStateColor(state)
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .fill(color.opacity(0.4))
                        .frame(width: 14, height: 14)
                        .opacity(state == .connecting ? 1 : 0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: state == .connecting)
                )

            switch state {
            case .connected:
                if let session {
                    Text("Connected \(session.startedAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(color)
                } else {
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(color)
                }
            case .connecting:
                Text("Connecting...")
                    .font(.caption)
                    .foregroundStyle(color)
            case .failed:
                Text("Failed")
                    .font(.caption)
                    .foregroundStyle(color)
            case .disconnected:
                Text("Disconnected")
                    .font(.caption)
                    .foregroundStyle(color)
            }
        }
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Byte Formatting

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        } else {
            return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
        }
    }
}
