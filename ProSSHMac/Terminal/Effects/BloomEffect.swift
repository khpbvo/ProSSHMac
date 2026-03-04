// BloomEffect.swift
// ProSSHV2
//
// Bloom (text glow) effect configuration.
// Applies a GPU bloom post-process that extracts bright terminal pixels,
// blurs them at half resolution, and additively composites the halo back.

import Foundation

// MARK: - BloomEffectConfiguration

/// Configuration for the bloom / text glow post-process effect.
///
/// When enabled, luminant terminal pixels above `threshold` receive a soft
/// glow halo whose strength and spread are controlled by `intensity` and
/// `radius`. The bloom can optionally pulse in sync with the gradient
/// background animation.
struct BloomEffectConfiguration: Codable, Sendable, Equatable {

    /// Master toggle — whether the bloom glow effect is active.
    var isEnabled: Bool

    /// Luminance cutoff above which pixels contribute to bloom (0.0–1.0).
    var threshold: Float

    /// Additive blend strength of the bloom halo (0.0–1.5).
    var intensity: Float

    /// Blur sigma multiplier controlling glow spread (0.5–3.0).
    var radius: Float

    /// When true, bloom intensity pulses in sync with gradient animation.
    var animateWithGradient: Bool

    // MARK: - Defaults

    static let `default` = BloomEffectConfiguration(
        isEnabled: false,
        threshold: 0.45,
        intensity: 0.65,
        radius: 1.5,
        animateWithGradient: true
    )

    // MARK: - Persistence

    static let defaultsKey = "terminal.effects.bloom"

    static func load(from defaults: UserDefaults = .standard) -> BloomEffectConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(BloomEffectConfiguration.self, from: data)
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
