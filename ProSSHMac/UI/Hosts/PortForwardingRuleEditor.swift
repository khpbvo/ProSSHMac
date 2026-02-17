import SwiftUI

struct PortForwardingRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""
    @State private var localPort: String = ""
    @State private var remoteHost: String = "localhost"
    @State private var remotePort: String = ""

    let onSave: (PortForwardingRule) -> Void

    private var validationError: String? {
        guard let lp = UInt16(localPort), lp > 0 else {
            return "Local port must be between 1 and 65535."
        }
        if remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Remote host is required."
        }
        guard let rp = UInt16(remotePort), rp > 0 else {
            return "Remote port must be between 1 and 65535."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Forwarding Rule") {
                    TextField("Label (optional)", text: $label)
                    TextField("Local Port", text: $localPort)
                        .iosKeyboardNumberPad()
                    TextField("Remote Host", text: $remoteHost)
                        .iosAutocapitalizationNever()
                        .autocorrectionDisabled()
                    TextField("Remote Port", text: $remotePort)
                        .iosKeyboardNumberPad()
                }

                if let error = validationError {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Forwarding Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let lp = UInt16(localPort),
                              let rp = UInt16(remotePort) else { return }
                        let rule = PortForwardingRule(
                            localPort: lp,
                            remoteHost: remoteHost.trimmingCharacters(in: .whitespacesAndNewlines),
                            remotePort: rp,
                            label: label.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        onSave(rule)
                        dismiss()
                    }
                    .disabled(validationError != nil)
                }
            }
        }
    }
}
