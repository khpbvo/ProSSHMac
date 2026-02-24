// Extracted from LibSSHTransport.swift
import Foundation

struct DefaultSSHCredentialResolver: SSHCredentialResolving {

    nonisolated func privateKey(for reference: UUID) throws -> String {
        let keys = try loadStoredKeys()
        guard let storedKey = keys.first(where: { $0.id == reference }) else {
            throw SSHTransportError.transportFailure(message: "Referenced SSH private key was not found.")
        }
        let privateKey = storedKey.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !privateKey.isEmpty else {
            throw SSHTransportError.transportFailure(
                message: "Referenced SSH key does not contain private key material."
            )
        }
        return privateKey
    }

    nonisolated func certificate(for reference: UUID) throws -> String {
        let certificates = try loadStoredCertificates()
        guard let certificate = certificates.first(where: { $0.id == reference }) else {
            throw SSHTransportError.transportFailure(message: "Referenced SSH certificate was not found.")
        }
        if let authorized = certificate.authorizedRepresentation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !authorized.isEmpty {
            return authorized
        }
        guard let keyType = Self.readSSHStringPrefix(from: certificate.rawCertificateData) else {
            throw SSHTransportError.transportFailure(
                message: "Referenced certificate is missing OpenSSH authorized representation."
            )
        }
        let base64 = certificate.rawCertificateData.base64EncodedString()
        let comment = certificate.keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        if comment.isEmpty {
            return "\(keyType) \(base64)"
        }
        return "\(keyType) \(base64) \(comment)"
    }

    nonisolated private func loadStoredKeys() throws -> [StoredSSHKey] {
        let fileURL = Self.applicationSupportFileURL(filename: "keys.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [StoredSSHKey].self,
            from: fileURL,
            fileManager: .default,
            decoder: decoder
        ) ?? []
    }

    nonisolated private func loadStoredCertificates() throws -> [SSHCertificate] {
        let fileURL = Self.applicationSupportFileURL(filename: "certificates.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try EncryptedStorage.loadJSON(
            [SSHCertificate].self,
            from: fileURL,
            fileManager: .default,
            decoder: decoder
        ) ?? []
    }

    nonisolated private static func applicationSupportFileURL(filename: String) -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("ProSSHV2", isDirectory: true)
            .appendingPathComponent(filename)
    }

    nonisolated private static func readSSHStringPrefix(from data: Data) -> String? {
        guard data.count >= 4 else {
            return nil
        }
        let length = data.prefix(4).reduce(0) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard length > 0 else {
            return nil
        }
        let requiredCount = 4 + Int(length)
        guard data.count >= requiredCount else {
            return nil
        }
        let stringData = data.subdata(in: 4..<requiredCount)
        return String(data: stringData, encoding: .utf8)
    }
}
