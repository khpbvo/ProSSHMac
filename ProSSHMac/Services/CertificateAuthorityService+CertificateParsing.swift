// Extracted from CertificateAuthorityService.swift
import Foundation

extension CertificateAuthorityService {

    func parseAuthorizedCertificate(_ authorizedCertificate: String) throws -> ParsedExternalCertificate {
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

    func parseAuthorizedPublicKey(_ authorized: String) throws -> ParsedPublicKey {
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

    func skipCertificateSubjectKeyData(
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

    func parseStringListPayload(_ payload: Data, context: String) throws -> [String] {
        var values: [String] = []
        var reader = SSHBinaryReader(data: payload)

        while !reader.isAtEnd {
            values.append(try reader.readStringText(context: context))
        }
        return values
    }

    func parseNameValueMapPayload(_ payload: Data, context: String) throws -> [String: String] {
        var values: [String: String] = [:]
        var reader = SSHBinaryReader(data: payload)

        while !reader.isAtEnd {
            let key = try reader.readStringText(context: context)
            let rawValue = try reader.readStringData(context: context)
            values[key] = displayValue(forOptionData: rawValue)
        }
        return values
    }

    func displayValue(forOptionData data: Data) -> String {
        if data.isEmpty {
            return ""
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    func parseSignatureAlgorithm(_ signatureBlob: Data) -> String {
        var reader = SSHBinaryReader(data: signatureBlob)
        guard let algorithm = try? reader.readStringText(context: "signature algorithm"), !algorithm.isEmpty else {
            return "unknown"
        }
        return algorithm
    }

    func baseKeyType(fromCertificateKeyType certificateKeyType: String) throws -> String {
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

    func certificateKeyType(for keyType: String) throws -> String {
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
}
