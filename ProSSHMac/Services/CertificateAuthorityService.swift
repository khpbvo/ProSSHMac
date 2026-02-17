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

    func generateKRL(
        request: KRLGenerationRequest,
        authorities: [CertificateAuthorityModel],
        certificates: [SSHCertificate]
    ) throws -> GeneratedKRLBundle {
        let now = Date()
        let iso8601 = ISO8601DateFormatter()

        let selectedAuthority: CertificateAuthorityModel?
        if let authorityID = request.authorityID {
            guard let authority = authorities.first(where: { $0.id == authorityID }) else {
                throw CertificateAuthorityError.signingFailed(message: "Selected certificate authority was not found.")
            }
            selectedAuthority = authority
        } else {
            selectedAuthority = nil
        }

        let filteredCertificates: [SSHCertificate]
        if let selectedAuthority {
            filteredCertificates = certificates.filter {
                $0.signingCAFingerprint == selectedAuthority.publicKeyFingerprint
            }
        } else {
            filteredCertificates = certificates
        }

        var revoked: [SSHCertificate] = []
        let requestedSerials = Set(request.revokedSerials)

        for serial in requestedSerials.sorted() {
            let matches = filteredCertificates.filter { $0.serialNumber == serial }
            if matches.isEmpty {
                throw CertificateAuthorityError.signingFailed(
                    message: "No certificate found for serial \(serial) in the selected scope."
                )
            }
            revoked.append(contentsOf: matches)
        }

        if request.includeExpiredCertificates {
            revoked.append(contentsOf: filteredCertificates.filter { $0.validBefore <= now })
        }

        var revokedByID: [UUID: SSHCertificate] = [:]
        for certificate in revoked {
            revokedByID[certificate.id] = certificate
        }
        let finalRevoked = revokedByID.values.sorted { lhs, rhs in
            if lhs.serialNumber == rhs.serialNumber {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.serialNumber < rhs.serialNumber
        }

        guard !finalRevoked.isEmpty else {
            throw CertificateAuthorityError.signingFailed(
                message: "No certificates matched. Enter compromised serials or include expired certificates."
            )
        }

        let revokedLines = finalRevoked.compactMap { authorizedRepresentation(for: $0) }
        guard !revokedLines.isEmpty else {
            throw CertificateAuthorityError.signingFailed(
                message: "Unable to build revoked certificate lines for KRL generation."
            )
        }

        let timestamp = iso8601.string(from: now)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        let authorityComponent = sanitizeFileComponent(selectedAuthority?.label ?? "all-ca")
        let fileStem = "prossh-krl-\(authorityComponent)-\(timestamp)"
        let keyFileName = "\(fileStem)-revoked_keys.pub"
        let command = "ssh-keygen -k -f \(fileStem).krl \(keyFileName)"

        let revokedKeysContent = revokedLines.joined(separator: "\n") + "\n"

        var manifestLines: [String] = [
            "# ProSSH v2 KRL manifest",
            "# Generated: \(iso8601.string(from: now))",
            "# Scope: \(selectedAuthority?.label ?? "All CAs")",
            "# Revoked certificates: \(finalRevoked.count)",
            "#",
            "# 1) Save revoked keys as: \(keyFileName)",
            "# 2) Run: \(command)",
            "# 3) Distribute \(fileStem).krl to SSH servers/clients",
            "",
            "serial,key_id,type,ca_fingerprint,signed_key_fingerprint,valid_after,valid_before"
        ]

        for certificate in finalRevoked {
            let row = [
                String(certificate.serialNumber),
                csvSafe(certificate.keyId),
                csvSafe(certificate.type.rawValue),
                csvSafe(certificate.signingCAFingerprint),
                csvSafe(certificate.signedKeyFingerprint),
                iso8601.string(from: certificate.validAfter),
                iso8601.string(from: certificate.validBefore)
            ].joined(separator: ",")
            manifestLines.append(row)
        }

        return GeneratedKRLBundle(
            generatedAt: now,
            fileStem: fileStem,
            authorityLabel: selectedAuthority?.label,
            revokedCertificateCount: finalRevoked.count,
            revokedKeysContent: revokedKeysContent,
            manifestContent: manifestLines.joined(separator: "\n") + "\n",
            openSSHCommand: command
        )
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

        authority.issuedCertificateCount += 1
        authority.nextSerialNumber = max(authority.nextSerialNumber, serialNumber + 1)
        updatedAuthorities[authorityIndex] = authority
        updatedAuthorities.sort { $0.createdAt > $1.createdAt }

        do {
            try await authorityStore.saveAuthorities(updatedAuthorities)
            try await certificateStore.saveCertificates(updatedCertificates)
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

    private func parseAuthorizedCertificate(_ authorizedCertificate: String) throws -> ParsedExternalCertificate {
        let normalized = authorizedCertificate.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            throw CertificateAuthorityError.signingFailed(message: "Paste a certificate in OpenSSH authorized format.")
        }

        let tokens = normalized
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
            .map(String.init)

        guard tokens.count >= 2 else {
            throw CertificateAuthorityError.signingFailed(message: "Invalid certificate format.")
        }

        let declaredKeyType = tokens[0]
        guard declaredKeyType.contains("-cert-v01@openssh.com") else {
            throw CertificateAuthorityError.signingFailed(message: "Input is not an OpenSSH certificate.")
        }

        guard let certificateBlob = Data(base64Encoded: tokens[1]) else {
            throw CertificateAuthorityError.signingFailed(message: "Certificate base64 decoding failed.")
        }

        var reader = SSHBinaryReader(data: certificateBlob)
        let certificateKeyType = try reader.readStringText(context: "certificate key type")
        _ = try reader.readStringData(context: "nonce")

        let subjectKeyDataStart = reader.offset
        try skipCertificateSubjectKeyData(certificateKeyType: certificateKeyType, reader: &reader)
        let subjectKeyDataEnd = reader.offset

        let serialNumber = try reader.readUInt64(context: "serial number")
        let certificateTypeRaw = try reader.readUInt32(context: "certificate type")
        guard let certificateRole = CertificateRole(sshCertificateTypeRaw: certificateTypeRaw) else {
            throw CertificateAuthorityError.signingFailed(message: "Unsupported certificate type: \(certificateTypeRaw).")
        }

        let keyID = try reader.readStringText(context: "key ID")
        let principalsPayload = try reader.readStringData(context: "valid principals")
        let principals = try parseStringListPayload(principalsPayload, context: "valid principals")

        let validAfter = Date(timeIntervalSince1970: TimeInterval(try reader.readUInt64(context: "valid after")))
        let validBefore = Date(timeIntervalSince1970: TimeInterval(try reader.readUInt64(context: "valid before")))

        let criticalOptionsPayload = try reader.readStringData(context: "critical options")
        let criticalOptions = try parseNameValueMapPayload(criticalOptionsPayload, context: "critical options")

        let extensionsPayload = try reader.readStringData(context: "extensions")
        let extensionsMap = try parseNameValueMapPayload(extensionsPayload, context: "extensions")
        _ = try reader.readStringData(context: "reserved")

        let signatureKeyBlob = try reader.readStringData(context: "signature key")
        let signatureBlob = try reader.readStringData(context: "signature")
        if !reader.isAtEnd {
            throw CertificateAuthorityError.signingFailed(message: "Malformed certificate data.")
        }

        let signatureAlgorithm = parseSignatureAlgorithm(signatureBlob)
        let baseKeyType = try baseKeyType(fromCertificateKeyType: certificateKeyType)
        let subjectKeySpecificData = Data(certificateBlob[subjectKeyDataStart..<subjectKeyDataEnd])
        let signedKeyBlob = sshString(from: baseKeyType) + subjectKeySpecificData

        let trailingComment = tokens.count > 2 ? tokens.dropFirst(2).joined(separator: " ") : ""
        let normalizedAuthorized: String = {
            if trailingComment.isEmpty {
                return "\(certificateKeyType) \(tokens[1])"
            }
            return "\(certificateKeyType) \(tokens[1]) \(trailingComment)"
        }()

        return ParsedExternalCertificate(
            certificateType: certificateRole.modelCertificateType,
            serialNumber: serialNumber,
            keyID: keyID,
            principals: principals,
            validAfter: validAfter,
            validBefore: validBefore,
            criticalOptions: criticalOptions,
            extensions: extensionsMap.keys.sorted(),
            signingCAFingerprint: fingerprintSHA256(for: signatureKeyBlob),
            signedKeyFingerprint: fingerprintSHA256(for: signedKeyBlob),
            signatureAlgorithm: signatureAlgorithm,
            rawCertificateData: certificateBlob,
            authorizedRepresentation: normalizedAuthorized,
            importSource: trailingComment.isEmpty ? nil : "Imported (\(trailingComment))"
        )
    }

    private func skipCertificateSubjectKeyData(
        certificateKeyType: String,
        reader: inout SSHBinaryReader
    ) throws {
        switch certificateKeyType {
        case "ssh-ed25519-cert-v01@openssh.com":
            _ = try reader.readStringData(context: "ed25519 subject key")
        case "ssh-rsa-cert-v01@openssh.com":
            _ = try reader.readStringData(context: "rsa exponent")
            _ = try reader.readStringData(context: "rsa modulus")
        case "ssh-dss-cert-v01@openssh.com":
            _ = try reader.readStringData(context: "dsa p")
            _ = try reader.readStringData(context: "dsa q")
            _ = try reader.readStringData(context: "dsa g")
            _ = try reader.readStringData(context: "dsa y")
        case "ecdsa-sha2-nistp256-cert-v01@openssh.com",
            "ecdsa-sha2-nistp384-cert-v01@openssh.com",
            "ecdsa-sha2-nistp521-cert-v01@openssh.com":
            _ = try reader.readStringData(context: "ecdsa curve")
            _ = try reader.readStringData(context: "ecdsa point")
        default:
            throw CertificateAuthorityError.signingFailed(
                message: "Unsupported certificate key type: \(certificateKeyType)."
            )
        }
    }

    private func parseStringListPayload(_ payload: Data, context: String) throws -> [String] {
        var values: [String] = []
        var reader = SSHBinaryReader(data: payload)

        while !reader.isAtEnd {
            values.append(try reader.readStringText(context: context))
        }
        return values
    }

    private func parseNameValueMapPayload(_ payload: Data, context: String) throws -> [String: String] {
        var values: [String: String] = [:]
        var reader = SSHBinaryReader(data: payload)

        while !reader.isAtEnd {
            let key = try reader.readStringText(context: context)
            let rawValue = try reader.readStringData(context: context)
            values[key] = displayValue(forOptionData: rawValue)
        }
        return values
    }

    private func displayValue(forOptionData data: Data) -> String {
        if data.isEmpty {
            return ""
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    private func parseSignatureAlgorithm(_ signatureBlob: Data) -> String {
        var reader = SSHBinaryReader(data: signatureBlob)
        guard let algorithm = try? reader.readStringText(context: "signature algorithm"), !algorithm.isEmpty else {
            return "unknown"
        }
        return algorithm
    }

    private func baseKeyType(fromCertificateKeyType certificateKeyType: String) throws -> String {
        switch certificateKeyType {
        case "ssh-ed25519-cert-v01@openssh.com":
            return "ssh-ed25519"
        case "ssh-rsa-cert-v01@openssh.com":
            return "ssh-rsa"
        case "ssh-dss-cert-v01@openssh.com":
            return "ssh-dss"
        case "ecdsa-sha2-nistp256-cert-v01@openssh.com":
            return "ecdsa-sha2-nistp256"
        case "ecdsa-sha2-nistp384-cert-v01@openssh.com":
            return "ecdsa-sha2-nistp384"
        case "ecdsa-sha2-nistp521-cert-v01@openssh.com":
            return "ecdsa-sha2-nistp521"
        default:
            throw CertificateAuthorityError.signingFailed(
                message: "Unsupported certificate key type: \(certificateKeyType)."
            )
        }
    }

    private func parseAuthorizedPublicKey(_ authorized: String) throws -> ParsedPublicKey {
        let tokens = authorized
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
            .map(String.init)

        guard tokens.count >= 2 else {
            throw CertificateAuthorityError.signingFailed(message: "Invalid public key format.")
        }

        guard let blob = Data(base64Encoded: tokens[1]) else {
            throw CertificateAuthorityError.signingFailed(message: "Public key base64 decoding failed.")
        }

        let firstString = try readFirstSSHString(from: blob)
        let keyType = firstString.text ?? tokens[0]
        let keySpecificData = blob.suffix(from: firstString.nextOffset)
        return ParsedPublicKey(
            keyType: keyType,
            rawBlob: blob,
            keySpecificData: Data(keySpecificData)
        )
    }

    private func certificateKeyType(for keyType: String) throws -> String {
        switch keyType {
        case "ssh-ed25519":
            return "ssh-ed25519-cert-v01@openssh.com"
        case "ssh-rsa":
            return "ssh-rsa-cert-v01@openssh.com"
        case "ssh-dss":
            return "ssh-dss-cert-v01@openssh.com"
        case "ecdsa-sha2-nistp256":
            return "ecdsa-sha2-nistp256-cert-v01@openssh.com"
        case "ecdsa-sha2-nistp384":
            return "ecdsa-sha2-nistp384-cert-v01@openssh.com"
        case "ecdsa-sha2-nistp521":
            return "ecdsa-sha2-nistp521-cert-v01@openssh.com"
        default:
            throw CertificateAuthorityError.signingFailed(message: "Unsupported key type for SSH certificates: \(keyType)")
        }
    }

    private func encodeStringList(_ values: [String]) -> Data {
        var result = Data()
        for value in values {
            result.append(sshString(from: value))
        }
        return result
    }

    private func encodeNameValueMap(_ values: [String: String]) -> Data {
        var mapPayload = Data()
        for key in values.keys.sorted() {
            mapPayload.append(sshString(from: key))
            mapPayload.append(sshString(from: values[key] ?? ""))
        }
        return mapPayload
    }

    private func fingerprintSHA256(for keyBlob: Data) -> String {
        let digest = SHA256.hash(data: keyBlob)
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }

    private func randomBytes(count: Int) throws -> Data {
        var buffer = Data(count: count)
        let status = buffer.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CertificateAuthorityError.signingFailed(message: "Failed to generate certificate nonce.")
        }
        return buffer
    }

    private func sshString(from text: String) -> Data {
        sshString(from: Data(text.utf8))
    }

    private func sshString(from data: Data) -> Data {
        var encoded = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
        encoded.append(data)
        return encoded
    }

    private func u32(_ value: UInt32) -> Data {
        var encoded = Data()
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { encoded.append(contentsOf: $0) }
        return encoded
    }

    private func u64(_ value: UInt64) -> Data {
        var encoded = Data()
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { encoded.append(contentsOf: $0) }
        return encoded
    }

    private func readFirstSSHString(from data: Data) throws -> (text: String?, nextOffset: Int) {
        guard data.count >= 4 else {
            throw CertificateAuthorityError.signingFailed(message: "Malformed SSH key data.")
        }
        let length = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let end = 4 + Int(length)
        guard end <= data.count else {
            throw CertificateAuthorityError.signingFailed(message: "Malformed SSH key data.")
        }
        let payload = Data(data[4..<end])
        let text = String(data: payload, encoding: .utf8)
        return (text, end)
    }

    private func authorizedRepresentation(for certificate: SSHCertificate) -> String? {
        if let existing = certificate.authorizedRepresentation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        guard
            let first = try? readFirstSSHString(from: certificate.rawCertificateData),
            let keyType = first.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !keyType.isEmpty
        else {
            return nil
        }

        let payload = certificate.rawCertificateData.base64EncodedString()
        let keyID = certificate.keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyID.isEmpty {
            return "\(keyType) \(payload)"
        }
        return "\(keyType) \(payload) \(keyID)"
    }

    private func sanitizeFileComponent(_ value: String) -> String {
        let mapped = value.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return collapsed.isEmpty ? "ca" : collapsed
    }

    private func csvSafe(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

private struct ParsedPublicKey {
    var keyType: String
    var rawBlob: Data
    var keySpecificData: Data
}

private struct ParsedExternalCertificate {
    var certificateType: CertificateType
    var serialNumber: UInt64
    var keyID: String
    var principals: [String]
    var validAfter: Date
    var validBefore: Date
    var criticalOptions: [String: String]
    var extensions: [String]
    var signingCAFingerprint: String
    var signedKeyFingerprint: String
    var signatureAlgorithm: String
    var rawCertificateData: Data
    var authorizedRepresentation: String
    var importSource: String?
}

private struct SSHBinaryReader {
    let data: Data
    var offset: Int = 0

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readUInt32(context: String) throws -> UInt32 {
        let bytes = try readBytes(count: 4, context: context)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64(context: String) throws -> UInt64 {
        let bytes = try readBytes(count: 8, context: context)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readStringData(context: String) throws -> Data {
        let length = Int(try readUInt32(context: "\(context) length"))
        return try readBytes(count: length, context: context)
    }

    mutating func readStringText(context: String) throws -> String {
        let payload = try readStringData(context: context)
        guard let text = String(data: payload, encoding: .utf8) else {
            throw CertificateAuthorityError.signingFailed(message: "Malformed \(context).")
        }
        return text
    }

    private mutating func readBytes(count: Int, context: String) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw CertificateAuthorityError.signingFailed(message: "Malformed \(context).")
        }
        let end = offset + count
        let chunk = Data(data[offset..<end])
        offset = end
        return chunk
    }
}

private enum CertificateRole {
    case user
    case host

    init?(sshCertificateTypeRaw value: UInt32) {
        switch value {
        case 1:
            self = .user
        case 2:
            self = .host
        default:
            return nil
        }
    }

    var sshCertificateType: UInt32 {
        switch self {
        case .user: return 1
        case .host: return 2
        }
    }

    var modelCertificateType: CertificateType {
        switch self {
        case .user: return .user
        case .host: return .host
        }
    }

    var unsupportedAuthorityType: CertificateType {
        switch self {
        case .user: return .host
        case .host: return .user
        }
    }

    var unsupportedAuthorityMessage: String {
        switch self {
        case .user: return "Selected CA only allows host certificates."
        case .host: return "Selected CA only allows user certificates."
        }
    }

    var displayName: String {
        switch self {
        case .user: return "user"
        case .host: return "host"
        }
    }
}
