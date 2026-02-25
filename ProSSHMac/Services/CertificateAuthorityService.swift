// swiftlint:disable file_length
import Foundation
import CryptoKit
import Security

struct CertificateAuthorityGenerationRequest {
    var label: String
    var certificateType: CertificateType
    var defaultValidityDuration: TimeInterval
    var notes: String?
}

struct UserCertificateSigningRequest {
    var authorityID: UUID
    var subjectPublicKeyAuthorized: String
    var associatedKeyID: UUID?
    var keyID: String
    var serialNumber: UInt64
    var principals: [String]
    var validAfter: Date
    var validBefore: Date
    var criticalOptions: [String: String]
    var extensions: [String: String]
}

struct HostCertificateSigningRequest {
    var authorityID: UUID
    var subjectPublicKeyAuthorized: String
    var associatedKeyID: UUID?
    var keyID: String
    var serialNumber: UInt64
    var principals: [String]
    var validAfter: Date
    var validBefore: Date
    var criticalOptions: [String: String]
    var extensions: [String: String]
}

struct KRLGenerationRequest {
    var authorityID: UUID?
    var revokedSerials: [UInt64]
    var includeExpiredCertificates: Bool
}

struct GeneratedKRLBundle {
    var generatedAt: Date
    var fileStem: String
    var authorityLabel: String?
    var revokedCertificateCount: Int
    var revokedKeysContent: String
    var manifestContent: String
    var openSSHCommand: String
}

enum CertificateAuthorityError: LocalizedError {
    case generationFailed(message: String)
    case signingFailed(message: String)
    case persistenceFailed(message: String)

    var errorDescription: String? {
        switch self {
        case let .generationFailed(message):
            return message
        case let .signingFailed(message):
            return message
        case let .persistenceFailed(message):
            return message
        }
    }
}

@MainActor
final class CertificateAuthorityService {
    private let authorityStore: any CertificateAuthorityStoreProtocol
    private let certificateStore: any CertificateStoreProtocol
    private let secureEnclaveKeyManager: SecureEnclaveKeyManager

    init(
        authorityStore: any CertificateAuthorityStoreProtocol,
        certificateStore: any CertificateStoreProtocol,
        secureEnclaveKeyManager: SecureEnclaveKeyManager
    ) {
        self.authorityStore = authorityStore
        self.certificateStore = certificateStore
        self.secureEnclaveKeyManager = secureEnclaveKeyManager
    }

    func loadAuthorities() async throws -> [CertificateAuthorityModel] {
        do {
            return try await authorityStore.loadAuthorities()
        } catch {
            throw CertificateAuthorityError.persistenceFailed(
                message: "Failed to load certificate authorities: \(error.localizedDescription)"
            )
        }
    }

