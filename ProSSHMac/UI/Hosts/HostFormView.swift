import SwiftUI

struct HostFormView: View {
    let title: String
    @Binding var draft: HostDraft
    let availableJumpHosts: [Host]
    let availableKeys: [StoredSSHKey]
    let editingHostID: UUID?
    let onSave: (HostDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showPortForwardingEditor = false

    init(
        title: String,
        draft: Binding<HostDraft>,
        availableJumpHosts: [Host] = [],
        availableKeys: [StoredSSHKey] = [],
        editingHostID: UUID? = nil,
        onSave: @escaping (HostDraft) -> Void
    ) {
        self.title = title
        self._draft = draft
        self.availableJumpHosts = availableJumpHosts
        self.availableKeys = availableKeys
        self.editingHostID = editingHostID
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

                Section("Classification") {
                    TextField("Tags (comma-separated)", text: $draft.tags)
                }

                Section("Notes") {
                    TextField("Optional notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(title)
            .sheet(isPresented: $showPortForwardingEditor) {
                PortForwardingRuleEditor { rule in
                    draft.portForwardingRules.append(rule)
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
