import Foundation
import Combine

struct KeyGenerationDraft: Equatable {
    var label = ""
    var keyType: KeyType = .ed25519
    var rsaBits: Int = 4096
    var ecdsaCurve: ECDSACurve = .p256
    var storeInSecureEnclave = false
    var format: KeyFormat = .openssh
    var passphrase = ""
    var confirmPassphrase = ""
    var passphraseCipher: PrivateKeyCipher = .chacha20Poly1305
    var comment = ""

    var validationError: String? {
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A key label is required."
        }

        if keyType == .rsa {
            let allowed = [2048, 3072, 4096]
            if !allowed.contains(rsaBits) {
                return "RSA key size must be 2048, 3072, or 4096."
            }
        }

        if storeInSecureEnclave {
            if keyType != .ecdsa || ecdsaCurve != .p256 {
                return "Secure Enclave storage is available for ECDSA P-256 keys only."
            }
        }

        let normalizedPassphrase = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedPassphrase.isEmpty {
            if storeInSecureEnclave {
                return "Passphrase encryption is unavailable for non-exportable Secure Enclave keys."
            }

            if format != .openssh {
                return "Passphrase encryption is currently available for OpenSSH format only."
            }

            if normalizedPassphrase.count < 8 {
                return "Passphrase must be at least 8 characters."
            }

            let normalizedConfirm = confirmPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedPassphrase != normalizedConfirm {
                return "Passphrase confirmation does not match."
            }
        }

