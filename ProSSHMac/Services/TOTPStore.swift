// TOTPStore.swift
// TOTP secret storage and prompt auto-fill detection for ProSSHMac
//
// TOTPStore: Manages TOTP secret lifecycle (save/retrieve/delete) via
// the existing BiometricPasswordStore/EncryptedStorage infrastructure.
//
// TOTPAutoFillDetector: Analyzes keyboard-interactive auth prompts to
// determine if they're asking for a TOTP code, enabling auto-fill.

import Foundation

// MARK: - TOTP Store

/// Manages TOTP secret storage using ProSSHMac's existing encrypted storage.
///
/// Secrets are stored as raw bytes in the Keychain, keyed by host ID.
/// The `TOTPConfiguration` on the Host model only holds the lookup reference,
/// never the secret itself. This ensures secrets don't leak through host
/// exports, JSON backups, or SSH config files.
///
/// Depends on the existing `BiometricPasswordStore` protocol — uses the same
/// Secure Enclave / biometric gating as SSH password storage.
///
/// Usage:
/// ```swift
/// let store = TOTPStore(passwordStore: biometricStore)
///
/// // Save from otpauth:// URI
/// let (config, secret) = try TOTPConfiguration.parse(otpauthURI: qrCodeText)
/// let reference = try await store.saveSecret(secret, forHostID: hostID)
/// host.totpConfiguration = config.withSecretReference(reference)
///
/// // Retrieve for code generation
/// if let secret = try await store.retrieveSecret(forHostID: hostID) {
///     let code = TOTPGenerator().generateCode(secret: secret, configuration: config)
/// }
/// ```
@MainActor
protocol TOTPStoreProtocol {
    /// Save a TOTP secret for a host. Returns the Keychain reference key.
    func saveSecret(_ secret: Data, forHostID hostID: UUID) async throws -> String

    /// Retrieve the TOTP secret for a host. Returns nil if not found.
    func retrieveSecret(forHostID hostID: UUID) async throws -> Data?

    /// Delete the TOTP secret for a host.
    func deleteSecret(forHostID hostID: UUID) async throws

    /// Check if a TOTP secret exists for a host (without retrieving it).
    func hasSecret(forHostID hostID: UUID) async -> Bool
}

/// Concrete TOTP store using the existing BiometricPasswordStore.
///
/// The implementation is intentionally thin — it's a namespaced wrapper
/// that generates consistent Keychain keys and delegates to the existing
/// encrypted storage infrastructure.
@MainActor
final class TOTPStore: TOTPStoreProtocol {

    /// Key prefix for TOTP secrets in the Keychain.
    /// Namespaced to avoid collisions with SSH password entries.
    private static let keyPrefix = "totp-secret-"

    /// The underlying encrypted storage (BiometricPasswordStore or EncryptedStorage).
    /// We use the same protocol the rest of ProSSHMac uses for password storage.
    ///
    /// NOTE: This references the existing storage protocol. During integration,
    /// wire this to the same BiometricPasswordStore instance used by SessionManager.
    private let store: any SecretStorageProtocol

    init(store: any SecretStorageProtocol) {
        self.store = store
    }

    func saveSecret(_ secret: Data, forHostID hostID: UUID) async throws -> String {
        let key = Self.keychainKey(for: hostID)
        try await store.saveData(secret, forKey: key)
        return key
    }

    func retrieveSecret(forHostID hostID: UUID) async throws -> Data? {
        let key = Self.keychainKey(for: hostID)
        return try await store.retrieveData(forKey: key)
    }

    func deleteSecret(forHostID hostID: UUID) async throws {
        let key = Self.keychainKey(for: hostID)
        try await store.deleteData(forKey: key)
    }

    func hasSecret(forHostID hostID: UUID) async -> Bool {
        let key = Self.keychainKey(for: hostID)
        return (try? await store.retrieveData(forKey: key)) != nil
    }

    /// Generate a consistent Keychain key for a host's TOTP secret.
    static func keychainKey(for hostID: UUID) -> String {
        "\(keyPrefix)\(hostID.uuidString)"
    }
}

