import Foundation
import CryptoKit
import Security

struct SecureEnclaveGeneratedKey {
    var tag: String
    var publicKeyAuthorizedFormat: String
    var fingerprintSHA256: String
    var fingerprintMD5: String
}

enum SecureEnclaveKeyManagerError: LocalizedError {
    case unavailableOnSimulator
    case accessControlCreationFailed
    case keyGenerationFailed(message: String)
    case publicKeyDerivationFailed
    case publicKeyExportFailed(message: String)
    case invalidPublicKeyEncoding
    case privateKeyNotFound
    case signatureFailed(message: String)
    case invalidECDSASignatureEncoding

    var errorDescription: String? {
        switch self {
        case .unavailableOnSimulator:
            return "Secure Enclave is unavailable in this environment. Requires Apple Silicon."
        case .accessControlCreationFailed:
            return "Failed to configure Secure Enclave access control."
        case let .keyGenerationFailed(message):
            return message
        case .publicKeyDerivationFailed:
            return "Failed to derive Secure Enclave public key."
        case let .publicKeyExportFailed(message):
            return message
        case .invalidPublicKeyEncoding:
            return "Secure Enclave returned an unsupported P-256 public key encoding."
        case .privateKeyNotFound:
            return "Secure Enclave private key could not be found."
        case let .signatureFailed(message):
            return message
        case .invalidECDSASignatureEncoding:
            return "Secure Enclave signature encoding was invalid."
        }
    }
}

nonisolated final class SecureEnclaveKeyManager {
    func generateP256Key(tag: String, comment: String) throws -> SecureEnclaveGeneratedKey {
#if targetEnvironment(simulator)
        throw SecureEnclaveKeyManagerError.unavailableOnSimulator
#else
        let tagData = Data(tag.utf8)

        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            nil
        ) else {
            throw SecureEnclaveKeyManagerError.accessControlCreationFailed
        }

        let privateKeyAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrAccessControl as String: accessControl
        ]

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateKeyAttributes
        ]

        var generationError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &generationError) else {
            throw SecureEnclaveKeyManagerError.keyGenerationFailed(
                message: cfErrorMessage(generationError) ?? "Secure Enclave key generation failed."
            )
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveKeyManagerError.publicKeyDerivationFailed
        }

        var exportError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            throw SecureEnclaveKeyManagerError.publicKeyExportFailed(
                message: cfErrorMessage(exportError) ?? "Failed to export Secure Enclave public key."
            )
        }

        guard publicKeyData.count == 65, publicKeyData.first == 0x04 else {
            throw SecureEnclaveKeyManagerError.invalidPublicKeyEncoding
        }

        let keyType = "ecdsa-sha2-nistp256"
        let curveName = "nistp256"
        let blob = sshString(Data(keyType.utf8))
            + sshString(Data(curveName.utf8))
            + sshString(publicKeyData)

        let publicKeyBase64 = blob.base64EncodedString()
        let publicKeyAuthorizedFormat: String = {
            if comment.isEmpty {
                return "\(keyType) \(publicKeyBase64)"
            }
            return "\(keyType) \(publicKeyBase64) \(comment)"
        }()

        let sha256Digest = SHA256.hash(data: blob)
        let sha256Fingerprint = "SHA256:\(Data(sha256Digest).base64EncodedString().replacingOccurrences(of: "=", with: ""))"

        let md5Digest = Insecure.MD5.hash(data: blob)
        let md5Fingerprint = "MD5:" + md5Digest.map { String(format: "%02x", $0) }.joined(separator: ":")

        return SecureEnclaveGeneratedKey(
            tag: tag,
            publicKeyAuthorizedFormat: publicKeyAuthorizedFormat,
            fingerprintSHA256: sha256Fingerprint,
            fingerprintMD5: md5Fingerprint
        )
