// Extracted from LibSSHTransport.swift
import Foundation

protocol SSHCredentialResolving: Sendable {
    nonisolated func privateKey(for reference: UUID) throws -> String
    nonisolated func certificate(for reference: UUID) throws -> String
}
