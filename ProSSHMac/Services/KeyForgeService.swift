import Foundation

enum ECDSACurve: String, CaseIterable, Identifiable {
    case p256
    case p384
    case p521

    var id: String { rawValue }

    var title: String {
        switch self {
        case .p256: return "P-256"
        case .p384: return "P-384"
        case .p521: return "P-521"
        }
    }

    var bitLength: Int {
        switch self {
        case .p256: return 256
        case .p384: return 384
        case .p521: return 521
        }
    }
}

struct KeyGenerationRequest {
    var label: String
    var keyType: KeyType
    var rsaBits: Int
    var ecdsaCurve: ECDSACurve
    var storeInSecureEnclave: Bool
    var format: KeyFormat
    var passphrase: String?
    var passphraseCipher: PrivateKeyCipher
    var comment: String
}

struct KeyImportRequest {
    var label: String?
    var keyText: String
    var passphrase: String?
    var source: String
}

struct KeyConversionRequest {
    var privateKeyText: String
    var targetFormat: KeyFormat
    var inputPassphrase: String?
    var outputPassphrase: String?
    var outputPassphraseCipher: PrivateKeyCipher
    var comment: String
}

struct KeyConversionResult {
    var privateKey: String
    var publicKey: String
    var fingerprintSHA256: String
    var fingerprintMD5: String
    var isPassphraseProtected: Bool
    var passphraseCipher: PrivateKeyCipher?
}

enum KeyForgeError: LocalizedError {
    case generationFailed(message: String)
    case importFailed(message: String)
    case conversionFailed(message: String)
    case copyIDFailed(message: String)

    var errorDescription: String? {
        switch self {
        case let .generationFailed(message):
            return message
        case let .importFailed(message):
            return message
        case let .conversionFailed(message):
            return message
        case let .copyIDFailed(message):
            return message
        }
    }
}

@MainActor
final class KeyForgeService {
    private let secureEnclaveKeyManager: SecureEnclaveKeyManager

    init(secureEnclaveKeyManager: SecureEnclaveKeyManager = SecureEnclaveKeyManager()) {
        self.secureEnclaveKeyManager = secureEnclaveKeyManager
    }