    func createAuthority(
        request: CertificateAuthorityGenerationRequest,
        existingAuthorities: [CertificateAuthorityModel]
    ) async throws -> [CertificateAuthorityModel] {
        let id = UUID()
        let normalizedLabel = request.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let secureEnclaveTag = "nl.budgetsoft.prosshv2.ca.\(id.uuidString.lowercased())"
        let keyComment = "\(normalizedLabel) CA"

        let generated: SecureEnclaveGeneratedKey
        do {
            generated = try secureEnclaveKeyManager.generateP256Key(tag: secureEnclaveTag, comment: keyComment)
        } catch {
            throw CertificateAuthorityError.generationFailed(
                message: "Failed to generate CA keypair in Secure Enclave: \(error.localizedDescription)"
            )
        }

        let authority = CertificateAuthorityModel(
            id: id,
            label: normalizedLabel,
            keyType: .ecdsa,
            publicKeyFingerprint: generated.fingerprintSHA256,
            publicKeyAuthorizedFormat: generated.publicKeyAuthorizedFormat,
            secureEnclaveReference: generated.tag,
            certificateType: request.certificateType,
            defaultValidityDuration: request.defaultValidityDuration,
            nextSerialNumber: 1,
            issuedCertificateCount: 0,
            createdAt: .now,
            notes: request.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
                ? nil
                : request.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        var updated = existingAuthorities
        updated.insert(authority, at: 0)
        updated.sort { $0.createdAt > $1.createdAt }

        do {
            try await authorityStore.saveAuthorities(updated)
        } catch {
            secureEnclaveKeyManager.deleteP256Key(tag: generated.tag)
            throw CertificateAuthorityError.persistenceFailed(
                message: "Failed to persist generated CA: \(error.localizedDescription)"
            )
        }

        return updated
    }

    func loadCertificates() async throws -> [SSHCertificate] {
        do {
            return try await certificateStore.loadCertificates()
        } catch {
            throw CertificateAuthorityError.persistenceFailed(
                message: "Failed to load certificates: \(error.localizedDescription)"
            )
        }
    }

    func importExternalCertificate(
        authorizedCertificate: String,
        existingCertificates: [SSHCertificate]
    ) async throws -> [SSHCertificate] {
        let parsed = try parseAuthorizedCertificate(authorizedCertificate)

        let duplicate = existingCertificates.contains { existing in
            existing.rawCertificateData == parsed.rawCertificateData
                || (
                    existing.serialNumber == parsed.serialNumber
                        && existing.keyId == parsed.keyID
                        && existing.signingCAFingerprint == parsed.signingCAFingerprint
                )
        }
        if duplicate {
            throw CertificateAuthorityError.signingFailed(message: "This certificate is already imported.")
        }

        let certificate = SSHCertificate(
            id: UUID(),
            type: parsed.certificateType,
            serialNumber: parsed.serialNumber,
            keyId: parsed.keyID,
            principals: parsed.principals,
            validAfter: parsed.validAfter,
            validBefore: parsed.validBefore,
            criticalOptions: parsed.criticalOptions,
            extensions: parsed.extensions,
            signingCAFingerprint: parsed.signingCAFingerprint,
            signedKeyFingerprint: parsed.signedKeyFingerprint,
            signatureAlgorithm: parsed.signatureAlgorithm,
            associatedKeyId: nil,
            rawCertificateData: parsed.rawCertificateData,
            authorizedRepresentation: parsed.authorizedRepresentation,
            importedFrom: parsed.importSource ?? "Imported from external CA",
            createdAt: .now
        )

        var updated = existingCertificates
        updated.insert(certificate, at: 0)
        updated.sort { $0.createdAt > $1.createdAt }

        do {
            try await certificateStore.saveCertificates(updated)
        } catch {
            throw CertificateAuthorityError.persistenceFailed(
                message: "Failed to persist imported certificate: \(error.localizedDescription)"
            )
        }

        return updated
    }

    func signUserCertificate(
        request: UserCertificateSigningRequest,
        existingAuthorities: [CertificateAuthorityModel],
        existingCertificates: [SSHCertificate]
    ) async throws -> (authorities: [CertificateAuthorityModel], certificates: [SSHCertificate]) {
        try await signCertificate(
            authorityID: request.authorityID,
            subjectPublicKeyAuthorized: request.subjectPublicKeyAuthorized,
            associatedKeyID: request.associatedKeyID,
            keyID: request.keyID,
            serialNumber: request.serialNumber,
            principals: request.principals,
            validAfter: request.validAfter,
            validBefore: request.validBefore,
            criticalOptions: request.criticalOptions,
            extensions: request.extensions,
            existingAuthorities: existingAuthorities,
            existingCertificates: existingCertificates,
            role: .user
        )
    }

    func signHostCertificate(
        request: HostCertificateSigningRequest,
        existingAuthorities: [CertificateAuthorityModel],
        existingCertificates: [SSHCertificate]
    ) async throws -> (authorities: [CertificateAuthorityModel], certificates: [SSHCertificate]) {
        try await signCertificate(
            authorityID: request.authorityID,
            subjectPublicKeyAuthorized: request.subjectPublicKeyAuthorized,
            associatedKeyID: request.associatedKeyID,
            keyID: request.keyID,
            serialNumber: request.serialNumber,
            principals: request.principals,
            validAfter: request.validAfter,
            validBefore: request.validBefore,
            criticalOptions: request.criticalOptions,
            extensions: request.extensions,
            existingAuthorities: existingAuthorities,
            existingCertificates: existingCertificates,
            role: .host
        )
    }

    private func signCertificate(
        authorityID: UUID,
        subjectPublicKeyAuthorized: String,
        associatedKeyID: UUID?,
        keyID: String,
        serialNumber: UInt64,
        principals: [String],
        validAfter: Date,
        validBefore: Date,
        criticalOptions: [String: String],
        extensions: [String: String],
        existingAuthorities: [CertificateAuthorityModel],
        existingCertificates: [SSHCertificate],
        role: CertificateRole
    ) async throws -> (authorities: [CertificateAuthorityModel], certificates: [SSHCertificate]) {
        let normalizedKeyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedKeyID.isEmpty {
            throw CertificateAuthorityError.signingFailed(message: "Certificate key ID is required.")
        }

        guard validBefore > validAfter else {
            throw CertificateAuthorityError.signingFailed(message: "Certificate validity end must be after start.")
        }

        guard let authorityIndex = existingAuthorities.firstIndex(where: { $0.id == authorityID }) else {
            throw CertificateAuthorityError.signingFailed(message: "Selected certificate authority was not found.")
        }

        var updatedAuthorities = existingAuthorities
        var authority = updatedAuthorities[authorityIndex]

        if authority.keyType != .ecdsa {
            throw CertificateAuthorityError.signingFailed(message: "Unsupported CA key type.")
        }
        if authority.certificateType == role.unsupportedAuthorityType {
            throw CertificateAuthorityError.signingFailed(message: role.unsupportedAuthorityMessage)
        }

        let authorityPublic = authority.publicKeyAuthorizedFormat?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if authorityPublic.isEmpty {
            throw CertificateAuthorityError.signingFailed(message: "CA public key is unavailable.")
        }

        let subjectKey = try parseAuthorizedPublicKey(subjectPublicKeyAuthorized)
        let certKeyType = try certificateKeyType(for: subjectKey.keyType)
        let caPublicKey = try parseAuthorizedPublicKey(authorityPublic)

        let nonce = try randomBytes(count: 32)
        let principalsBlob = encodeStringList(principals)
        let criticalOptionsBlob = encodeNameValueMap(criticalOptions)
        let extensionsBlob = encodeNameValueMap(extensions)

        var toBeSigned = Data()
        toBeSigned.append(sshString(from: certKeyType))
        toBeSigned.append(sshString(from: nonce))
        toBeSigned.append(subjectKey.keySpecificData)
        toBeSigned.append(u64(serialNumber))
        toBeSigned.append(u32(role.sshCertificateType))
        toBeSigned.append(sshString(from: normalizedKeyID))
        toBeSigned.append(sshString(from: principalsBlob))
        toBeSigned.append(u64(UInt64(validAfter.timeIntervalSince1970)))
        toBeSigned.append(u64(UInt64(validBefore.timeIntervalSince1970)))
        toBeSigned.append(sshString(from: criticalOptionsBlob))
        toBeSigned.append(sshString(from: extensionsBlob))
        toBeSigned.append(sshString(from: Data())) // reserved
        toBeSigned.append(sshString(from: caPublicKey.rawBlob))

        let signatureBlob: Data
        do {
            signatureBlob = try secureEnclaveKeyManager.signSSHCertificatePayload(
                payload: toBeSigned,
                tag: authority.secureEnclaveReference
            )
        } catch {
            throw CertificateAuthorityError.signingFailed(
                message: "Failed to sign \(role.displayName) certificate: \(error.localizedDescription)"
            )
        }

        var certificateBlob = toBeSigned
        certificateBlob.append(sshString(from: signatureBlob))

        let certificateAuthorized = "\(certKeyType) \(certificateBlob.base64EncodedString()) \(normalizedKeyID)"
        let signatureAlgorithm = (try? readFirstSSHString(from: signatureBlob).text) ?? "ecdsa-sha2-nistp256"

        let certificate = SSHCertificate(
            id: UUID(),
            type: role.modelCertificateType,
            serialNumber: serialNumber,
            keyId: normalizedKeyID,
            principals: principals,
            validAfter: validAfter,
            validBefore: validBefore,
            criticalOptions: criticalOptions,
            extensions: extensions.keys.sorted(),
            signingCAFingerprint: authority.publicKeyFingerprint,
            signedKeyFingerprint: fingerprintSHA256(for: subjectKey.rawBlob),
            signatureAlgorithm: signatureAlgorithm,
            associatedKeyId: associatedKeyID,
            rawCertificateData: certificateBlob,
            authorizedRepresentation: certificateAuthorized,
            importedFrom: "Signed by \(authority.label)",
            createdAt: .now
        )

        var updatedCertificates = existingCertificates
        updatedCertificates.insert(certificate, at: 0)
        updatedCertificates.sort { $0.createdAt > $1.createdAt }

        guard authority.issuedCertificateCount < UInt64.max else {
            throw CertificateAuthorityError.signingFailed(
                message: "Certificate authority has reached the maximum issued certificate count."
            )
        }
        authority.issuedCertificateCount += 1

        guard serialNumber < UInt64.max else {
            throw CertificateAuthorityError.signingFailed(
                message: "Serial number has reached the maximum allowed value."
            )
        }
        authority.nextSerialNumber = max(authority.nextSerialNumber, serialNumber + 1)
        updatedAuthorities[authorityIndex] = authority
        updatedAuthorities.sort { $0.createdAt > $1.createdAt }

        do {
            // Save certificates first: if the authority save fails afterward,
            // we have a saved certificate with a stale serial counter (recoverable)
            // rather than an updated counter with a missing certificate (data loss).
            try await certificateStore.saveCertificates(updatedCertificates)
            try await authorityStore.saveAuthorities(updatedAuthorities)
        } catch {
            throw CertificateAuthorityError.persistenceFailed(
                message: "Failed to persist signed certificate: \(error.localizedDescription)"
            )
        }

        return (updatedAuthorities, updatedCertificates)
    }

    func deleteAuthorities(
        ids: [UUID],
        existingAuthorities: [CertificateAuthorityModel]
    ) async throws -> [CertificateAuthorityModel] {
        let deleting = existingAuthorities.filter { ids.contains($0.id) }
        var updated = existingAuthorities
        updated.removeAll { ids.contains($0.id) }

        do {
            try await authorityStore.saveAuthorities(updated)
        } catch {
            throw CertificateAuthorityError.persistenceFailed(
                message: "Failed to persist CA deletion: \(error.localizedDescription)"
            )
        }

        for authority in deleting {
            let tag = authority.secureEnclaveReference.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty {
                secureEnclaveKeyManager.deleteP256Key(tag: tag)
            }
        }

        return updated
    }

}
