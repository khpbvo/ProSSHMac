// TOTPConfiguration.swift
// TOTP 2FA configuration model for ProSSHMac
//
// Stored on the Host model as an optional field. The actual secret
// bytes live in BiometricPasswordStore/EncryptedStorage — this struct
// only holds parameters and a Keychain lookup reference.

import Foundation

// MARK: - TOTP Algorithm

/// Hash algorithm used for HMAC in TOTP generation (RFC 6238 §1.2).
enum TOTPAlgorithm: String, Codable, CaseIterable, Identifiable, Sendable {
    case sha1
    case sha256
    case sha512

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sha1:   return "SHA-1"
        case .sha256: return "SHA-256"
        case .sha512: return "SHA-512"
        }
    }

    /// HMAC output length in bytes for this algorithm.
    var hashLength: Int {
        switch self {
        case .sha1:   return 20
        case .sha256: return 32
        case .sha512: return 64
        }
    }
}

// MARK: - TOTP Configuration

/// Configuration for TOTP-based two-factor authentication on an SSH host.
///
/// Stored as an optional field on `Host`. The TOTP secret itself is stored
/// separately in the Keychain via `BiometricPasswordStore`, referenced by
/// `secretReference`. This ensures secrets never appear in host exports,
/// JSON backups, or SSH config files.
///
/// Conforms to the `otpauth://` URI scheme (de facto standard, originally
/// defined by Google Authenticator, now universal across TOTP apps).
struct TOTPConfiguration: Codable, Hashable, Sendable {

    /// Keychain lookup key for the TOTP secret (e.g., "totp-secret-{hostID}").
    /// The actual secret bytes are stored in BiometricPasswordStore.
    var secretReference: String

    /// HMAC algorithm. Defaults to SHA-1 (most common; used by Google Authenticator).
    var algorithm: TOTPAlgorithm

    /// Number of digits in the generated code. Typically 6, sometimes 8.
    var digits: Int

    /// Time step in seconds. Standard is 30; some systems use 60.
    var period: Int

    /// Issuer name for display (e.g., "UMCG", "RAV-BN VPN", "FreeIPA").
    var issuer: String?

    /// Account name for display (e.g., "k.vanosch@hsc.nl").
    var accountName: String?

    /// Optional custom regex pattern to match server prompts for auto-fill.
    /// When nil, the default prompt detection patterns are used.
    var customPromptPattern: String?

    /// Clock drift offset in seconds. Normally 0. Adjust if a specific
    /// server's clock is consistently off.
    var driftOffset: Int

    init(
        secretReference: String,
        algorithm: TOTPAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        issuer: String? = nil,
        accountName: String? = nil,
        customPromptPattern: String? = nil,
        driftOffset: Int = 0
    ) {
        self.secretReference = secretReference
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.issuer = issuer
        self.accountName = accountName
        self.customPromptPattern = customPromptPattern
        self.driftOffset = driftOffset
    }
}

// MARK: - otpauth:// URI Parsing

extension TOTPConfiguration {

    /// Errors that can occur when parsing an `otpauth://` URI.
    enum ParseError: LocalizedError, Sendable {
        case invalidScheme
        case invalidType
        case missingSecret
        case invalidBase32Secret
        case invalidDigits
        case invalidPeriod

        var errorDescription: String? {
            switch self {
            case .invalidScheme:       return "URI must start with otpauth://"
            case .invalidType:         return "Only TOTP is supported (not HOTP)"
            case .missingSecret:       return "Secret parameter is required"
            case .invalidBase32Secret: return "Secret is not valid Base32"
            case .invalidDigits:       return "Digits must be 6 or 8"
            case .invalidPeriod:       return "Period must be a positive integer"
            }
        }
    }

