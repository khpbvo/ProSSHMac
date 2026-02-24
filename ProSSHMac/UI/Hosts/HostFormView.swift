import SwiftUI
import Combine

struct HostFormView: View {
    let title: String
    @Binding var draft: HostDraft
    let availableJumpHosts: [Host]
    let availableKeys: [StoredSSHKey]
    let editingHostID: UUID?
    let totpStore: TOTPStore?
    let onSave: (HostDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showPortForwardingEditor = false
    @State private var showTOTPProvisioningSheet = false
    @State private var totpSecret: Data? = nil

    init(
        title: String,
        draft: Binding<HostDraft>,
        availableJumpHosts: [Host] = [],
        availableKeys: [StoredSSHKey] = [],
        editingHostID: UUID? = nil,
        totpStore: TOTPStore? = nil,
        onSave: @escaping (HostDraft) -> Void
    ) {
        self.title = title
        self._draft = draft
        self.availableJumpHosts = availableJumpHosts
        self.availableKeys = availableKeys
        self.editingHostID = editingHostID
        self.totpStore = totpStore
        self.onSave = onSave
    }

    private var eligibleJumpHosts: [Host] {
        availableJumpHosts.filter { host in
            if let editingHostID, host.id == editingHostID { return false }
            if host.jumpHost != nil { return false }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    TextField("Label", text: $draft.label)
                    TextField("Folder (optional)", text: $draft.folder)
                    TextField("Hostname or IP", text: $draft.hostname)
                        .iosAutocapitalizationNever()
                        .autocorrectionDisabled()
                    TextField("Username", text: $draft.username)
                        .iosAutocapitalizationNever()
                        .autocorrectionDisabled()
                }

                Section("Connection") {
                    TextField("Port", text: $draft.port)
                        .iosKeyboardNumberPad()
                    Picker("Auth Method", selection: $draft.authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }

                    if draft.authMethod == .publicKey {
                        Picker("SSH Key", selection: $draft.keyReference) {
                            Text("None").tag(nil as UUID?)
                            ForEach(availableKeys) { key in
                                Text(key.metadata.label).tag(key.id as UUID?)
                            }
                        }
                    }

                    Toggle("Forward SSH Agent", isOn: $draft.agentForwardingEnabled)
                    Text("Only enable for trusted hosts. Remote systems may request signatures from your local agent while connected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Enable Legacy Algorithms", isOn: $draft.legacyModeEnabled)
                    Text("Enable only for trusted legacy equipment. Modern algorithms remain preferred by default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Jump Host") {
                    Picker("Jump Host", selection: $draft.jumpHost) {
                        Text("None (Direct)").tag(nil as UUID?)
                        ForEach(eligibleJumpHosts) { host in
                            Text(host.label).tag(host.id as UUID?)
                        }
                    }

                    if let selectedID = draft.jumpHost,
                       let selectedHost = availableJumpHosts.first(where: { $0.id == selectedID }) {
                        Text("\(selectedHost.username)@\(selectedHost.hostname):\(selectedHost.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Route this connection through another saved host.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Port Forwarding") {
                    ForEach($draft.portForwardingRules) { $rule in
                        HStack {
                            Toggle("", isOn: $rule.isEnabled)
                                .labelsHidden()
                                .frame(width: 40)
                            VStack(alignment: .leading) {
                                Text(rule.label)
                                    .font(.subheadline)
                                Text("localhost:\(rule.localPort) \u{2192} \(rule.remoteHost):\(rule.remotePort)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        draft.portForwardingRules.remove(atOffsets: offsets)
                    }

                    Button("Add Forwarding Rule") {
                        showPortForwardingEditor = true
                    }

                    Text("Forward local ports through this SSH connection. Rules activate automatically on connect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Security") {
                    TextField("Pinned Host Key Algos (comma-separated)", text: $draft.pinnedHostKeyAlgorithms)
                        .iosAutocapitalizationNever()
                        .autocorrectionDisabled()
                    Text("If set, connection is blocked unless the negotiated host key algorithm matches one of these values.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Shell Integration") {
                    Picker("Device / Shell Type", selection: $draft.shellIntegrationType) {
                        Text("None (default)").tag(ShellIntegrationType.none)

                        Section("Unix Shells") {
                            Text("Zsh").tag(ShellIntegrationType.zsh)
                            Text("Bash").tag(ShellIntegrationType.bash)
                            Text("Fish").tag(ShellIntegrationType.fish)
                            Text("POSIX sh").tag(ShellIntegrationType.posixSh)
                        }

                        Section("Network Vendors") {
                            Text("Cisco IOS / IOS-XE").tag(ShellIntegrationType.ciscoIOS)
                            Text("Juniper JunOS").tag(ShellIntegrationType.juniperJunOS)
                            Text("Arista EOS").tag(ShellIntegrationType.aristaEOS)
                            Text("MikroTik RouterOS").tag(ShellIntegrationType.mikrotikRouterOS)
                            Text("Palo Alto PAN-OS").tag(ShellIntegrationType.paloAltoPANOS)
                            Text("HP/Aruba ProCurve").tag(ShellIntegrationType.hpProCurve)
                            Text("Fortinet FortiOS").tag(ShellIntegrationType.fortinetFortiOS)
                            Text("Nokia SR OS").tag(ShellIntegrationType.nokiaSROS)
                        }

                        Section("Custom") {
                            Text("Custom regex").tag(ShellIntegrationType.custom)
                        }
                    }

                    if draft.shellIntegrationType == .custom {
                        TextField("Prompt regex pattern", text: $draft.customPromptRegex)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text(shellIntegrationHelpText(for: draft.shellIntegrationType))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if draft.authMethod == .keyboardInteractive, editingHostID != nil {
                    Section("Two-Factor Authentication") {
                        if let config = draft.totpConfiguration {
                            TOTPLiveCodeView(config: config, secret: totpSecret)
                            Button("Remove 2FA", role: .destructive) {
                                draft.totpConfiguration = nil
                                totpSecret = nil
                                if let hostID = editingHostID {
                                    Task { try? await totpStore?.deleteSecret(forHostID: hostID) }
                                }
                            }
                        } else {
                            Button("Set Up Two-Factor Auth") {
                                showTOTPProvisioningSheet = true
                            }
                        }
                    }
                }

                Section("Classification") {
                    TextField("Tags (comma-separated)", text: $draft.tags)
                }

                Section("Notes") {
                    TextField("Optional notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(title)
            .task(id: draft.totpConfiguration?.secretReference) {
                guard let _ = draft.totpConfiguration, let hostID = editingHostID else {
                    totpSecret = nil
                    return
                }
                totpSecret = try? await totpStore?.retrieveSecret(forHostID: hostID)
            }
            .sheet(isPresented: $showPortForwardingEditor) {
                PortForwardingRuleEditor { rule in
                    draft.portForwardingRules.append(rule)
                }
            }
            .sheet(isPresented: $showTOTPProvisioningSheet) {
                if let hostID = editingHostID {
                    TOTPProvisioningSheetView(hostID: hostID, totpStore: totpStore) { config, secret in
                        draft.totpConfiguration = config
                        totpSecret = secret
                        showTOTPProvisioningSheet = false
                    } onCancel: {
                        showTOTPProvisioningSheet = false
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                    }
                    .disabled(
                        draft.validationError != nil ||
                        draft.jumpHostValidationError(hostID: editingHostID, allHosts: availableJumpHosts) != nil
                    )
                }
            }
        }
    }

    // MARK: - Private helpers

    private func shellIntegrationHelpText(for type: ShellIntegrationType) -> String {
        switch type {
        case .none:
            return "No shell integration. The AI copilot uses generic prompt detection."
        case .zsh:
            return "Injects OSC 133 hooks via precmd/preexec. Provides command boundaries and exit codes."
        case .bash:
            return "Injects OSC 133 hooks via PROMPT_COMMAND and DEBUG trap. Provides command boundaries and exit codes."
        case .fish:
            return "Injects OSC 133 hooks via fish_prompt/fish_preexec events. Provides command boundaries and exit codes."
        case .posixSh:
            return "Limited: wraps PS1 with prompt markers only. No exit code capture (POSIX sh limitation)."
        case .ciscoIOS:
            return "Matches Cisco IOS/IOS-XE prompts (e.g. Router#, Router(config-if)#)."
        case .juniperJunOS:
            return "Matches Juniper JunOS prompts (e.g. user@host>, [edit] user@host#)."
        case .aristaEOS:
            return "Matches Arista EOS prompts (e.g. switch#, switch(config)#)."
        case .mikrotikRouterOS:
            return "Matches MikroTik RouterOS prompts (e.g. [admin@MikroTik] >)."
        case .paloAltoPANOS:
            return "Matches Palo Alto PAN-OS prompts (e.g. admin@PA-VM>, admin@PA-VM#)."
        case .hpProCurve:
            return "Matches HP/Aruba ProCurve prompts (e.g. switch#, HPswitch(config)#)."
        case .fortinetFortiOS:
            return "Matches Fortinet FortiOS prompts (e.g. FortiGate-60F#, FortiGate-60F (global)#)."
        case .nokiaSROS:
            return "Matches Nokia SR OS prompts (e.g. A:router#, A:router[/system]#)."
        case .custom:
            return "Enter a regular expression that matches your device's prompt line."
        }
    }
}

// MARK: - TOTP Live Code View

/// Displays a live-updating TOTP code with a countdown progress bar.
struct TOTPLiveCodeView: View {
    let config: TOTPConfiguration
    let secret: Data?

    @State private var codeResult: TOTPGenerator.CodeResult? = nil
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = codeResult {
                HStack(spacing: 12) {
                    Text(result.code)
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(result.isExpiringSoon ? .orange : .primary)

                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: result.progress)
                            .tint(result.isExpiringSoon ? .orange : .accentColor)
                            .frame(width: 80)
                        Text("\(result.secondsRemaining)s remaining")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let issuer = config.issuer {
                    Text(issuer + (config.accountName.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Loading code…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { refreshCode() }
        .onReceive(timer) { _ in refreshCode() }
    }

    private func refreshCode() {
        guard let secret else { return }
        codeResult = TOTPGenerator().generateCode(secret: secret, configuration: config)
    }
}

// MARK: - TOTP Provisioning Sheet

/// Sheet for provisioning TOTP via URI paste or manual Base32 entry.
struct TOTPProvisioningSheetView: View {
    let hostID: UUID
    let totpStore: TOTPStore?
    let onDone: (TOTPConfiguration, Data) -> Void
    let onCancel: () -> Void

    @State private var selectedTab = 0
    @State private var uriText = ""
    @State private var base32Text = ""
    @State private var issuerText = ""
    @State private var accountText = ""
    @State private var selectedAlgorithm: TOTPAlgorithm = .sha1
    @State private var digits = 6
    @State private var period = 30
    @State private var errorMessage: String? = nil
    @State private var isProvisioning = false

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                // Tab 1: Paste URI
                Form {
                    Section("Paste otpauth:// URI") {
                        TextField("otpauth://totp/...", text: $uriText, axis: .vertical)
                            .lineLimit(3...5)
                            .autocorrectionDisabled()
                            .iosAutocapitalizationNever()
                    }
                    if let error = errorMessage {
                        Section {
                            Text(error)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
                .tabItem { Label("Paste URI", systemImage: "link") }
                .tag(0)

                // Tab 2: Manual entry
                Form {
                    Section("Secret") {
                        TextField("Base32 secret", text: $base32Text)
                            .autocorrectionDisabled()
                            .iosAutocapitalizationNever()
                    }
                    Section("Details (optional)") {
                        TextField("Issuer (e.g. UMCG)", text: $issuerText)
                        TextField("Account name", text: $accountText)
                    }
                    Section("Parameters") {
                        Picker("Algorithm", selection: $selectedAlgorithm) {
                            ForEach(TOTPAlgorithm.allCases) { alg in
                                Text(alg.displayName).tag(alg)
                            }
                        }
                        Stepper("Digits: \(digits)", value: $digits, in: 6...8, step: 2)
                        Stepper("Period: \(period)s", value: $period, in: 15...120, step: 15)
                    }
                    if let error = errorMessage {
                        Section {
                            Text(error)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
                .tabItem { Label("Manual", systemImage: "keyboard") }
                .tag(1)
            }
            .navigationTitle("Set Up Two-Factor Auth")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        Task { await provision() }
                    }
                    .disabled(isProvisioning)
                }
            }
        }
    }

    private func provision() async {
        errorMessage = nil
        isProvisioning = true
        defer { isProvisioning = false }

        guard let store = totpStore else {
            errorMessage = "TOTP storage unavailable."
            return
        }
        let provisioningService = TOTPProvisioningService(store: store)

        do {
            let config: TOTPConfiguration
            let secret: Data
            if selectedTab == 0 {
                // URI path
                let (parsed, rawSecret) = try TOTPConfiguration.parse(otpauthURI: uriText.trimmingCharacters(in: .whitespacesAndNewlines))
                let reference = try await store.saveSecret(rawSecret, forHostID: hostID)
                config = TOTPConfiguration(
                    secretReference: reference,
                    algorithm: parsed.algorithm,
                    digits: parsed.digits,
                    period: parsed.period,
                    issuer: parsed.issuer,
                    accountName: parsed.accountName
                )
                secret = rawSecret
            } else {
                // Manual path
                let rawSecret = try Base32.decode(base32Text.trimmingCharacters(in: .whitespacesAndNewlines))
                let reference = try await store.saveSecret(rawSecret, forHostID: hostID)
                config = TOTPConfiguration(
                    secretReference: reference,
                    algorithm: selectedAlgorithm,
                    digits: digits,
                    period: period,
                    issuer: issuerText.isEmpty ? nil : issuerText,
                    accountName: accountText.isEmpty ? nil : accountText
                )
                secret = rawSecret
            }
            _ = provisioningService  // suppress unused warning
            onDone(config, secret)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
