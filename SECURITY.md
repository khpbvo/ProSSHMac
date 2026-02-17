# Security Policy

## Reporting a Vulnerability

Please report security vulnerabilities through
[GitHub Security Advisories](https://github.com/khpbvo/ProSSHMac/security/advisories/new)
(private by default). Do **not** open a public issue for security reports.

We will acknowledge receipt within 72 hours and aim to provide an initial
assessment within one week.

## Scope

The following areas are in scope for security reports:

- Credential exposure (passwords, private keys, passphrases leaking to logs,
  pasteboard, or unprotected storage)
- SSH private key leakage or mishandling
- Encrypted storage bypass (circumventing AES-GCM encryption or Keychain
  master key protections)
- Host key verification bypass (TOFU trust-on-first-use circumvention)
- Secure Enclave key extraction or misuse
- Certificate authority signing flaws

## Out of Scope

- Vulnerabilities in upstream **libssh** or **OpenSSL** libraries. Please
  report those to the respective upstream projects:
  - libssh: https://www.libssh.org/security/
  - OpenSSL: https://www.openssl.org/news/vulnerabilities.html
- Denial-of-service attacks that require local access to the machine
- Issues requiring physical access to an unlocked device

## Security Architecture Overview

ProSSHMac employs several layers of defense:

| Layer | Mechanism |
|---|---|
| **Credential Storage** | AES-256-GCM encryption with a Keychain-managed master key (`EncryptedStorage`) |
| **Hardware Key Protection** | Secure Enclave P-256 keys via `SecureEnclaveKeyManager` for certificate signing |
| **Host Verification** | Trust-on-first-use (TOFU) model with persistent known-hosts store (`FileKnownHostsStore`) |
| **Algorithm Policy** | Modern-first negotiation (curve25519, chacha20-poly1305, ed25519) with opt-in legacy fallback |
| **Audit Logging** | All connection, authentication, and transfer events recorded via `AuditLogManager` |
| **Biometric Gating** | Optional Touch ID / password gating for stored credentials via `BiometricPasswordStore` |