    /// Parse an `otpauth://` URI into a TOTPConfiguration and raw secret.
    ///
    /// URI format:
    /// ```
    /// otpauth://totp/ISSUER:ACCOUNT?secret=BASE32SECRET&issuer=ISSUER&algorithm=SHA1&digits=6&period=30
    /// ```
    ///
    /// - Parameter uri: The `otpauth://` URI string (typically from a QR code).
    /// - Returns: A tuple of (configuration, rawSecretBytes). The caller is responsible
    ///   for storing the secret bytes in the Keychain and setting `secretReference`.
    static func parse(otpauthURI uri: String) throws -> (config: TOTPConfiguration, secret: Data) {
        guard let components = URLComponents(string: uri),
              components.scheme == "otpauth" else {
            throw ParseError.invalidScheme
        }

        // Type must be "totp" (we don't support HOTP counter-based).
        guard components.host?.lowercased() == "totp" else {
            throw ParseError.invalidType
        }

        // Parse label path: "/ISSUER:ACCOUNT" or "/ACCOUNT"
        let labelPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let (pathIssuer, pathAccount) = parseLabelPath(labelPath)

        // Parse query parameters.
        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? [])
                .compactMap { item -> (String, String)? in
                    guard let value = item.value else { return nil }
                    return (item.name.lowercased(), value)
                }
        )

        // Secret (required).
        guard let secretBase32 = params["secret"] else {
            throw ParseError.missingSecret
        }
        let secretData = try Base32.decode(secretBase32)

        // Algorithm (optional, default SHA1).
        let algorithm: TOTPAlgorithm
        switch params["algorithm"]?.lowercased() {
        case "sha256": algorithm = .sha256
        case "sha512": algorithm = .sha512
        default:       algorithm = .sha1
        }

        // Digits (optional, default 6).
        let digits: Int
        if let digitsStr = params["digits"] {
            guard let d = Int(digitsStr), d == 6 || d == 8 else {
                throw ParseError.invalidDigits
            }
            digits = d
        } else {
            digits = 6
        }

        // Period (optional, default 30).
        let period: Int
        if let periodStr = params["period"] {
            guard let p = Int(periodStr), p > 0 else {
                throw ParseError.invalidPeriod
            }
            period = p
        } else {
            period = 30
        }

        // Issuer: query param takes precedence over path prefix.
        let issuer = params["issuer"] ?? pathIssuer
        let accountName = pathAccount

        let config = TOTPConfiguration(
            secretReference: "",  // Caller sets this after Keychain storage
            algorithm: algorithm,
            digits: digits,
            period: period,
            issuer: issuer,
            accountName: accountName
        )

        return (config, secretData)
    }

    /// Generate an `otpauth://` URI from this configuration and raw secret bytes.
    ///
    /// Useful for exporting to other authenticator apps (e.g., showing a QR code).
    /// Requires biometric confirmation before calling — the secret is sensitive.
    func toOTPAuthURI(secret: Data) -> String {
        let secretBase32 = Base32.encode(secret)

        // Build label: "ISSUER:ACCOUNT" or just "ACCOUNT"
        var label = ""
        if let issuer, !issuer.isEmpty {
            label = "\(issuer):\(accountName ?? "ProSSHMac")"
        } else {
            label = accountName ?? "ProSSHMac"
        }

        let encodedLabel = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label

        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = "totp"
        components.path = "/\(encodedLabel)"

        var queryItems = [
            URLQueryItem(name: "secret", value: secretBase32),
            URLQueryItem(name: "algorithm", value: algorithm.rawValue.uppercased()),
            URLQueryItem(name: "digits", value: String(digits)),
            URLQueryItem(name: "period", value: String(period))
        ]

        if let issuer, !issuer.isEmpty {
            queryItems.append(URLQueryItem(name: "issuer", value: issuer))
        }

        components.queryItems = queryItems

        return components.string ?? "otpauth://totp/?secret=\(secretBase32)"
    }

    // MARK: - Private Helpers

    /// Parse the label path component: "ISSUER:ACCOUNT" or just "ACCOUNT".
    private static func parseLabelPath(_ path: String) -> (issuer: String?, account: String?) {
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.isEmpty else { return (nil, nil) }

        if let colonIndex = decoded.firstIndex(of: ":") {
            let issuer = String(decoded[decoded.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespaces)
            let account = String(decoded[decoded.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            return (issuer.isEmpty ? nil : issuer, account.isEmpty ? nil : account)
        }

        return (nil, decoded)
    }
}

// MARK: - Base32 Codec

/// RFC 4648 Base32 encoder/decoder for TOTP secrets.
///
/// TOTP secrets are conventionally transmitted as Base32 strings (uppercase,
/// no padding required). This is a minimal implementation — not a general-
/// purpose Base32 library.
enum Base32: Sendable {

    private static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static let decodeTable: [UInt8: UInt8] = {
        var table: [UInt8: UInt8] = [:]
        for (index, char) in alphabet.enumerated() {
            table[UInt8(char.asciiValue!)] = UInt8(index)
            // Also accept lowercase.
            if let lower = Character(String(char).lowercased()).asciiValue {
                table[lower] = UInt8(index)
            }
        }
        return table
    }()

    /// Decode a Base32 string to raw bytes.
    ///
    /// Accepts uppercase and lowercase input, ignores padding (`=`) and whitespace.
    static func decode(_ input: String) throws -> Data {
        // Strip padding and whitespace.
        let cleaned = input
            .filter { !$0.isWhitespace && $0 != "=" }

        guard !cleaned.isEmpty else {
            throw TOTPConfiguration.ParseError.invalidBase32Secret
        }

        var bits: UInt64 = 0
        var bitCount = 0
        var output = Data()

        for char in cleaned {
            guard let ascii = char.asciiValue,
                  let value = decodeTable[ascii] else {
                throw TOTPConfiguration.ParseError.invalidBase32Secret
            }

            bits = (bits << 5) | UInt64(value)
            bitCount += 5

            if bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((bits >> bitCount) & 0xFF))
            }
        }

        return output
    }

    /// Encode raw bytes to a Base32 string (uppercase, no padding).
    static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        var bits: UInt64 = 0
        var bitCount = 0
        var result = ""

        for byte in data {
            bits = (bits << 8) | UInt64(byte)
            bitCount += 8

            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((bits >> bitCount) & 0x1F)
                result.append(alphabet[index])
            }
        }

        // Handle remaining bits (pad with zeros on the right).
        if bitCount > 0 {
            let index = Int((bits << (5 - bitCount)) & 0x1F)
            result.append(alphabet[index])
        }

        return result
    }
}
