// TOTPGenerator.swift
// RFC 6238 TOTP code generation engine for ProSSHMac
//
// Pure computation — takes secret bytes + timestamp, returns a code string.
// No I/O, no Keychain access, no side effects. Uses CommonCrypto for HMAC.

import Foundation
import CommonCrypto

// MARK: - Generator

/// Generates time-based one-time passwords per RFC 6238 (TOTP) and RFC 4226 (HOTP).
///
/// The algorithm:
/// 1. Compute `counter = floor(unixTime / period)`
/// 2. Encode counter as 8-byte big-endian
/// 3. Compute `HMAC(algorithm, secret, counter)`
/// 4. Dynamic truncation: extract 4 bytes at offset determined by last nibble
/// 5. Mask to 31 bits, modulo 10^digits
///
/// Usage:
/// ```swift
/// let generator = TOTPGenerator()
/// let code = generator.generateCode(
///     secret: secretBytes,
///     algorithm: .sha1,
///     digits: 6,
///     period: 30,
///     timestamp: Date()
/// )
/// // code == "123456"
/// ```
struct TOTPGenerator: Sendable {

    /// Result of code generation, includes metadata for UI display.
    struct CodeResult: Sendable, Equatable {
        /// The generated TOTP code (zero-padded to `digits` length).
        let code: String

        /// Seconds remaining in the current time period.
        let secondsRemaining: Int

        /// Total period length in seconds.
        let period: Int

        /// The time step counter used for generation.
        let counter: UInt64

        /// Progress through the current period (0.0 = just started, 1.0 = about to expire).
        var progress: Double {
            1.0 - (Double(secondsRemaining) / Double(period))
        }

        /// Whether the code is about to expire (≤5 seconds remaining).
        var isExpiringSoon: Bool {
            secondsRemaining <= 5
        }
    }

    /// Generate a TOTP code for the given parameters.
    ///
    /// - Parameters:
    ///   - secret: Raw secret bytes (decoded from Base32).
    ///   - algorithm: HMAC algorithm (default: SHA-1).
    ///   - digits: Code length, 6 or 8 (default: 6).
    ///   - period: Time step in seconds (default: 30).
    ///   - timestamp: The current time (default: now).
    ///   - driftOffset: Clock drift adjustment in seconds (default: 0).
    /// - Returns: A `CodeResult` with the code and timing metadata.
    func generateCode(
        secret: Data,
        algorithm: TOTPAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        timestamp: Date = .now,
        driftOffset: Int = 0
    ) -> CodeResult {
        let unixTime = Int(timestamp.timeIntervalSince1970) + driftOffset
        let counter = UInt64(unixTime / period)
        let secondsRemaining = period - (unixTime % period)

        let code = generateHOTP(
            secret: secret,
            counter: counter,
            algorithm: algorithm,
            digits: digits
        )

        return CodeResult(
            code: code,
            secondsRemaining: secondsRemaining,
            period: period,
            counter: counter
        )
    }

    /// Generate a TOTP code using a `TOTPConfiguration` and secret bytes.
    ///
    /// Convenience method that unpacks configuration fields.
    func generateCode(
        secret: Data,
        configuration: TOTPConfiguration,
        timestamp: Date = .now
    ) -> CodeResult {
        generateCode(
            secret: secret,
            algorithm: configuration.algorithm,
            digits: configuration.digits,
            period: configuration.period,
            timestamp: timestamp,
            driftOffset: configuration.driftOffset
        )
    }

    /// Generate a "smart" code that picks the next period's code if the current
    /// one is about to expire.
    ///
    /// If the current code has ≤ `threshold` seconds remaining, generates
    /// the next code instead. This avoids the "panic type before it expires"
    /// problem that plagues authenticator apps.
    ///
    /// - Parameter threshold: Seconds threshold for switching to next code (default: 3).
    /// - Returns: A `CodeResult`. If the next period's code was used, `secondsRemaining`
    ///   reflects the full next period plus the remaining seconds.
    func generateSmartCode(
        secret: Data,
        configuration: TOTPConfiguration,
        timestamp: Date = .now,
        threshold: Int = 3
    ) -> CodeResult {
        let current = generateCode(
            secret: secret,
            configuration: configuration,
            timestamp: timestamp
        )

        if current.secondsRemaining <= threshold {
            // Generate next period's code.
            let nextTimestamp = timestamp.addingTimeInterval(TimeInterval(current.secondsRemaining))
            let next = generateCode(
                secret: secret,
                configuration: configuration,
                timestamp: nextTimestamp
            )
            // Adjust remaining time: current remainder + full next period.
            return CodeResult(
                code: next.code,
                secondsRemaining: current.secondsRemaining + configuration.period,
                period: configuration.period,
                counter: next.counter
            )
        }

        return current
    }

