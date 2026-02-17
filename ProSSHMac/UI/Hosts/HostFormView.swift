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
}
