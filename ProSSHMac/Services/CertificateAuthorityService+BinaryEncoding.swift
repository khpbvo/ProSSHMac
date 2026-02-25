// Extracted from CertificateAuthorityService.swift
import Foundation
import CryptoKit
import Security

extension CertificateAuthorityService {

    func sshString(from text: String) -> Data {
        sshString(from: Data(text.utf8))
    }

    func sshString(from data: Data) -> Data {
        var encoded = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
        encoded.append(data)
        return encoded
    }

    func u32(_ value: UInt32) -> Data {
        var encoded = Data()
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { encoded.append(contentsOf: $0) }
        return encoded
    }

    func u64(_ value: UInt64) -> Data {
        var encoded = Data()
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { encoded.append(contentsOf: $0) }
        return encoded
    }

    func encodeStringList(_ values: [String]) -> Data {
        var result = Data()
        for value in values {
            result.append(sshString(from: value))
        }
        return result
    }

    func encodeNameValueMap(_ values: [String: String]) -> Data {
        var mapPayload = Data()
        for key in values.keys.sorted() {
            mapPayload.append(sshString(from: key))
            mapPayload.append(sshString(from: values[key] ?? ""))
        }
        return mapPayload
    }

    func fingerprintSHA256(for keyBlob: Data) -> String {
        let digest = SHA256.hash(data: keyBlob)
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }

    func randomBytes(count: Int) throws -> Data {
        var buffer = Data(count: count)
        let status = buffer.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CertificateAuthorityError.signingFailed(message: "Failed to generate certificate nonce.")
        }
        return buffer
    }

    func readFirstSSHString(from data: Data) throws -> (text: String?, nextOffset: Int) {
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
}