    func generateKey(request: KeyGenerationRequest) throws -> StoredSSHKey {
        if request.storeInSecureEnclave {
            return try generateSecureEnclaveP256Key(request: request)
        }

        let mapping = mapRequest(request)

        var privateKeyBuffer = [CChar](repeating: 0, count: 64 * 1024)
        var publicKeyBuffer = [CChar](repeating: 0, count: 8 * 1024)
        var sha256Buffer = [CChar](repeating: 0, count: 256)
        var md5Buffer = [CChar](repeating: 0, count: 256)
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let result = request.comment.withCString { commentPtr in
            if let passphrase = request.normalizedPassphrase {
                return passphrase.withCString { passphrasePtr in
                    prossh_libssh_generate_keypair(
                        mapping.algorithm,
                        mapping.parameter,
                        mapping.format,
                        passphrasePtr,
                        mapping.privateKeyCipher,
                        commentPtr,
                        &privateKeyBuffer,
                        privateKeyBuffer.count,
                        &publicKeyBuffer,
                        publicKeyBuffer.count,
                        &sha256Buffer,
                        sha256Buffer.count,
                        &md5Buffer,
                        md5Buffer.count,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
            }

            return prossh_libssh_generate_keypair(
                mapping.algorithm,
                mapping.parameter,
                mapping.format,
                nil,
                PROSSH_PRIVATE_KEY_CIPHER_NONE,
                commentPtr,
                &privateKeyBuffer,
                privateKeyBuffer.count,
                &publicKeyBuffer,
                publicKeyBuffer.count,
                &sha256Buffer,
                sha256Buffer.count,
                &md5Buffer,
                md5Buffer.count,
                &errorBuffer,
                errorBuffer.count
            )
        }

        if result != 0 {
            let message = errorBuffer.asString
            throw KeyForgeError.generationFailed(
                message: message.isEmpty ? "Key generation failed." : message
            )
        }

        let keyID = UUID()
        let generatedAt = Date.now
        let publicKey = publicKeyBuffer.asString
        let privateKey = privateKeyBuffer.asString
        let sha256 = sha256Buffer.asString
        let md5 = md5Buffer.asString

        let metadata = SSHKey(
            id: keyID,
            label: request.label,
            type: request.keyType,
            bitLength: mapping.bitLength,
            fingerprint: sha256,
            fingerprintMD5: md5,
            publicKeyAuthorizedFormat: publicKey,
            storageLocation: .encryptedStorage,
            format: request.format,
            isPassphraseProtected: request.normalizedPassphrase != nil,
            passphraseCipher: request.normalizedPassphrase != nil ? request.passphraseCipher : nil,
            comment: request.comment.isEmpty ? nil : request.comment,
            associatedCertificates: [],
            createdAt: generatedAt,
            importedFrom: "Generated on device"
        )

        return StoredSSHKey(
            metadata: metadata,
            privateKey: privateKey,
            publicKey: publicKey,
            secureEnclaveTag: nil
        )
    }

    func importKey(request: KeyImportRequest) throws -> StoredSSHKey {
        let normalizedKeyText = request.keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKeyText.isEmpty else {
            throw KeyForgeError.importFailed(message: "No key text was provided for import.")
        }

        var privateKeyBuffer = [CChar](repeating: 0, count: 64 * 1024)
        var publicKeyBuffer = [CChar](repeating: 0, count: 8 * 1024)
        var keyTypeBuffer = [CChar](repeating: 0, count: 64)
        var sha256Buffer = [CChar](repeating: 0, count: 256)
        var md5Buffer = [CChar](repeating: 0, count: 256)
        var errorBuffer = [CChar](repeating: 0, count: 512)

        var bitLength: Int32 = -1
        var isPrivateKey: Int32 = 0
        var isPassphraseProtected: Int32 = 0
        var detectedFormat: Int32 = Int32(PROSSH_PRIVATE_KEY_OPENSSH.rawValue)
        var detectedCipher: Int32 = Int32(PROSSH_PRIVATE_KEY_CIPHER_NONE.rawValue)

        let normalizedLabel = request.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassphrase = request.passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = normalizedKeyText.withCString { keyTextPtr in
            let commentCString = (normalizedLabel?.isEmpty == false ? normalizedLabel! : "").withCString { commentPtr in
                if let passphrase = normalizedPassphrase, !passphrase.isEmpty {
                    return passphrase.withCString { passphrasePtr in
                        prossh_libssh_import_key(
                            keyTextPtr,
                            passphrasePtr,
                            commentPtr,
                            &privateKeyBuffer,
                            privateKeyBuffer.count,
                            &publicKeyBuffer,
                            publicKeyBuffer.count,
                            &keyTypeBuffer,
                            keyTypeBuffer.count,
                            &bitLength,
                            &isPrivateKey,
                            &isPassphraseProtected,
                            &detectedFormat,
                            &detectedCipher,
                            &sha256Buffer,
                            sha256Buffer.count,
                            &md5Buffer,
                            md5Buffer.count,
                            &errorBuffer,
                            errorBuffer.count
                        )
                    }
                }

                return prossh_libssh_import_key(
                    keyTextPtr,
                    nil,
                    commentPtr,
                    &privateKeyBuffer,
                    privateKeyBuffer.count,
                    &publicKeyBuffer,
                    publicKeyBuffer.count,
                    &keyTypeBuffer,
                    keyTypeBuffer.count,
                    &bitLength,
                    &isPrivateKey,
                    &isPassphraseProtected,
                    &detectedFormat,
                    &detectedCipher,
                    &sha256Buffer,
                    sha256Buffer.count,
                    &md5Buffer,
                    md5Buffer.count,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
            return commentCString
        }

        if result != 0 {
            let message = errorBuffer.asString
            throw KeyForgeError.importFailed(
                message: message.isEmpty ? "Key import failed." : message
            )
        }

        let importedKeyType = try mapImportedKeyType(rawValue: keyTypeBuffer.asString)
        let importedFormat = mapImportedFormat(rawValue: detectedFormat)
        let importedCipher = mapImportedCipher(rawValue: detectedCipher)
        let resolvedBitLength: Int? = bitLength > 0 ? Int(bitLength) : nil

        let displayLabel: String = {
            if let normalizedLabel, !normalizedLabel.isEmpty {
                return normalizedLabel
            }
            switch importedKeyType {
            case .rsa:
                return resolvedBitLength != nil ? "Imported RSA-\(resolvedBitLength!) Key" : "Imported RSA Key"
            case .ed25519:
                return "Imported Ed25519 Key"
            case .ecdsa:
                return resolvedBitLength != nil ? "Imported ECDSA P-\(resolvedBitLength!) Key" : "Imported ECDSA Key"
            case .dsa:
                return resolvedBitLength != nil ? "Imported DSA-\(resolvedBitLength!) Key" : "Imported DSA Key"
            }
        }()

        let publicKey = publicKeyBuffer.asString
        let privateKey = privateKeyBuffer.asString
        let sha256 = sha256Buffer.asString
        let md5 = md5Buffer.asString
        let keyID = UUID()
        let importedAt = Date.now

        let metadata = SSHKey(
            id: keyID,
            label: displayLabel,
            type: importedKeyType,
            bitLength: resolvedBitLength,
            fingerprint: sha256,
            fingerprintMD5: md5,
            publicKeyAuthorizedFormat: publicKey,
            storageLocation: .encryptedStorage,
            format: importedFormat,
            isPassphraseProtected: isPassphraseProtected != 0,
            passphraseCipher: isPassphraseProtected != 0 ? importedCipher : nil,
            comment: nil,
            associatedCertificates: [],
            createdAt: importedAt,
            importedFrom: request.source
        )

        return StoredSSHKey(
            metadata: metadata,
            privateKey: isPrivateKey != 0 ? privateKey : "",
            publicKey: publicKey,
            secureEnclaveTag: nil
        )
    }

    func convertPrivateKey(request: KeyConversionRequest) throws -> KeyConversionResult {
        let normalizedPrivateKey = request.privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrivateKey.isEmpty else {
            throw KeyForgeError.conversionFailed(message: "No private key material is available for conversion.")
        }

        let normalizedInputPassphrase = request.inputPassphrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOutputPassphrase = request.outputPassphrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedComment = request.comment.trimmingCharacters(in: .whitespacesAndNewlines)

        var privateKeyBuffer = [CChar](repeating: 0, count: 64 * 1024)
        var publicKeyBuffer = [CChar](repeating: 0, count: 8 * 1024)
        var sha256Buffer = [CChar](repeating: 0, count: 256)
        var md5Buffer = [CChar](repeating: 0, count: 256)
        var errorBuffer = [CChar](repeating: 0, count: 512)

        var outputIsPassphraseProtected: Int32 = 0
        var outputCipherRaw: Int32 = Int32(PROSSH_PRIVATE_KEY_CIPHER_NONE.rawValue)

        let outputFormat = mapPrivateKeyFormat(request.targetFormat)
        let outputCipher = mapPrivateKeyCipher(request.outputPassphraseCipher)

        let result = normalizedPrivateKey.withCString { privateKeyPtr in
            normalizedComment.withCString { commentPtr in
                if let inputPassphrase = normalizedInputPassphrase, !inputPassphrase.isEmpty {
                    return inputPassphrase.withCString { inputPassphrasePtr in
                        if let outputPassphrase = normalizedOutputPassphrase, !outputPassphrase.isEmpty {
                            return outputPassphrase.withCString { outputPassphrasePtr in
                                prossh_libssh_convert_private_key(
                                    privateKeyPtr,
                                    inputPassphrasePtr,
                                    outputFormat,
                                    outputPassphrasePtr,
                                    outputCipher,
                                    commentPtr,
                                    &privateKeyBuffer,
                                    privateKeyBuffer.count,
                                    &publicKeyBuffer,
                                    publicKeyBuffer.count,
                                    &sha256Buffer,
                                    sha256Buffer.count,
                                    &md5Buffer,
                                    md5Buffer.count,
                                    &outputIsPassphraseProtected,
                                    &outputCipherRaw,
                                    &errorBuffer,
                                    errorBuffer.count
                                )
                            }
                        }

                        return prossh_libssh_convert_private_key(
                            privateKeyPtr,
                            inputPassphrasePtr,
                            outputFormat,
                            nil,
                            outputCipher,
                            commentPtr,
                            &privateKeyBuffer,
                            privateKeyBuffer.count,
                            &publicKeyBuffer,
                            publicKeyBuffer.count,
                            &sha256Buffer,
                            sha256Buffer.count,
                            &md5Buffer,
                            md5Buffer.count,
                            &outputIsPassphraseProtected,
                            &outputCipherRaw,
                            &errorBuffer,
                            errorBuffer.count
                        )
                    }
                }

                if let outputPassphrase = normalizedOutputPassphrase, !outputPassphrase.isEmpty {
                    return outputPassphrase.withCString { outputPassphrasePtr in
                        prossh_libssh_convert_private_key(
                            privateKeyPtr,
                            nil,
                            outputFormat,
                            outputPassphrasePtr,
                            outputCipher,
                            commentPtr,
                            &privateKeyBuffer,
                            privateKeyBuffer.count,
                            &publicKeyBuffer,
                            publicKeyBuffer.count,
                            &sha256Buffer,
                            sha256Buffer.count,
                            &md5Buffer,
                            md5Buffer.count,
                            &outputIsPassphraseProtected,
                            &outputCipherRaw,
                            &errorBuffer,
                            errorBuffer.count
                        )
                    }
                }

                return prossh_libssh_convert_private_key(
                    privateKeyPtr,
                    nil,
                    outputFormat,
                    nil,
                    outputCipher,
                    commentPtr,
                    &privateKeyBuffer,
                    privateKeyBuffer.count,
                    &publicKeyBuffer,
                    publicKeyBuffer.count,
                    &sha256Buffer,
                    sha256Buffer.count,
                    &md5Buffer,
                    md5Buffer.count,
                    &outputIsPassphraseProtected,
                    &outputCipherRaw,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }

        if result != 0 {
            let message = errorBuffer.asString
            throw KeyForgeError.conversionFailed(
                message: message.isEmpty ? "Key format conversion failed." : message
            )
        }

        let resolvedCipher = outputIsPassphraseProtected != 0
            ? mapImportedCipher(rawValue: outputCipherRaw)
            : nil

        return KeyConversionResult(
            privateKey: privateKeyBuffer.asString,
            publicKey: publicKeyBuffer.asString,
            fingerprintSHA256: sha256Buffer.asString,
            fingerprintMD5: md5Buffer.asString,
            isPassphraseProtected: outputIsPassphraseProtected != 0,
            passphraseCipher: resolvedCipher
        )
    }

    func copyPublicKeyToHost(
        host: Host,
        storedKey: StoredSSHKey,
        hostPassword: String,
        privateKeyPassphrase: String?
    ) throws {
        let normalizedPublicKey = storedKey.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPublicKey.isEmpty else {
            throw KeyForgeError.copyIDFailed(message: "No public key is available for ssh-copy-id.")
        }

        let normalizedPrivateKey = storedKey.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrivateKey.isEmpty else {
            throw KeyForgeError.copyIDFailed(
                message: "A private key is required to verify key-based authentication after installation."
            )
        }

        let normalizedHostPassword = hostPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHostPassword.isEmpty else {
            throw KeyForgeError.copyIDFailed(message: "Host password is required for ssh-copy-id.")
        }

        let normalizedPrivateKeyPassphrase = privateKeyPassphrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let policies: [SSHAlgorithmPolicy] = host.legacyModeEnabled
            ? [.modern, .legacy]
            : [.modern]

        var lastErrorMessage = "ssh-copy-id failed."

        for policy in policies {
            let keyExchange = policy.keyExchange.joined(separator: ",")
            let ciphers = policy.ciphers.joined(separator: ",")
            let selectedHostKeys = host.pinnedHostKeyAlgorithms.isEmpty ? policy.hostKeys : host.pinnedHostKeyAlgorithms
            let hostKeys = selectedHostKeys.joined(separator: ",")
            let macs = policy.macs.joined(separator: ",")

            var errorBuffer = [CChar](repeating: 0, count: 512)

            let result = host.hostname.withCString { hostnamePtr in
                host.username.withCString { usernamePtr in
                    normalizedHostPassword.withCString { passwordPtr in
                        normalizedPublicKey.withCString { publicKeyPtr in
                            normalizedPrivateKey.withCString { privateKeyPtr in
                                keyExchange.withCString { kexPtr in
                                    ciphers.withCString { ciphersPtr in
                                        hostKeys.withCString { hostKeysPtr in
                                            macs.withCString { macsPtr in
                                                if let normalizedPrivateKeyPassphrase,
                                                   !normalizedPrivateKeyPassphrase.isEmpty {
                                                    return normalizedPrivateKeyPassphrase.withCString { privateKeyPassphrasePtr in
                                                        prossh_libssh_copy_public_key_to_host(
                                                            hostnamePtr,
                                                            host.port,
                                                            usernamePtr,
                                                            passwordPtr,
                                                            publicKeyPtr,
                                                            privateKeyPtr,
                                                            privateKeyPassphrasePtr,
                                                            kexPtr,
                                                            ciphersPtr,
                                                            hostKeysPtr,
                                                            macsPtr,
                                                            10,
                                                            &errorBuffer,
                                                            errorBuffer.count
                                                        )
                                                    }
                                                }

                                                return prossh_libssh_copy_public_key_to_host(
                                                    hostnamePtr,
                                                    host.port,
                                                    usernamePtr,
                                                    passwordPtr,
                                                    publicKeyPtr,
                                                    privateKeyPtr,
                                                    nil,
                                                    kexPtr,
                                                    ciphersPtr,
                                                    hostKeysPtr,
                                                    macsPtr,
                                                    10,
                                                    &errorBuffer,
                                                    errorBuffer.count
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if result == 0 {
                return
            }

            let message = errorBuffer.asString
            if !message.isEmpty {
                lastErrorMessage = message
            }
        }

        throw KeyForgeError.copyIDFailed(message: lastErrorMessage)
    }

    func deleteStoredKeyMaterial(_ key: StoredSSHKey) {
        guard key.metadata.storageLocation == .secureEnclave,
              let secureEnclaveTag = key.secureEnclaveTag,
              !secureEnclaveTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        secureEnclaveKeyManager.deleteP256Key(tag: secureEnclaveTag)
    }

    private func mapRequest(_ request: KeyGenerationRequest) -> (
        algorithm: ProSSHKeyAlgorithm,
        parameter: Int32,
        format: ProSSHPrivateKeyFormat,
        privateKeyCipher: ProSSHPrivateKeyCipher,
        bitLength: Int
    ) {
        let format = mapPrivateKeyFormat(request.format)
        let cipher = mapPrivateKeyCipher(request.passphraseCipher)

        switch request.keyType {
        case .rsa:
            return (
                algorithm: PROSSH_KEY_RSA,
                parameter: Int32(request.rsaBits),
                format: format,
                privateKeyCipher: cipher,
                bitLength: request.rsaBits
            )
        case .ed25519:
            return (
                algorithm: PROSSH_KEY_ED25519,
                parameter: 0,
                format: format,
                privateKeyCipher: cipher,
                bitLength: 256
            )
        case .ecdsa:
            switch request.ecdsaCurve {
            case .p256:
                return (
                    algorithm: PROSSH_KEY_ECDSA_P256,
                    parameter: 0,
                    format: format,
                    privateKeyCipher: cipher,
                    bitLength: request.ecdsaCurve.bitLength
                )
            case .p384:
                return (
                    algorithm: PROSSH_KEY_ECDSA_P384,
                    parameter: 0,
                    format: format,
                    privateKeyCipher: cipher,
                    bitLength: request.ecdsaCurve.bitLength
                )
            case .p521:
                return (
                    algorithm: PROSSH_KEY_ECDSA_P521,
                    parameter: 0,
                    format: format,
                    privateKeyCipher: cipher,
                    bitLength: request.ecdsaCurve.bitLength
                )
            }
        case .dsa:
            return (
                algorithm: PROSSH_KEY_DSA,
                parameter: 1024,
                format: format,
                privateKeyCipher: cipher,
                bitLength: 1024
            )
        }
    }

    private func mapImportedKeyType(rawValue: String) throws -> KeyType {
        switch rawValue.lowercased() {
        case "rsa":
            return .rsa
        case "ed25519":
            return .ed25519
        case "ecdsa":
            return .ecdsa
        case "dsa":
            return .dsa
        default:
            throw KeyForgeError.importFailed(message: "Unsupported key type encountered during import.")
        }
    }

    private func mapImportedFormat(rawValue: Int32) -> KeyFormat {
        switch rawValue {
        case Int32(PROSSH_PRIVATE_KEY_PEM.rawValue):
            return .pem
        case Int32(PROSSH_PRIVATE_KEY_PKCS8.rawValue):
            return .pkcs8
        case Int32(PROSSH_PRIVATE_KEY_OPENSSH.rawValue):
            return .openssh
        default:
            return .openssh
        }
    }

    private func mapImportedCipher(rawValue: Int32) -> PrivateKeyCipher? {
        switch rawValue {
        case Int32(PROSSH_PRIVATE_KEY_CIPHER_AES256CTR.rawValue):
            return .aes256ctr
        case Int32(PROSSH_PRIVATE_KEY_CIPHER_CHACHA20_POLY1305.rawValue):
            return .chacha20Poly1305
        default:
            return nil
        }
    }

    private func mapPrivateKeyFormat(_ format: KeyFormat) -> ProSSHPrivateKeyFormat {
        switch format {
        case .openssh:
            return PROSSH_PRIVATE_KEY_OPENSSH
        case .pem:
            return PROSSH_PRIVATE_KEY_PEM
        case .pkcs8:
            return PROSSH_PRIVATE_KEY_PKCS8
        }
    }

    private func mapPrivateKeyCipher(_ cipher: PrivateKeyCipher) -> ProSSHPrivateKeyCipher {
        switch cipher {
        case .aes256ctr:
            return PROSSH_PRIVATE_KEY_CIPHER_AES256CTR
        case .chacha20Poly1305:
            return PROSSH_PRIVATE_KEY_CIPHER_CHACHA20_POLY1305
        }
    }

    private func generateSecureEnclaveP256Key(request: KeyGenerationRequest) throws -> StoredSSHKey {
        guard request.keyType == .ecdsa, request.ecdsaCurve == .p256 else {
            throw KeyForgeError.generationFailed(
                message: "Secure Enclave storage currently supports ECDSA P-256 keys only."
            )
        }

        if request.normalizedPassphrase != nil {
            throw KeyForgeError.generationFailed(
                message: "Passphrase encryption is unavailable for non-exportable Secure Enclave keys."
            )
        }

        let keyID = UUID()
        let tag = "nl.budgetsoft.prosshv2.secureenclave.\(keyID.uuidString.lowercased())"
        let comment = request.comment.trimmingCharacters(in: .whitespacesAndNewlines)

        let generated: SecureEnclaveGeneratedKey
        do {
            generated = try secureEnclaveKeyManager.generateP256Key(tag: tag, comment: comment)
        } catch {
            throw KeyForgeError.generationFailed(message: error.localizedDescription)
        }

        let metadata = SSHKey(
            id: keyID,
            label: request.label,
            type: .ecdsa,
            bitLength: 256,
            fingerprint: generated.fingerprintSHA256,
            fingerprintMD5: generated.fingerprintMD5,
            publicKeyAuthorizedFormat: generated.publicKeyAuthorizedFormat,
            storageLocation: .secureEnclave,
            format: .openssh,
            isPassphraseProtected: false,
            passphraseCipher: nil,
            comment: comment.isEmpty ? nil : comment,
            associatedCertificates: [],
            createdAt: .now,
            importedFrom: "Generated in Secure Enclave"
        )

        return StoredSSHKey(
            metadata: metadata,
            privateKey: "",
            publicKey: generated.publicKeyAuthorizedFormat,
            secureEnclaveTag: generated.tag
        )
    }
}

private extension KeyGenerationRequest {
    var normalizedPassphrase: String? {
        guard let passphrase else { return nil }
        return passphrase.isEmpty ? nil : passphrase
    }
}

private extension Array where Element == CChar {
    nonisolated var asString: String {
        String(decoding: prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
