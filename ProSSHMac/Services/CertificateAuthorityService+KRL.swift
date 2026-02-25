// Extracted from CertificateAuthorityService.swift
import Foundation

extension CertificateAuthorityService {

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

    func authorizedRepresentation(for certificate: SSHCertificate) -> String? {
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

    func sanitizeFileComponent(_ value: String) -> String {
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

    func csvSafe(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