/// Protocol for the underlying secret storage.
///
/// This abstracts over BiometricPasswordStore / EncryptedStorage so that
/// TOTPStore can be tested with a mock. During integration, conform the
/// existing password store to this protocol (or use an adapter).
@MainActor
protocol SecretStorageProtocol {
    func saveData(_ data: Data, forKey key: String) async throws
    func retrieveData(forKey key: String) async throws -> Data?
    func deleteData(forKey key: String) async throws
}

// MARK: - TOTP Provisioning Service

/// Handles the full provisioning flow: parse URI → store secret → return configuration.
///
/// This is the entry point for both QR code scanning and manual secret entry.
@MainActor
final class TOTPProvisioningService {

    private let store: any TOTPStoreProtocol

    init(store: any TOTPStoreProtocol) {
        self.store = store
    }

    /// Provision TOTP from an `otpauth://` URI (from QR code scan or paste).
    ///
    /// - Parameters:
    ///   - uri: The `otpauth://` URI string.
    ///   - hostID: The host to associate this TOTP configuration with.
    /// - Returns: A complete `TOTPConfiguration` with the `secretReference` set.
    func provision(fromURI uri: String, forHostID hostID: UUID) async throws -> TOTPConfiguration {
        let (config, secret) = try TOTPConfiguration.parse(otpauthURI: uri)
        let reference = try await store.saveSecret(secret, forHostID: hostID)
        return TOTPConfiguration(
            secretReference: reference,
            algorithm: config.algorithm,
            digits: config.digits,
            period: config.period,
            issuer: config.issuer,
            accountName: config.accountName
        )
    }

    /// Provision TOTP from a manually entered Base32 secret string.
    ///
    /// - Parameters:
    ///   - base32Secret: The Base32-encoded secret (from a text field or setup page).
    ///   - algorithm: HMAC algorithm (default: SHA-1).
    ///   - digits: Code length (default: 6).
    ///   - period: Time step in seconds (default: 30).
    ///   - issuer: Optional issuer name for display.
    ///   - accountName: Optional account name for display.
    ///   - hostID: The host to associate this TOTP configuration with.
    /// - Returns: A complete `TOTPConfiguration` with the `secretReference` set.
    func provision(
        fromBase32Secret base32Secret: String,
        algorithm: TOTPAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        issuer: String? = nil,
        accountName: String? = nil,
        forHostID hostID: UUID
    ) async throws -> TOTPConfiguration {
        let secret = try Base32.decode(base32Secret)
        let reference = try await store.saveSecret(secret, forHostID: hostID)
        return TOTPConfiguration(
            secretReference: reference,
            algorithm: algorithm,
            digits: digits,
            period: period,
            issuer: issuer,
            accountName: accountName
        )
    }

    /// Remove TOTP configuration for a host (deletes the secret from Keychain).
    func deprovision(forHostID hostID: UUID) async throws {
        try await store.deleteSecret(forHostID: hostID)
    }

    /// Export an `otpauth://` URI for backup or transfer to another authenticator.
    ///
    /// ⚠️ This exposes the raw secret — caller MUST gate behind biometric confirmation.
    func exportURI(
        configuration: TOTPConfiguration,
        forHostID hostID: UUID
    ) async throws -> String? {
        guard let secret = try await store.retrieveSecret(forHostID: hostID) else {
            return nil
        }
        return configuration.toOTPAuthURI(secret: secret)
    }
}

// MARK: - Auto-Fill Detector

/// Detects TOTP prompts in SSH keyboard-interactive authentication.
///
/// When libssh fires a keyboard-interactive callback with a prompt string,
/// this detector determines whether the prompt is asking for a TOTP code.
/// If yes, ProSSHMac can auto-fill from the host's `TOTPConfiguration`.
///
/// The detector supports:
/// - Built-in patterns for common TOTP prompt formats
/// - Per-host custom patterns via `TOTPConfiguration.customPromptPattern`
/// - Negative patterns to avoid false positives (e.g., "password" prompts)
///
/// Usage:
/// ```swift
/// let detector = TOTPAutoFillDetector()
///
/// // During keyboard-interactive auth callback:
/// if detector.isTOTPPrompt(prompt, customPattern: host.totpConfiguration?.customPromptPattern) {
///     // Auto-fill with generated TOTP code
/// }
/// ```
struct TOTPAutoFillDetector: Sendable {

