import Foundation

enum CertificateType: String, Codable, CaseIterable, Identifiable {
    case user
    case host
    case both

    var id: String { rawValue }
}

struct SSHCertificate: Identifiable, Codable, Hashable {
    var id: UUID
    var type: CertificateType
    var serialNumber: UInt64
    var keyId: String
    var principals: [String]
    var validAfter: Date
    var validBefore: Date
    var criticalOptions: [String: String]
    var extensions: [String]
    var signingCAFingerprint: String
    var signedKeyFingerprint: String
    var signatureAlgorithm: String
    var associatedKeyId: UUID?
    var rawCertificateData: Data
    var authorizedRepresentation: String?
    var importedFrom: String?
    var createdAt: Date
}

struct CertificateAuthorityModel: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    var keyType: KeyType
    var publicKeyFingerprint: String
    var publicKeyAuthorizedFormat: String?
    var secureEnclaveReference: String
    var certificateType: CertificateType
    var defaultValidityDuration: TimeInterval
    var nextSerialNumber: UInt64
    var issuedCertificateCount: UInt64
    var createdAt: Date
    var notes: String?
}
