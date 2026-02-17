// ScannerEffect.swift
// ProSSHV2
//
// Knight Rider KITT-style scanner effect configuration.
// Renders a sweeping red glow across the username portion of the
// terminal prompt on the cursor row. Active only for local sessions.

import Foundation

// MARK: - ScannerEffectConfiguration

/// Configuration for the Knight Rider scanner glow effect.
///
/// When enabled, a colored glow sweeps left-to-right and back across the
/// username characters on the active prompt line. The username length is
/// resolved dynamically from the OS at render time.
struct ScannerEffectConfiguration: Codable, Sendable, Equatable {

    /// Master toggle — whether the scanner effect is active.
    var isEnabled: Bool

    /// Sweep speed multiplier (0.2 = slow, 1.0 = normal, 3.0 = fast).
    var speed: Float

    /// Width of the glow band as a fraction of the username span (0.05–0.4).
    var glowWidth: Float

    /// Brightness intensity of the glow (0.3–2.0).
    var intensity: Float

    /// Glow color (default: KITT red).
    var color: GradientColor

    /// Length of the trailing tail behind the scanner (0.0–0.5).
    var trailLength: Float

    // MARK: - Defaults

    static let `default` = ScannerEffectConfiguration(
        isEnabled: false,
        speed: 1.0,
        glowWidth: 0.15,
        intensity: 1.0,
        color: GradientColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 1.0),
        trailLength: 0.1
    )

    // MARK: - Persistence

    static let defaultsKey = "terminal.effects.scanner"

    static func load(from defaults: UserDefaults = .standard) -> ScannerEffectConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(ScannerEffectConfiguration.self, from: data)
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