    /// Result of prompt analysis.
    enum PromptAnalysis: Sendable, Equatable {
        /// This prompt is asking for a TOTP code.
        case totpPrompt(matchedPattern: String)

        /// This prompt is asking for something else (password, etc.).
        case notTOTP

        /// Uncertain — could be TOTP but confidence is low.
        case uncertain(reason: String)
    }

    /// Built-in patterns that match common TOTP/2FA prompts.
    ///
    /// These are case-insensitive substring matches. Ordered by specificity
    /// (most specific first) to give the best `matchedPattern` in results.
    private static let positivePatterns: [(pattern: String, label: String)] = [
        ("verification code",     "Verification code prompt"),
        ("authenticator code",    "Authenticator code prompt"),
        ("authenticator app",     "Authenticator app prompt"),
        ("google authenticator",  "Google Authenticator prompt"),
        ("one-time password",     "One-time password prompt"),
        ("one-time code",         "One-time code prompt"),
        ("otp code",              "OTP code prompt"),
        ("otp:",                  "OTP prompt"),
        ("totp code",             "TOTP code prompt"),
        ("totp:",                 "TOTP prompt"),
        ("2fa code",              "2FA code prompt"),
        ("two-factor",            "Two-factor prompt"),
        ("two factor",            "Two-factor prompt"),
        ("6-digit code",          "6-digit code prompt"),
        ("security code",         "Security code prompt"),
        ("mfa code",              "MFA code prompt"),
        ("multi-factor",          "Multi-factor prompt"),
        ("duo",                   "Duo prompt"),
        ("yubikey",               "YubiKey prompt (may need physical key)"),
        ("freeipa",               "FreeIPA OTP prompt"),
    ]

    /// Patterns that indicate this is NOT a TOTP prompt, even if other
    /// patterns might match. Prevents false positives.
    private static let negativePatterns: [String] = [
        "password",
        "passphrase",
        "pin code",
        "ssh key",
        "private key",
        "enter key",
    ]

    /// Analyze a keyboard-interactive prompt string.
    ///
    /// - Parameters:
    ///   - prompt: The prompt string from the SSH server.
    ///   - customPattern: Optional per-host regex pattern from `TOTPConfiguration`.
    /// - Returns: A `PromptAnalysis` indicating whether this is a TOTP prompt.
    func analyze(
        prompt: String,
        customPattern: String? = nil
    ) -> PromptAnalysis {
        let lowered = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Check negative patterns first — "password" prompts are never TOTP.
        for negative in Self.negativePatterns {
            if lowered.contains(negative) {
                return .notTOTP
            }
        }

        // Check custom pattern (per-host override).
        if let customPattern, !customPattern.isEmpty {
            if let regex = try? NSRegularExpression(pattern: customPattern, options: .caseInsensitive) {
                let range = NSRange(prompt.startIndex..., in: prompt)
                if regex.firstMatch(in: prompt, range: range) != nil {
                    return .totpPrompt(matchedPattern: "Custom: \(customPattern)")
                }
            }
        }

        // Check built-in positive patterns.
        for (pattern, label) in Self.positivePatterns {
            if lowered.contains(pattern) {
                return .totpPrompt(matchedPattern: label)
            }
        }

        // Heuristic: if the prompt is very short and asks for a "code",
        // it's probably TOTP but we're not certain.
        if lowered.contains("code") && lowered.count < 40 {
            return .uncertain(reason: "Short prompt containing 'code' — may be TOTP")
        }

        return .notTOTP
    }

    /// Convenience: simple boolean check for the common case.
    ///
    /// Returns `true` for `.totpPrompt` results, `false` for `.notTOTP`,
    /// and `true` for `.uncertain` (erring on the side of auto-fill attempt).
    func isTOTPPrompt(
        _ prompt: String,
        customPattern: String? = nil
    ) -> Bool {
        switch analyze(prompt: prompt, customPattern: customPattern) {
        case .totpPrompt: return true
        case .uncertain:  return true
        case .notTOTP:    return false
        }
    }
}