#endif
    }

    func deleteP256Key(tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        SecItemDelete(query as CFDictionary)
    }

    func signSSHCertificatePayload(payload: Data, tag: String) throws -> Data {
#if targetEnvironment(simulator)
        throw SecureEnclaveKeyManagerError.unavailableOnSimulator
#else
        let privateKey = try findPrivateKey(tag: tag)

        var signingError: Unmanaged<CFError>?
        guard let derSignature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            payload as CFData,
            &signingError
        ) as Data? else {
            throw SecureEnclaveKeyManagerError.signatureFailed(
                message: cfErrorMessage(signingError) ?? "Secure Enclave signing failed."
            )
        }

        let (r, s) = try decodeECDSASignatureDER(derSignature)
        let inner = sshMPInt(r) + sshMPInt(s)

        var sshSignature = Data()
        sshSignature.append(sshString(Data("ecdsa-sha2-nistp256".utf8)))
        sshSignature.append(sshString(inner))
        return sshSignature
#endif
    }

    private func sshString(_ data: Data) -> Data {
        var buffer = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            buffer.append(contentsOf: bytes)
        }
        buffer.append(data)
        return buffer
    }

    private func sshMPInt(_ unsignedInteger: Data) -> Data {
        let normalized = unsignedInteger.drop { $0 == 0 }
        if normalized.isEmpty {
            return sshString(Data())
        }

        var value = Data(normalized)
        if let first = value.first, (first & 0x80) != 0 {
            value.insert(0, at: 0)
        }
        return sshString(value)
    }

    private func findPrivateKey(tag: String) throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let key = item as? SecKey else {
            throw SecureEnclaveKeyManagerError.privateKeyNotFound
        }
        return key
    }

    private func decodeECDSASignatureDER(_ der: Data) throws -> (Data, Data) {
        var cursor = der.startIndex

        func readByte() throws -> UInt8 {
            guard cursor < der.endIndex else {
                throw SecureEnclaveKeyManagerError.invalidECDSASignatureEncoding
            }
            let value = der[cursor]
            cursor = der.index(after: cursor)
            return value
        }

        func readLength() throws -> Int {
            let first = try readByte()
            if (first & 0x80) == 0 {
                return Int(first)
            }

            let byteCount = Int(first & 0x7f)
            if byteCount == 0 || byteCount > 4 {
                throw SecureEnclaveKeyManagerError.invalidECDSASignatureEncoding
            }

            var length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(try readByte())
            }
            return length
        }

        guard try readByte() == 0x30 else {
            throw SecureEnclaveKeyManagerError.invalidECDSASignatureEncoding
        }

        let sequenceLength = try readLength()
        guard let sequenceEnd = der.index(cursor, offsetBy: sequenceLength, limitedBy: der.endIndex) else {
            throw SecureEnclaveKeyManagerError.invalidECDSASignatureEncoding
        }

        guard try readByte() == 0x02 else {
            throw SecureEnclaveKeyManagerError.invalidECDSASignatureEncoding
        }
        let rLength = try readLength()
        guard let rEnd = der.index(cursor, offsetBy: rLength, limitedBy: sequenceEnd) else {
            throw SecureEnclaveKeyManagerError.invalidECDSASignatureEncoding
        }
        let r = Data(der[cursor..<rEnd])
        cursor = rEnd

        guard try readByte() == 0x02 else {
            throw SecureEnclaveKeyManagerError.invalidECDSASignatureEncoding
        }
        let sLength = try readLength()
        guard let sEnd = der.index(cursor, offsetBy: sLength, limitedBy: sequenceEnd) else {
            throw SecureEnclaveKeyManagerError.invalidECDSASignatureEncoding
        }
        let s = Data(der[cursor..<sEnd])
        cursor = sEnd

        guard cursor == sequenceEnd else {
            throw SecureEnclaveKeyManagerError.invalidECDSASignatureEncoding
        }

        return (r, s)
    }

    private func cfErrorMessage(_ error: Unmanaged<CFError>?) -> String? {
        guard let error else { return nil }
        let managed = error.takeRetainedValue()
        return managed.localizedDescription
    }
}
