import Foundation
import LocalAuthentication
import Security

protocol BiometricPasswordStoring: Sendable {
    func isBiometricsAvailable() -> Bool
    func save(password: String, forHostID hostID: UUID) throws
    func retrieve(forHostID hostID: UUID, reason: String) async throws -> String
    func delete(forHostID hostID: UUID) throws
    func hasStoredPassword(forHostID hostID: UUID) -> Bool
}

enum BiometricPasswordError: LocalizedError {
    case biometricsUnavailable
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case noPasswordStored
    case dataConversionFailed
    case authenticationFailed
    case userCancelled

    var errorDescription: String? {
        switch self {
        case .biometricsUnavailable:
            return "Biometric authentication is not available on this device."
        case .saveFailed(let status):
            return "Failed to save password to Keychain (status \(status))."
        case .retrieveFailed(let status):
            return "Failed to retrieve password from Keychain (status \(status))."
        case .deleteFailed(let status):
            return "Failed to delete password from Keychain (status \(status))."
        case .noPasswordStored:
            return "No saved password found for this host."
        case .dataConversionFailed:
            return "Password data could not be converted."
        case .authenticationFailed:
            return "Biometric authentication failed."
        case .userCancelled:
            return "Authentication was cancelled by the user."
        }
    }
}

final class BiometricPasswordStore: BiometricPasswordStoring {
    private let service: String

    init(service: String = "nl.budgetsoft.ProSSHV2.host-passwords") {
        self.service = service
    }

    func isBiometricsAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func save(password: String, forHostID hostID: UUID) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw BiometricPasswordError.dataConversionFailed
        }

        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            throw BiometricPasswordError.saveFailed(errSecParam)
        }

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString,
            kSecValueData as String: passwordData,
            kSecAttrAccessControl as String: accessControl
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricPasswordError.saveFailed(status)
        }
    }

    func retrieve(forHostID hostID: UUID, reason: String) async throws -> String {
        let service = self.service
        let account = hostID.uuidString

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedReason = reason

                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecUseAuthenticationContext as String: context
                ]

                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)

                guard status == errSecSuccess,
                      let data = result as? Data,
                      let password = String(data: data, encoding: .utf8) else {
                    switch status {
                    case errSecItemNotFound:
                        continuation.resume(throwing: BiometricPasswordError.noPasswordStored)
                    case errSecAuthFailed:
                        continuation.resume(throwing: BiometricPasswordError.authenticationFailed)
                    case errSecUserCanceled:
                        continuation.resume(throwing: BiometricPasswordError.userCancelled)
                    case errSecSuccess:
                        // Status was success but data conversion failed.
                        continuation.resume(throwing: BiometricPasswordError.dataConversionFailed)
                    default:
                        continuation.resume(throwing: BiometricPasswordError.retrieveFailed(status))
                    }
                    return
                }

                continuation.resume(returning: password)
            }
        }
    }

    func delete(forHostID hostID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BiometricPasswordError.deleteFailed(status)
        }
    }

    func hasStoredPassword(forHostID hostID: UUID) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString,
            kSecUseAuthenticationContext as String: context
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecInteractionNotAllowed means the item exists but requires biometric
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    // MARK: - Raw Keychain helpers (no biometric gate — used for TOTP auto-fill)

    /// Save arbitrary base64-encoded data under a string account key with no biometric requirement.
    /// Uses kSecAttrAccessibleAfterFirstUnlock so it can be read during background auth flows.
    func saveRaw(_ base64: String, account: String) throws {
        guard let data = base64.data(using: .utf8) else {
            throw BiometricPasswordError.dataConversionFailed
        }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricPasswordError.saveFailed(status)
        }
    }

    /// Retrieve a base64-encoded string stored under a raw account key (no biometric prompt).
    func retrieveRaw(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw BiometricPasswordError.retrieveFailed(status)
        }
        return string
    }

    /// Delete a raw Keychain item stored under a string account key.
    func deleteRaw(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BiometricPasswordError.deleteFailed(status)
        }
    }
}

// MARK: - SecretStorageProtocol conformance (used by TOTPStore)

extension BiometricPasswordStore: SecretStorageProtocol {
    func saveData(_ data: Data, forKey key: String) async throws {
        let base64 = data.base64EncodedString()
        try saveRaw(base64, account: key)
    }

    func retrieveData(forKey key: String) async throws -> Data? {
        guard let base64 = try retrieveRaw(account: key) else { return nil }
        return Data(base64Encoded: base64)
    }

    func deleteData(forKey key: String) async throws {
        try deleteRaw(account: key)
    }
}
