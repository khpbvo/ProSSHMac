// CursorEffects.swift
// ProSSHV2
//
// Cursor effect primitives: smooth blink, glow pulse, and lerp helpers.

import Foundation

enum CursorEffects {

    /// Smooth sinusoidal blink phase in [0, 1].
    static func blinkPhase(
        time: Float,
        halfPeriod: Float,
        visible: Bool,
        blinkEnabled: Bool
    ) -> Float {
        guard visible else { return 0 }
        guard blinkEnabled else { return 1 }
        let omega = Float.pi / max(0.001, halfPeriod)
        let value = (sinf(time * omega) + 1) * 0.5
        return min(1, max(0, value))
    }

    /// Glow pulse, slightly phase-shifted from blink.
    static func glowIntensity(
        time: Float,
        blinkPhase: Float,
        base: Float,
        pulseRange: Float,
        phaseOffset: Float
    ) -> Float {
        guard blinkPhase > 0 else { return 0 }
        let pulse = 0.5 + 0.5 * sinf(time * Float.pi + phaseOffset)
        let value = (base + pulseRange * pulse) * blinkPhase
        return min(1, max(0, value))
    }

    /// Linear interpolation helper.
    static func lerp(current: Float, target: Float, factor: Float) -> Float {
        current + (target - current) * min(1, max(0, factor))
    }
}
