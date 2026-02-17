// MatrixScreensaverEffect.swift
// ProSSHV2
//
// Matrix-style falling character screensaver configuration.
// Activates after a configurable idle period and renders
// cascading green glyphs across the terminal background.

import Foundation

// MARK: - MatrixScreensaverConfiguration

/// Configuration for the Matrix-style falling character screensaver.
///
/// When enabled, the screensaver activates after the configured idle
/// timeout and displays cascading characters across the screen.
/// Any user interaction (mouse movement, key press) dismisses it.
struct MatrixScreensaverConfiguration: Codable, Sendable, Equatable {

    /// Master toggle — whether the screensaver is active.
    var isEnabled: Bool

    /// Minutes of inactivity before the screensaver activates (1–60).
    var idleTimeoutMinutes: Int

    /// Fall speed multiplier (0.2 = slow, 1.0 = normal, 3.0 = fast).
    var speed: Float

    /// Column density — fraction of screen width filled with streams (0.1–1.0).
    var density: Float

    /// Primary glow color for the falling characters.
    var color: GradientColor

    /// Length of the fading trail behind each leading character (3–40 cells).
    var trailLength: Int

    /// Character set used for the falling glyphs.
    var characterSet: MatrixCharacterSet

    // MARK: - Defaults

    static let `default` = MatrixScreensaverConfiguration(
        isEnabled: false,
        idleTimeoutMinutes: 5,
        speed: 1.0,
        density: 0.6,
        color: GradientColor(red: 0.0, green: 0.9, blue: 0.2, alpha: 1.0),
        trailLength: 16,
        characterSet: .katakanaAndLatin
    )

    // MARK: - Persistence

    static let defaultsKey = "terminal.effects.matrixScreensaver"

    static func load(from defaults: UserDefaults = .standard) -> MatrixScreensaverConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(MatrixScreensaverConfiguration.self, from: data)
        else {
            return .default
        }
        return config
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - MatrixCharacterSet

/// The set of characters used in the falling rain.
enum MatrixCharacterSet: Int, CaseIterable, Identifiable, Codable, Sendable {
    case katakanaAndLatin = 0
    case katakanaOnly = 1
    case latinOnly = 2
    case digits = 3
    case binary = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .katakanaAndLatin: return "Katakana + Latin"
        case .katakanaOnly:     return "Katakana"
        case .latinOnly:        return "Latin"
        case .digits:           return "Digits"
        case .binary:           return "Binary"
        }
    }

    /// Returns the pool of characters for this set.
    var characters: [Character] {
        switch self {
        case .katakanaAndLatin:
            return Self.katakanaChars + Self.latinChars
        case .katakanaOnly:
            return Self.katakanaChars
        case .latinOnly:
            return Self.latinChars
        case .digits:
            return Array("0123456789")
        case .binary:
            return Array("01")
        }
    }

    private static let katakanaChars: [Character] = {
        // Half-width Katakana range: U+FF66 to U+FF9D
        (0xFF66...0xFF9D).compactMap { UnicodeScalar($0).map { Character($0) } }
    }()

    private static let latinChars: [Character] = {
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*")
    }()
}
