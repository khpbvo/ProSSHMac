// SmoothScrollConfiguration.swift
// ProSSHV2
//
// Smooth scrolling effect configuration.
// Controls the CPU-side physics engine that provides sub-pixel smooth
// scrolling with spring interpolation and momentum decay.

import Foundation

// MARK: - SmoothScrollConfiguration

/// Configuration for the smooth scrolling physics engine.
///
/// When enabled, trackpad scroll gestures produce sub-pixel smooth movement
/// instead of discrete line-jumps. The engine uses spring interpolation to
/// snap fractional offsets back to integer row boundaries, and optionally
/// carries momentum after the trackpad is released.
struct SmoothScrollConfiguration: Codable, Sendable, Equatable {

    /// Master toggle — whether smooth scrolling is active.
    var isEnabled: Bool

    /// Lerp factor per frame for snapping the fractional offset back to zero.
    /// Higher values = snappier response (range: 0.15–0.50).
    var springStiffness: Float

    /// Momentum velocity multiplier per frame. Higher values = longer coast
    /// after trackpad release (range: 0.85–0.97).
    var friction: Float

    /// Whether to carry velocity after the trackpad is released.
    var momentumEnabled: Bool

    /// Velocity cap in rows/sec to prevent runaway scrolling.
    var maxVelocity: Float

    // MARK: - Defaults

    static let `default` = SmoothScrollConfiguration(
        isEnabled: true,
        springStiffness: 0.30,
        friction: 0.92,
        momentumEnabled: true,
        maxVelocity: 80.0
    )

    // MARK: - Persistence

    static let defaultsKey = "terminal.effects.smoothScroll"

    static func load(from defaults: UserDefaults = .standard) -> SmoothScrollConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(SmoothScrollConfiguration.self, from: data)
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