        return nil
    }

    func toRequest() -> KeyGenerationRequest {
        KeyGenerationRequest(
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            keyType: keyType,
            rsaBits: rsaBits,
            ecdsaCurve: ecdsaCurve,
            storeInSecureEnclave: storeInSecureEnclave,
            format: format,
            passphrase: normalizedPassphrase,
            passphraseCipher: passphraseCipher,
            comment: normalizedComment
        )
    }

    private var normalizedComment: String {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private var normalizedPassphrase: String? {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class KeyForgeViewModel: ObservableObject {
    @Published private(set) var keys: [StoredSSHKey] = []
    @Published var isLoading = false
    @Published var isGenerating = false
    @Published var isImporting = false
    @Published var isConverting = false
    @Published var isCopyingPublicKey = false
    @Published var errorMessage: String?

    private let keyStore: any KeyStoreProtocol
    private let keyForgeService: KeyForgeService
    private var hasLoaded = false

    init(
        keyStore: any KeyStoreProtocol,
        keyForgeService: KeyForgeService
    ) {
        self.keyStore = keyStore
        self.keyForgeService = keyForgeService
    }

    func loadKeysIfNeeded() async {
        guard !hasLoaded else { return }
        await loadKeys()
    }

    func loadKeys() async {
        isLoading = true
        defer { isLoading = false }

        do {
            keys = try await keyStore.loadKeys().sorted(by: Self.sortKeys)
            hasLoaded = true
        } catch {
            errorMessage = "Failed to load keys: \(error.localizedDescription)"
        }
    }

    func generateKey(from draft: KeyGenerationDraft) async -> Bool {
        if let validationError = draft.validationError {
            errorMessage = validationError
            return false
        }

        isGenerating = true
        defer { isGenerating = false }

        do {
            let generated = try keyForgeService.generateKey(request: draft.toRequest())
            keys.insert(generated, at: 0)
            keys.sort(by: Self.sortKeys)
            try await keyStore.saveKeys(keys)
            return true
        } catch {
            errorMessage = "Failed to generate key: \(error.localizedDescription)"
            return false
        }
    }

    func deleteKeys(at offsets: IndexSet) async {
        for index in offsets.sorted(by: >) {
            let deleting = keys[index]
            keyForgeService.deleteStoredKeyMaterial(deleting)
            keys.remove(at: index)
        }

        do {
            try await keyStore.saveKeys(keys)
        } catch {
            errorMessage = "Failed to persist key deletion: \(error.localizedDescription)"
        }
    }

    func importKeyText(
        _ keyText: String,
        label: String,
        passphrase: String?,
        source: String
    ) async -> Bool {
        let normalizedText = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedText.isEmpty {
            errorMessage = "No key text found to import."
            return false
        }

        isImporting = true
        defer { isImporting = false }

        do {
            let imported = try keyForgeService.importKey(
                request: KeyImportRequest(
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label,
                    keyText: normalizedText,
                    passphrase: passphrase?.trimmingCharacters(in: .whitespacesAndNewlines),
                    source: source
                )
            )
            keys.insert(imported, at: 0)
            keys.sort(by: Self.sortKeys)
            try await keyStore.saveKeys(keys)
            return true
        } catch {
            errorMessage = "Failed to import key: \(error.localizedDescription)"
            return false
        }
    }

    func importKeyFile(
        at url: URL,
        label: String,
        passphrase: String?,
        source: String
    ) async -> Bool {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let keyText = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii)
            guard let keyText else {
                errorMessage = "Selected file is not valid UTF-8/ASCII text."
                return false
            }

            let sourceLabel = "\(source): \(url.lastPathComponent)"
            return await importKeyText(
                keyText,
                label: label,
                passphrase: passphrase,
                source: sourceLabel
            )
        } catch {
            errorMessage = "Failed to read key file: \(error.localizedDescription)"
            return false
        }
    }

    func importAirDroppedKeyFile(at url: URL) async {
        let suggestedLabel = url.deletingPathExtension().lastPathComponent
        _ = await importKeyFile(
            at: url,
            label: suggestedLabel,
            passphrase: nil,
            source: "AirDrop"
        )
    }

    func convertKey(
        id: UUID,
        targetFormat: KeyFormat,
        currentPassphrase: String?,
        newPassphrase: String?,
        confirmNewPassphrase: String?,
        newPassphraseCipher: PrivateKeyCipher
    ) async -> Bool {
        guard let index = keys.firstIndex(where: { $0.id == id }) else {
            errorMessage = "Unable to find selected key."
            return false
        }

        var existing = keys[index]
        if existing.metadata.storageLocation == .secureEnclave {
            errorMessage = "Secure Enclave keys are non-exportable and cannot be format-converted."
            return false
        }
        if existing.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "This key only contains public material. Import the private key to convert formats."
            return false
        }

        if targetFormat == existing.metadata.format {
            errorMessage = "Select a different target format for conversion."
            return false
        }

        let normalizedCurrentPassphrase = currentPassphrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNewPassphrase = newPassphrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConfirmNewPassphrase = confirmNewPassphrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if existing.metadata.isPassphraseProtected &&
            (normalizedCurrentPassphrase == nil || normalizedCurrentPassphrase?.isEmpty == true) {
            errorMessage = "Current passphrase is required to convert this encrypted key."
            return false
        }

        if let normalizedNewPassphrase, !normalizedNewPassphrase.isEmpty {
            if targetFormat != .openssh {
                errorMessage = "Output passphrase encryption is currently supported for OpenSSH format only."
                return false
            }

            if normalizedNewPassphrase.count < 8 {
                errorMessage = "New passphrase must be at least 8 characters."
                return false
            }

            if normalizedNewPassphrase != (normalizedConfirmNewPassphrase ?? "") {
                errorMessage = "New passphrase confirmation does not match."
                return false
            }
        }

        isConverting = true
        defer { isConverting = false }

        do {
            let conversion = try keyForgeService.convertPrivateKey(
                request: KeyConversionRequest(
                    privateKeyText: existing.privateKey,
                    targetFormat: targetFormat,
                    inputPassphrase: normalizedCurrentPassphrase,
                    outputPassphrase: normalizedNewPassphrase,
                    outputPassphraseCipher: newPassphraseCipher,
                    comment: existing.metadata.comment ?? existing.metadata.label
                )
            )

            existing.privateKey = conversion.privateKey
            existing.publicKey = conversion.publicKey
            existing.metadata.publicKeyAuthorizedFormat = conversion.publicKey
            existing.metadata.format = targetFormat
            existing.metadata.fingerprint = conversion.fingerprintSHA256
            existing.metadata.fingerprintMD5 = conversion.fingerprintMD5
            existing.metadata.isPassphraseProtected = conversion.isPassphraseProtected
            existing.metadata.passphraseCipher = conversion.passphraseCipher
            existing.metadata.importedFrom = "Converted on device"

            keys[index] = existing
            try await keyStore.saveKeys(keys)
            return true
        } catch {
            errorMessage = "Failed to convert key: \(error.localizedDescription)"
            return false
        }
    }

    func copyPublicKeyToHost(
        keyID: UUID,
        host: Host,
        hostPassword: String,
        privateKeyPassphrase: String?
    ) async -> Bool {
        guard let storedKey = keys.first(where: { $0.id == keyID }) else {
            errorMessage = "Unable to find selected key."
            return false
        }
        if storedKey.metadata.storageLocation == .secureEnclave {
            errorMessage = "ssh-copy-id verification is not supported for Secure Enclave keys yet."
            return false
        }

        let normalizedHostPassword = hostPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedHostPassword.isEmpty {
            errorMessage = "Host password is required for ssh-copy-id."
            return false
        }

        let normalizedPrivateKeyPassphrase = privateKeyPassphrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if storedKey.metadata.isPassphraseProtected &&
            (normalizedPrivateKeyPassphrase == nil || normalizedPrivateKeyPassphrase?.isEmpty == true) {
            errorMessage = "Key passphrase is required to verify an encrypted private key."
            return false
        }

        isCopyingPublicKey = true
        defer { isCopyingPublicKey = false }

        do {
            try keyForgeService.copyPublicKeyToHost(
                host: host,
                storedKey: storedKey,
                hostPassword: normalizedHostPassword,
                privateKeyPassphrase: normalizedPrivateKeyPassphrase
            )
            return true
        } catch {
            errorMessage = "ssh-copy-id failed: \(error.localizedDescription)"
            return false
        }
    }

    func updatePreferredCopyIDHost(keyID: UUID, hostID: UUID?) async {
        guard let index = keys.firstIndex(where: { $0.id == keyID }) else { return }
        keys[index].metadata.preferredCopyIDHostID = hostID
        do {
            try await keyStore.saveKeys(keys)
        } catch {
            errorMessage = "Failed to save host preference: \(error.localizedDescription)"
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private static func sortKeys(lhs: StoredSSHKey, rhs: StoredSSHKey) -> Bool {
        lhs.metadata.createdAt > rhs.metadata.createdAt
    }
}
