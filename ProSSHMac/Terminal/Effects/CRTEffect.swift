// CRTEffect.swift
// ProSSHV2
//
// CRT post-processing configuration and math helpers.

import Foundation

struct CRTEffectConfiguration: Sendable {
    var isEnabled: Bool
    var scanlineOpacity: Float
    var scanlineDensity: Float
    var barrelDistortion: Float
    var phosphorPersistence: Float

    static let `default` = CRTEffectConfiguration(
        isEnabled: false,
        scanlineOpacity: 0.16,
        scanlineDensity: 1.8,
        barrelDistortion: 0.055,
        phosphorPersistence: 0.90
    )
}

enum CRTEffect {
    nonisolated static let enabledDefaultsKey = "terminal.effects.crtEnabled"

    nonisolated static func loadEnabledFromDefaults(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledDefaultsKey) as? Bool) ?? false
    }

    nonisolated static func clamp(_ value: Float, min lower: Float = 0, max upper: Float = 1) -> Float {
        Swift.max(lower, Swift.min(upper, value))
    }

    /// Convert phosphor persistence to a frame-rate independent blend multiplier.
    nonisolated static func phosphorBlend(
        persistence: Float,
        frameDeltaSeconds: Float,
        referenceFPS: Float = 60
    ) -> Float {
        let p = clamp(persistence, min: 0, max: 0.999)
        let dt = Swift.max(0, frameDeltaSeconds)
        let equivalentFrames = dt * Swift.max(1, referenceFPS)
        return powf(p, equivalentFrames)
    }
}