    /// Validate a code against a window of time steps.
    ///
    /// Useful for testing or for server-side validation. Checks the given code
    /// against `window` time steps before and after the current counter.
    ///
    /// - Parameter window: Number of periods to check in each direction (default: 1).
    /// - Returns: `true` if the code matches any time step in the window.
    func validateCode(
        _ code: String,
        secret: Data,
        algorithm: TOTPAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        timestamp: Date = .now,
        driftOffset: Int = 0,
        window: Int = 1
    ) -> Bool {
        let unixTime = Int(timestamp.timeIntervalSince1970) + driftOffset
        let currentCounter = UInt64(unixTime / period)

        for offset in -window...window {
            let counter = currentCounter &+ UInt64(bitPattern: Int64(offset))
            let generated = generateHOTP(
                secret: secret,
                counter: counter,
                algorithm: algorithm,
                digits: digits
            )
            if generated == code {
                return true
            }
        }

        return false
    }

    // MARK: - RFC 4226 HOTP Core

    /// Generate an HOTP code per RFC 4226.
    ///
    /// This is the core algorithm shared by both HOTP and TOTP.
    /// TOTP simply uses `floor(time / period)` as the counter.
    private func generateHOTP(
        secret: Data,
        counter: UInt64,
        algorithm: TOTPAlgorithm,
        digits: Int
    ) -> String {
        // Step 1: Encode counter as 8-byte big-endian.
        var counterBigEndian = counter.bigEndian
        let counterData = Data(bytes: &counterBigEndian, count: 8)

        // Step 2: Compute HMAC.
        let hmac = computeHMAC(
            algorithm: algorithm,
            key: secret,
            data: counterData
        )

        // Step 3: Dynamic truncation (RFC 4226 §5.4).
        let offset = Int(hmac[hmac.count - 1] & 0x0F)
        let truncated: UInt32 =
            (UInt32(hmac[offset])     & 0x7F) << 24 |
            (UInt32(hmac[offset + 1]) & 0xFF) << 16 |
            (UInt32(hmac[offset + 2]) & 0xFF) << 8  |
            (UInt32(hmac[offset + 3]) & 0xFF)

        // Step 4: Modulo to get the desired number of digits.
        let modulus = UInt32(pow(10.0, Double(digits)))
        let code = truncated % modulus

        // Zero-pad to the correct number of digits.
        return String(format: "%0\(digits)d", code)
    }

    // MARK: - HMAC via CommonCrypto

    /// Compute HMAC using CommonCrypto.
    ///
    /// CommonCrypto is available on all Apple platforms without additional
    /// dependencies. We use it instead of CryptoKit because CryptoKit's
    /// HMAC doesn't expose raw bytes as cleanly for the truncation step.
    private func computeHMAC(
        algorithm: TOTPAlgorithm,
        key: Data,
        data: Data
    ) -> Data {
        let ccAlgorithm: CCHmacAlgorithm
        let digestLength: Int

        switch algorithm {
        case .sha1:
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA1)
            digestLength = Int(CC_SHA1_DIGEST_LENGTH)
        case .sha256:
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA256)
            digestLength = Int(CC_SHA256_DIGEST_LENGTH)
        case .sha512:
            ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA512)
            digestLength = Int(CC_SHA512_DIGEST_LENGTH)
        }

        var result = Data(count: digestLength)

        result.withUnsafeMutableBytes { resultPtr in
            key.withUnsafeBytes { keyPtr in
                data.withUnsafeBytes { dataPtr in
                    CCHmac(
                        ccAlgorithm,
                        keyPtr.baseAddress, key.count,
                        dataPtr.baseAddress, data.count,
                        resultPtr.baseAddress
                    )
                }
            }
        }

        return result
    }
}
