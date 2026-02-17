import SwiftUI

struct CertificatesView: View {
    @EnvironmentObject private var viewModel: CertificatesViewModel

    @State private var draft = CertificateAuthorityDraft()
    @State private var userDraft = UserCertificateDraft()
    @State private var hostDraft = HostCertificateDraft()
    @State private var krlDraft = KRLGenerationDraft()
    @State private var importCertificateInput = ""
    @State private var generatedKRLBundle: GeneratedKRLBundle?
    @State private var operationMessage: String?

    var body: some View {
        List {
            createCASection
            signUserCertificateSection
            signHostCertificateSection
            importCertificateSection
            generateKRLSection
            authoritiesSection
            issuedCertificatesSection
        }
        .navigationTitle("Certificates")
        .task {
            await viewModel.loadAuthoritiesIfNeeded()
            seedUserDraftDefaultsIfNeeded()
            seedHostDraftDefaultsIfNeeded()
        }
        .onChange(of: userDraft.authorityID) { _, newValue in
            userDraft.applyAuthorityDefaults(viewModel.authority(for: newValue))
        }
        .onChange(of: hostDraft.authorityID) { _, newValue in
            hostDraft.applyAuthorityDefaults(viewModel.authority(for: newValue))
        }
        .alert(
            "Certificates",
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

    private var createCASection: some View {
        Section("Create CA") {
            TextField("CA Label", text: $draft.label)
                .iosAutocapitalizationWords()

            Picker("Certificate Type", selection: $draft.certificateType) {
                Text("User").tag(CertificateType.user)
                Text("Host").tag(CertificateType.host)
                Text("Both").tag(CertificateType.both)
            }

            Stepper(value: $draft.defaultValidityDays, in: 1...3650) {
                Text("Default Validity: \(draft.defaultValidityDays) days")
            }

            TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                .lineLimit(2...4)

            Text("CA keypair uses Secure Enclave backed ECDSA P-256 and remains non-exportable.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    let created = await viewModel.createAuthority(from: draft)
                    if created {
                        operationMessage = "Certificate authority created."
                        draft = CertificateAuthorityDraft()

                        if userDraft.authorityID == nil {
                            userDraft.authorityID = userSigningAuthorities.first?.id
                        }
                        userDraft.applyAuthorityDefaults(viewModel.authority(for: userDraft.authorityID))

                        if hostDraft.authorityID == nil {
                            hostDraft.authorityID = hostSigningAuthorities.first?.id
                        }
                        hostDraft.applyAuthorityDefaults(viewModel.authority(for: hostDraft.authorityID))
                    }
                }
            } label: {
                if viewModel.isGeneratingAuthority {
                    ProgressView()
                } else {
                    Text("Generate CA Keypair")
                }
            }
            .disabled(viewModel.isGeneratingAuthority)
        }
    }

    private var signUserCertificateSection: some View {
        Section("Sign User Certificate") {
            if userSigningAuthorities.isEmpty {
                Text("Create a CA with user or both certificate type first.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Signing CA", selection: $userDraft.authorityID) {
                    ForEach(userSigningAuthorities) { authority in
                        Text("\(authority.label) (\(authority.certificateType.rawValue))")
                            .tag(Optional(authority.id))
                    }
                }

                HStack {
                    TextField("Serial Number", text: $userDraft.serialNumber)
                        .iosKeyboardNumberPad()
                    Button("Use Next") {
                        if let authority = viewModel.authority(for: userDraft.authorityID) {
                            userDraft.serialNumber = String(authority.nextSerialNumber)
                        }
                    }
                    .buttonStyle(.borderless)
                }

                TextField("Certificate Key ID", text: $userDraft.keyID)
                TextField("Principals (comma or newline separated)", text: $userDraft.principals, axis: .vertical)
                    .lineLimit(2...4)

                DatePicker("Valid After", selection: $userDraft.validAfter)
                DatePicker("Valid Before", selection: $userDraft.validBefore)

                TextField("Subject Public Key (authorized format)", text: $userDraft.subjectPublicKeyAuthorized, axis: .vertical)
                    .lineLimit(3...6)
                    .iosAutocapitalizationNever()
                    .autocorrectionDisabled()

                TextField("Critical Options (name=value per line)", text: $userDraft.criticalOptions, axis: .vertical)
                    .lineLimit(2...5)
                    .iosAutocapitalizationNever()
                    .autocorrectionDisabled()

                TextField("Extensions (name=value per line)", text: $userDraft.extensions, axis: .vertical)
                    .lineLimit(2...5)
                    .iosAutocapitalizationNever()
                    .autocorrectionDisabled()

                Text("Set empty value as just 'name'. Example extension: permit-pty")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        let signed = await viewModel.signUserCertificate(from: userDraft)
                        if signed {
                            operationMessage = "User certificate signed."
                            if let authority = viewModel.authority(for: userDraft.authorityID) {
                                userDraft.serialNumber = String(authority.nextSerialNumber)
                            }
                        }
                    }
                } label: {
                    if viewModel.isSigningCertificate {
                        ProgressView()
                    } else {
                        Text("Sign User Certificate")
                    }
                }
                .disabled(viewModel.isSigningCertificate)
            }
        }
    }

    private var signHostCertificateSection: some View {
        Section("Sign Host Certificate") {
            if hostSigningAuthorities.isEmpty {
                Text("Create a CA with host or both certificate type first.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Signing CA", selection: $hostDraft.authorityID) {
                    ForEach(hostSigningAuthorities) { authority in
                        Text("\(authority.label) (\(authority.certificateType.rawValue))")
                            .tag(Optional(authority.id))
                    }
                }

                HStack {
                    TextField("Serial Number", text: $hostDraft.serialNumber)
                        .iosKeyboardNumberPad()
                    Button("Use Next") {
                        if let authority = viewModel.authority(for: hostDraft.authorityID) {
                            hostDraft.serialNumber = String(authority.nextSerialNumber)
                        }
                    }
                    .buttonStyle(.borderless)
                }

                TextField("Certificate Key ID", text: $hostDraft.keyID)
                TextField("Host Principals (comma or newline separated)", text: $hostDraft.hostPrincipals, axis: .vertical)
                    .lineLimit(2...4)

                DatePicker("Valid After", selection: $hostDraft.validAfter)
                DatePicker("Valid Before", selection: $hostDraft.validBefore)

                TextField("Host Public Key (authorized format)", text: $hostDraft.subjectPublicKeyAuthorized, axis: .vertical)
                    .lineLimit(3...6)
                    .iosAutocapitalizationNever()
                    .autocorrectionDisabled()

                TextField("Critical Options (name=value per line)", text: $hostDraft.criticalOptions, axis: .vertical)
                    .lineLimit(2...5)
                    .iosAutocapitalizationNever()
                    .autocorrectionDisabled()

                TextField("Extensions (name=value per line)", text: $hostDraft.extensions, axis: .vertical)
                    .lineLimit(2...5)
                    .iosAutocapitalizationNever()
                    .autocorrectionDisabled()

                Text("Set empty value as just 'name'.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        let signed = await viewModel.signHostCertificate(from: hostDraft)
                        if signed {
                            operationMessage = "Host certificate signed."
                            if let authority = viewModel.authority(for: hostDraft.authorityID) {
                                hostDraft.serialNumber = String(authority.nextSerialNumber)
                            }
                        }
                    }
                } label: {
                    if viewModel.isSigningCertificate {
                        ProgressView()
                    } else {
                        Text("Sign Host Certificate")
                    }
                }
                .disabled(viewModel.isSigningCertificate)
            }
        }
    }

    private var importCertificateSection: some View {
        Section("Import Certificate") {
            TextField("OpenSSH certificate line", text: $importCertificateInput, axis: .vertical)
                .lineLimit(3...6)
                .iosAutocapitalizationNever()
                .autocorrectionDisabled()

            Button("Paste from Clipboard") {
                guard let clipboard = PlatformClipboard.readString()?.trimmingCharacters(in: .whitespacesAndNewlines), !clipboard.isEmpty else {
                    operationMessage = "Clipboard is empty."
                    return
                }
                importCertificateInput = clipboard
            }
            .buttonStyle(.borderless)

            Button {
                Task {
                    let imported = await viewModel.importExternalCertificate(from: importCertificateInput)
                    if imported {
                        operationMessage = "Certificate imported from external CA."
                        importCertificateInput = ""
                    }
                }
            } label: {
                if viewModel.isImportingCertificate {
                    ProgressView()
                } else {
                    Text("Import External Certificate")
                }
            }
            .disabled(viewModel.isImportingCertificate || importCertificateInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text("Paste a full OpenSSH certificate entry (e.g. ssh-ed25519-cert-v01@openssh.com ...).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var generateKRLSection: some View {
        Section("Generate KRL") {
            Picker("CA Scope", selection: $krlDraft.authorityID) {
                Text("All Certificate Authorities").tag(UUID?.none)
                ForEach(viewModel.authorities) { authority in
                    Text(authority.label).tag(Optional(authority.id))
                }
            }

            TextField("Compromised Serials (comma/newline)", text: $krlDraft.revokedSerials, axis: .vertical)
                .lineLimit(2...4)
                .iosAutocapitalizationNever()
                .autocorrectionDisabled()

            Toggle("Include Expired Certificates", isOn: $krlDraft.includeExpiredCertificates)

            Text("Use serials for compromised certs. The generated bundle includes revoked keys plus an ssh-keygen command to build a .krl file.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                if let generated = viewModel.generateKRL(from: krlDraft) {
                    generatedKRLBundle = generated
                    operationMessage = "KRL bundle generated for \(generated.revokedCertificateCount) certificate(s)."
                }
            } label: {
                if viewModel.isGeneratingKRL {
                    ProgressView()
                } else {
                    Text("Generate KRL Bundle")
                }
            }
            .disabled(viewModel.isGeneratingKRL)

            if let generatedKRLBundle {
                Text("Output stem: \(generatedKRLBundle.fileStem)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(generatedKRLBundle.openSSHCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)

                Button("Copy ssh-keygen Command") {
                    PlatformClipboard.writeString(generatedKRLBundle.openSSHCommand)
                    operationMessage = "ssh-keygen command copied."
                }
                .buttonStyle(.borderless)

                Button("Copy Revoked Keys File") {
                    PlatformClipboard.writeString(generatedKRLBundle.revokedKeysContent)
                    operationMessage = "Revoked keys file copied."
                }
                .buttonStyle(.borderless)

                Button("Copy KRL Manifest") {
                    PlatformClipboard.writeString(generatedKRLBundle.manifestContent)
                    operationMessage = "KRL manifest copied."
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var authoritiesSection: some View {
        Section("Certificate Authorities") {
            if viewModel.isLoading {
                ProgressView("Loading certificate authorities...")
            }

            if viewModel.authorities.isEmpty && !viewModel.isLoading {
                Text("No certificate authorities yet. Generate one above.")
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.authorities) { authority in
                VStack(alignment: .leading, spacing: 6) {
                    Text(authority.label)
                        .font(.headline)

                    Text("Type: \(authority.certificateType.rawValue.capitalized) · Key: \(keyTypeTitle(authority.keyType))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Fingerprint: \(authority.publicKeyFingerprint)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    Text("Issued: \(authority.issuedCertificateCount) · Next serial: \(authority.nextSerialNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let publicKey = authority.publicKeyAuthorizedFormat, !publicKey.isEmpty {
                        Text(publicKey)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)

                        Button("Copy CA Public Key") {
                            PlatformClipboard.writeString(publicKey)
                            operationMessage = "CA public key copied."
                        }
                        .buttonStyle(.borderless)
                    }

                    Text("Created: \(authority.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                Task {
                    await viewModel.deleteAuthorities(at: offsets)
                }
            }
        }
    }

    private var issuedCertificatesSection: some View {
        Section("Issued Certificates") {
            if viewModel.certificates.isEmpty {
                Text("No certificates issued yet.")
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.certificates) { certificate in
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink {
                        CertificateInspectorView(certificate: certificate)
                    } label: {
                        certificateSummaryRow(certificate)
                    }

                    Button("Copy Signed Certificate") {
                        PlatformClipboard.writeString(certificate.authorizedRepresentation ?? certificate.rawCertificateData.base64EncodedString())
                        operationMessage = "Signed certificate copied."
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func seedUserDraftDefaultsIfNeeded() {
        if userDraft.authorityID == nil {
            userDraft.authorityID = userSigningAuthorities.first?.id
        }
        userDraft.applyAuthorityDefaults(viewModel.authority(for: userDraft.authorityID))
    }

    private func seedHostDraftDefaultsIfNeeded() {
        if hostDraft.authorityID == nil {
            hostDraft.authorityID = hostSigningAuthorities.first?.id
        }
        hostDraft.applyAuthorityDefaults(viewModel.authority(for: hostDraft.authorityID))
    }

    private func keyTypeTitle(_ keyType: KeyType) -> String {
        switch keyType {
        case .rsa:
            return "RSA"
        case .ed25519:
            return "Ed25519"
        case .ecdsa:
            return "ECDSA P-256"
        case .dsa:
            return "DSA"
        }
    }

    @ViewBuilder
    private func certificateSummaryRow(_ certificate: SSHCertificate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(certificate.keyId)
                .font(.headline)

            Text("Serial: \(certificate.serialNumber) · Type: \(certificate.type.rawValue.capitalized) · \(certificateStatus(certificate))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Principals: \(certificate.principals.isEmpty ? "None" : certificate.principals.joined(separator: ", "))")
                .font(.caption)
                .lineLimit(2)

            Text("Extensions: \(certificate.extensions.isEmpty ? "None" : certificate.extensions.joined(separator: ", "))")
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func certificateStatus(_ certificate: SSHCertificate) -> String {
        let now = Date()
        if now < certificate.validAfter {
            return "Not Yet Valid"
        }
        if now > certificate.validBefore {
            return "Expired"
        }
        return "Active"
    }

    private var userSigningAuthorities: [CertificateAuthorityModel] {
        viewModel.authorities.filter { $0.certificateType != .host }
    }

    private var hostSigningAuthorities: [CertificateAuthorityModel] {
        viewModel.authorities.filter { $0.certificateType != .user }
    }
}
