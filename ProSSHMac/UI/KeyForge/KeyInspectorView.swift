import SwiftUI

struct KeyInspectorView: View {
    let keyID: UUID

    @EnvironmentObject private var viewModel: KeyForgeViewModel
    @EnvironmentObject private var hostListViewModel: HostListViewModel

    @State private var operationMessage: String?
    @State private var conversionTargetFormat: KeyFormat = .pem
    @State private var sourcePassphrase = ""
    @State private var outputPassphrase = ""
    @State private var confirmOutputPassphrase = ""
    @State private var outputPassphraseCipher: PrivateKeyCipher = .chacha20Poly1305
    @State private var selectedCopyIDHostID: UUID?
    @State private var copyIDHostPassword = ""
    @State private var copyIDPrivateKeyPassphrase = ""

    var body: some View {
        Group {
            if let storedKey = currentStoredKey {
                let key = storedKey.metadata

                List {
                    Section("Overview") {
                        detailRow("Label", value: key.label)
                        detailRow("Type", value: keyTypeTitle(key.type, bitLength: key.bitLength))
                        detailRow("Format", value: key.format.rawValue.uppercased())
                        detailRow("Storage", value: storageLocationTitle(key.storageLocation))
                        detailRow("Created", value: key.createdAt.formatted(date: .abbreviated, time: .shortened))
                        detailRow("Encryption", value: encryptionStatus(for: key))

                        if let comment = key.comment, !comment.isEmpty {
                            detailRow("Comment", value: comment)
                        }

                        if let importedFrom = key.importedFrom, !importedFrom.isEmpty {
                            detailRow("Source", value: importedFrom)
                        }
                    }

                    Section("Fingerprints") {
                        selectableRow("SHA-256", value: key.fingerprint)
                        selectableRow("MD5", value: key.fingerprintMD5)
                        selectableRow("Bubble Babble", value: key.bubbleBabbleFingerprint)
                    }

                    Section("Public Key") {
                        Text(storedKey.publicKey)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)

                        Button("Copy Public Key") {
                            PlatformClipboard.writeString(storedKey.publicKey)
                            operationMessage = "Public key copied."
                        }
                    }

                    Section("Format Conversion") {
                        if key.storageLocation == .secureEnclave {
                            Text("Secure Enclave private keys are non-exportable and cannot be converted to other formats.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            detailRow("Current Format", value: key.format.rawValue.uppercased())

                            Picker("Target Format", selection: $conversionTargetFormat) {
                                Text("OpenSSH").tag(KeyFormat.openssh)
                                Text("PEM").tag(KeyFormat.pem)
                                Text("PKCS#8").tag(KeyFormat.pkcs8)
                            }

                            if key.isPassphraseProtected {
                                SecureField("Current Passphrase", text: $sourcePassphrase)
                                    .textContentType(.password)
                            }

                            if conversionTargetFormat == .openssh {
                                SecureField("New Passphrase (optional)", text: $outputPassphrase)
                                    .textContentType(.newPassword)

                                if !outputPassphrase.isEmpty {
                                    SecureField("Confirm New Passphrase", text: $confirmOutputPassphrase)
                                        .textContentType(.newPassword)

                                    Picker("Output Cipher", selection: $outputPassphraseCipher) {
                                        Text(PrivateKeyCipher.chacha20Poly1305.title)
                                            .tag(PrivateKeyCipher.chacha20Poly1305)
                                        Text(PrivateKeyCipher.aes256ctr.title)
                                            .tag(PrivateKeyCipher.aes256ctr)
                                    }
                                }
                            } else if !outputPassphrase.isEmpty {
                                Text("Output passphrase encryption is currently supported for OpenSSH format only.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Button {
                                Task {
                                    let converted = await viewModel.convertKey(
                                        id: keyID,
                                        targetFormat: conversionTargetFormat,
                                        currentPassphrase: sourcePassphrase,
                                        newPassphrase: outputPassphrase,
                                        confirmNewPassphrase: confirmOutputPassphrase,
                                        newPassphraseCipher: outputPassphraseCipher
                                    )

                                    if converted {
                                        sourcePassphrase = ""
                                        outputPassphrase = ""
                                        confirmOutputPassphrase = ""
                                        operationMessage = "Key converted to \(conversionTargetFormat.rawValue.uppercased())."
                                    }
                                }
                            } label: {
                                if viewModel.isConverting {
                                    ProgressView()
                                } else {
                                    Text("Convert Key Format")
                                }
                            }
                            .disabled(viewModel.isConverting || conversionTargetFormat == key.format)
                        }
                    }

                    Section("ssh-copy-id") {
                        if key.storageLocation == .secureEnclave {
                            Text("ssh-copy-id verification currently requires exportable private key material and is unavailable for Secure Enclave keys.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if hostListViewModel.isLoading {
                            ProgressView("Loading hosts...")
                        } else if hostListViewModel.hosts.isEmpty {
                            Text("No hosts available. Add a host in the Hosts tab first.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Target Host", selection: $selectedCopyIDHostID) {
                                Text("Select a host").tag(Optional<UUID>.none)
                                ForEach(hostListViewModel.hosts) { host in
                                    Text("\(host.label) (\(host.username)@\(host.hostname):\(host.port))")
                                        .tag(Optional(host.id))
                                }
                            }

                            SecureField("Host Password", text: $copyIDHostPassword)
                                .textContentType(.password)

                            if key.isPassphraseProtected {
                                SecureField("Key Passphrase", text: $copyIDPrivateKeyPassphrase)
                                    .textContentType(.password)
                            }

                            Button {
                                guard let selectedHostID = selectedCopyIDHostID,
                                      let selectedHost = hostListViewModel.hosts.first(where: { $0.id == selectedHostID }) else {
                                    viewModel.errorMessage = "Select a target host first."
                                    return
                                }

                                Task {
                                    let copied = await viewModel.copyPublicKeyToHost(
                                        keyID: keyID,
                                        host: selectedHost,
                                        hostPassword: copyIDHostPassword,
                                        privateKeyPassphrase: copyIDPrivateKeyPassphrase
                                    )

                                    if copied {
                                        copyIDHostPassword = ""
                                        copyIDPrivateKeyPassphrase = ""
                                        operationMessage = "Public key installed and verified on \(selectedHost.label)."
                                    }
                                }
                            } label: {
                                if viewModel.isCopyingPublicKey {
                                    ProgressView()
                                } else {
                                    Text("Run ssh-copy-id")
                                }
                            }
                            .disabled(
                                viewModel.isCopyingPublicKey ||
                                selectedCopyIDHostID == nil ||
                                copyIDHostPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )

                            Text("Uses password auth to install key, sets ~/.ssh permissions, then verifies key-based login before success.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Certificates") {
                        if key.associatedCertificates.isEmpty {
                            Text("No associated certificates.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(key.associatedCertificates, id: \.self) { certificateID in
                                Text(certificateID.uuidString)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .navigationTitle("Key Inspector")
                .task {
                    await hostListViewModel.loadHostsIfNeeded()
                }
                .onAppear {
                    if conversionTargetFormat == key.format {
                        conversionTargetFormat = preferredConversionTarget(for: key.format)
                    }
                    if selectedCopyIDHostID == nil {
                        selectedCopyIDHostID = key.preferredCopyIDHostID ?? hostListViewModel.hosts.first?.id
                    }
                }
                .onChange(of: selectedCopyIDHostID) { _, newHostID in
                    Task {
                        await viewModel.updatePreferredCopyIDHost(keyID: keyID, hostID: newHostID)
                    }
                }
                .onChange(of: key.format) { _, newFormat in
                    if conversionTargetFormat == newFormat {
                        conversionTargetFormat = preferredConversionTarget(for: newFormat)
                    }

                    if newFormat != .openssh {
                        outputPassphrase = ""
                        confirmOutputPassphrase = ""
                        outputPassphraseCipher = .chacha20Poly1305
                    }
                }
                .onChange(of: hostListViewModel.hosts) { _, hosts in
                    if let selectedCopyIDHostID,
                       hosts.contains(where: { $0.id == selectedCopyIDHostID }) {
                        return
                    }
                    selectedCopyIDHostID = hosts.first?.id
                }
            } else {
                ContentUnavailableView(
                    "Key Not Found",
                    systemImage: "key.slash",
                    description: Text("The selected key is no longer available.")
                )
                .navigationTitle("Key Inspector")
            }
        }
        .alert(
            "Key Inspector",
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

    private var currentStoredKey: StoredSSHKey? {
        viewModel.keys.first(where: { $0.id == keyID })
    }

    @ViewBuilder
    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func selectableRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func encryptionStatus(for key: SSHKey) -> String {
        if key.isPassphraseProtected {
            if let cipher = key.passphraseCipher {
                return "Passphrase Protected (\(cipher.title))"
            }
            return "Passphrase Protected"
        }
        return "Not Passphrase Protected"
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

    private func preferredConversionTarget(for currentFormat: KeyFormat) -> KeyFormat {
        switch currentFormat {
        case .openssh:
            return .pem
        case .pem:
            return .pkcs8
        case .pkcs8:
            return .openssh
        }
    }

    private func storageLocationTitle(_ storageLocation: StorageLocation) -> String {
        switch storageLocation {
        case .secureEnclave:
            return "Secure Enclave"
        case .encryptedStorage:
            return "Encrypted Storage"
        }
    }
}

private extension SSHKey {
    var bubbleBabbleFingerprint: String {
        guard let bytes = md5FingerprintBytes, !bytes.isEmpty else {
            return "Unavailable"
        }
        return BubbleBabble.encode(bytes: bytes)
    }

    var md5FingerprintBytes: [UInt8]? {
        let normalized = fingerprintMD5
            .replacingOccurrences(of: "MD5:", with: "")
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty, normalized.count % 2 == 0 else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.count / 2)

        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let value = UInt8(normalized[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(value)
            index = next
        }

        return bytes
    }
}

private enum BubbleBabble {
    private static let vowels: [Character] = Array("aeiouy")
    private static let consonants: [Character] = Array("bcdfghklmnprstvzx")

    static func encode(bytes: [UInt8]) -> String {
        var seed = 1
        let rounds = (bytes.count / 2) + 1
        var result: [Character] = ["x"]

        for round in 0..<rounds {
            if round + 1 < rounds || bytes.count % 2 != 0 {
                let first = bytes[round * 2]

                let i0 = (((Int(first) >> 6) & 0x03) + seed) % 6
                let i1 = (Int(first) >> 2) & 0x0f
                let i2 = ((Int(first) & 0x03) + (seed / 6)) % 6

                result.append(vowels[i0])
                result.append(consonants[i1])
                result.append(vowels[i2])

                if round + 1 < rounds {
                    let second = bytes[(round * 2) + 1]
                    let i3 = (Int(second) >> 4) & 0x0f
                    let i4 = Int(second) & 0x0f

                    result.append(consonants[i3])
                    result.append("-")
                    result.append(consonants[i4])

                    seed = ((seed * 5) + (Int(first) * 7) + Int(second)) % 36
                }
            } else {
                let i0 = seed % 6
                let i1 = 16
                let i2 = seed / 6
                result.append(vowels[i0])
                result.append(consonants[i1])
                result.append(vowels[i2])
            }
        }

        result.append("x")
        return String(result)
    }
}
