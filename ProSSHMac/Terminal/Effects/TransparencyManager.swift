// TransparencyManager.swift
// ProSSHV2
//
// Shared terminal background transparency settings utilities.

import Foundation

enum TransparencyManager {
    nonisolated static let backgroundOpacityKey = "terminal.effects.backgroundOpacityPercent"
    nonisolated static let defaultBackgroundOpacityPercent: Double = 100

    nonisolated static func clampBackgroundOpacityPercent(_ value: Double) -> Double {
        Swift.max(0, Swift.min(100, value))
    }

    nonisolated static func normalizedOpacity(fromPercent percent: Double) -> Double {
        clampBackgroundOpacityPercent(percent) / 100.0
    }

    nonisolated static func loadBackgroundOpacityPercent(_ defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: backgroundOpacityKey) != nil else {
            return defaultBackgroundOpacityPercent
        }
        return clampBackgroundOpacityPercent(defaults.double(forKey: backgroundOpacityKey))
    }
}
