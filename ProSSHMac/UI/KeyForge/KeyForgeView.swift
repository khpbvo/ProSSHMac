import SwiftUI
import UniformTypeIdentifiers

struct KeyForgeView: View {
    @EnvironmentObject private var viewModel: KeyForgeViewModel

    @State private var draft = KeyGenerationDraft()
    @State private var operationMessage: String?
    @State private var importLabel = ""
    @State private var importPassphrase = ""
    @State private var showKeyFileImporter = false

    private let rsaOptions = [2048, 3072, 4096]

    var body: some View {
        List {
            Section("Generate Key") {
                TextField("Label", text: $draft.label)
                    .iosAutocapitalizationWords()

                Picker("Type", selection: $draft.keyType) {
                    Text("Ed25519").tag(KeyType.ed25519)
                    Text("RSA").tag(KeyType.rsa)
                    Text("ECDSA").tag(KeyType.ecdsa)
                    Text("DSA").tag(KeyType.dsa)
                }

                if draft.keyType == .rsa {
                    Picker("RSA Size", selection: $draft.rsaBits) {
                        ForEach(rsaOptions, id: \.self) { bits in
                            Text("\(bits)").tag(bits)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if draft.keyType == .ecdsa {
                    Picker("ECDSA Curve", selection: $draft.ecdsaCurve) {
                        ForEach(ECDSACurve.allCases) { curve in
                            Text(curve.title).tag(curve)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if draft.keyType == .ecdsa && draft.ecdsaCurve == .p256 {
                    Toggle("Store in Secure Enclave", isOn: $draft.storeInSecureEnclave)
                }

                if draft.storeInSecureEnclave {
                    Text("Private key stays non-exportable in Secure Enclave. OpenSSH public key is generated for distribution.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Private Key Format", selection: $draft.format) {
                        Text("OpenSSH").tag(KeyFormat.openssh)
                        Text("PEM").tag(KeyFormat.pem)
                        Text("PKCS#8").tag(KeyFormat.pkcs8)
                    }
                }

                if draft.storeInSecureEnclave {
                    EmptyView()
                } else if draft.format == .openssh {
                    SecureField("Passphrase (optional)", text: $draft.passphrase)
                        .textContentType(.newPassword)

                    if !draft.passphrase.isEmpty {
                        SecureField("Confirm Passphrase", text: $draft.confirmPassphrase)
                            .textContentType(.newPassword)

                        Picker("Encryption Cipher", selection: $draft.passphraseCipher) {
                            Text(PrivateKeyCipher.chacha20Poly1305.title).tag(PrivateKeyCipher.chacha20Poly1305)
                            Text(PrivateKeyCipher.aes256ctr.title).tag(PrivateKeyCipher.aes256ctr)
                        }
                    }
                } else if !draft.passphrase.isEmpty {
                    Text("Passphrase encryption is currently available for OpenSSH format.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                TextField("Comment (optional)", text: $draft.comment)
                    .iosAutocapitalizationNever()
                    .autocorrectionDisabled()

                Button {
                    Task {
                        if await viewModel.generateKey(from: draft) {
                            operationMessage = "Key generated successfully."
                        }
                    }
                } label: {
                    if viewModel.isGenerating {
                        ProgressView()
                    } else {
                        Text("Generate Key")
                    }
                }
                .disabled(viewModel.isGenerating)
            }

            Section("Import Key") {
                TextField("Label (optional)", text: $importLabel)
                    .iosAutocapitalizationWords()

                SecureField("Passphrase (if key is encrypted)", text: $importPassphrase)
                    .textContentType(.password)

                Button {
                    let clipboard = PlatformClipboard.readString() ?? ""
                    Task {
                        let imported = await viewModel.importKeyText(
                            clipboard,
                            label: importLabel,
                            passphrase: importPassphrase,
                            source: "Clipboard"
                        )
                        if imported {
                            operationMessage = "Key imported from clipboard."
                            importLabel = ""
                            importPassphrase = ""
                        }
                    }
                } label: {
                    if viewModel.isImporting {
                        ProgressView()
                    } else {
                        Text("Import From Clipboard")
                    }
                }
                .disabled(viewModel.isImporting || viewModel.isGenerating)

                Button("Import From File") {
                    showKeyFileImporter = true
                }
                .disabled(viewModel.isImporting || viewModel.isGenerating)

                Text("AirDrop tip: open the received key file in ProSSHV2, or save it to Files and import it here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Keys") {
                if viewModel.isLoading {
                    ProgressView("Loading keys...")
                }

                if viewModel.keys.isEmpty && !viewModel.isLoading {
                    Text("No keys yet. Generate your first key above.")
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.keys) { stored in
                    NavigationLink {
                        KeyInspectorView(keyID: stored.id)
                    } label: {
                        keyRow(stored)
                    }
                }
                .onDelete { offsets in
                    Task {
                        await viewModel.deleteKeys(at: offsets)
                    }
                }
            }
        }
        .navigationTitle("KeyForge")
        .task {
            await viewModel.loadKeysIfNeeded()
        }
        .onChange(of: draft.format) { _, newFormat in
            if newFormat != .openssh {
                draft.passphrase = ""
                draft.confirmPassphrase = ""
            } else if draft.passphraseCipher != .chacha20Poly1305 {
                draft.passphraseCipher = .chacha20Poly1305
            }
        }
        .onChange(of: draft.keyType) { _, newType in
            if newType != .ecdsa {
                draft.storeInSecureEnclave = false
            }
        }
        .onChange(of: draft.ecdsaCurve) { _, newCurve in
            if newCurve != .p256 {
                draft.storeInSecureEnclave = false
            }
        }
        .onChange(of: draft.storeInSecureEnclave) { _, enabled in
            if enabled {
                draft.format = .openssh
                draft.passphrase = ""
                draft.confirmPassphrase = ""
                draft.passphraseCipher = .chacha20Poly1305
            }
        }
        .fileImporter(
            isPresented: $showKeyFileImporter,
            allowedContentTypes: [.plainText, .text, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let fileURL = urls.first else { return }
                Task {
                    let imported = await viewModel.importKeyFile(
                        at: fileURL,
                        label: importLabel,
                        passphrase: importPassphrase,
                        source: "File"
                    )
                    if imported {
                        operationMessage = "Key imported from file."
                        importLabel = ""
                        importPassphrase = ""
                    }
                }
            case let .failure(error):
                Task { @MainActor in
                    viewModel.errorMessage = "Unable to select key file: \(error.localizedDescription)"
                }
            }
        }
        .alert(
            "KeyForge",
            isPresented: Binding(
                get: { operationMessage != nil },
                set: { if !$0 { operationMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                operationMessage = nil
            }
        } message: {
            Text(operationMessage ?? "")
        }
        .alert(
            "Issue",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { _ in viewModel.clearError() }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.clearError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private func keyRow(_ stored: StoredSSHKey) -> some View {
        let key = stored.metadata

        VStack(alignment: .leading, spacing: 6) {
            Text(key.label)
                .font(.headline)

            Text("\(keyTypeTitle(key.type, bitLength: key.bitLength)) · \(key.format.rawValue.uppercased())")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if key.storageLocation == .secureEnclave {
                Text("Stored in Secure Enclave")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if key.isPassphraseProtected {
                Text("Passphrase Protected (\(key.passphraseCipher?.title ?? "Unknown"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(key.fingerprint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func keyTypeTitle(_ keyType: KeyType, bitLength: Int?) -> String {
        switch keyType {
        case .rsa:
            return "RSA-\(bitLength ?? 0)"
        case .ed25519:
            return "Ed25519"
        case .ecdsa:
            return "ECDSA P-\(bitLength ?? 0)"
        case .dsa:
            return "DSA-\(bitLength ?? 1024)"
        }
    }
}
