// Extracted from CertificateAuthorityService.swift
import Foundation

struct ParsedPublicKey {
    var keyType: String
    var rawBlob: Data
    var keySpecificData: Data
}

struct ParsedExternalCertificate {
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

struct SSHBinaryReader {
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

enum CertificateRole {
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
