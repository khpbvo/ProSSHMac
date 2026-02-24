// Extracted from SSHTransport.swift
import Foundation

struct SSHAlgorithmPolicy {
    let keyExchange: [String]
    let hostKeys: [String]
    let ciphers: [String]
    let macs: [String]

    nonisolated static let modern = SSHAlgorithmPolicy(
        keyExchange: ["curve25519-sha256", "ecdh-sha2-nistp256", "diffie-hellman-group14-sha256"],
        hostKeys: ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-256"],
        ciphers: ["chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com", "aes128-ctr"],
        macs: ["hmac-sha2-256-etm@openssh.com", "hmac-sha2-512"]
    )

    nonisolated static let legacy = SSHAlgorithmPolicy(
        keyExchange: ["diffie-hellman-group14-sha1", "diffie-hellman-group1-sha1"],
        hostKeys: ["ssh-rsa", "ssh-dss"],
        ciphers: ["aes128-cbc", "3des-cbc"],
        macs: ["hmac-sha1", "hmac-sha1-96"]
    )
}
