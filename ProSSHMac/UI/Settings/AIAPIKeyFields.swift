import SwiftUI

/// Key entry for one AI provider: secure field, paste, saved-key hint, Save/Remove, status.
struct AIAPIKeyFields: View {
    @ObservedObject var viewModel: AIKeySettingsViewModel

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(viewModel.providerName) API Key")
                    .font(.subheadline)

                SecureField("API key...", text: $viewModel.apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                HStack {
                    Button("Paste from Clipboard") {
                        viewModel.pasteFromClipboard()
                    }
                    .buttonStyle(.borderless)

                    Spacer()
                }
            }

            Text("Stored securely in the device Keychain and used by the AI assistant service.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if viewModel.hasStoredAPIKey {
                Label(
                    "Saved key: \(viewModel.storedKeyHint ?? "••••")",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.green)
            } else {
                Text("No API key saved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Save API Key") {
                    Task {
                        await viewModel.saveAPIKey()
                    }
                }
                .disabled(viewModel.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Remove API Key", role: .destructive) {
                    Task {
                        await viewModel.removeAPIKey()
                    }
                }
                .disabled(!viewModel.hasStoredAPIKey)
            }

            if let statusMessage = viewModel.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
