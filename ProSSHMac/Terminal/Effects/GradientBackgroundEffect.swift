// GradientBackgroundEffect.swift
// ProSSHV2
//
// Animated gradient background effect configuration and presets.
// Renders a GPU-accelerated gradient behind terminal cells with
// optional glow, animation, noise grain, and vignette effects.

import Foundation
import SwiftUI
import AppKit

// MARK: - GradientStyle

/// The shape of the gradient blending.
enum GradientStyle: Int, CaseIterable, Identifiable, Codable, Sendable {
    case linear = 0
    case radial = 1
    case angular = 2
    case diamond = 3
    case mesh = 4          // multi-point organic blending

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .linear:  return "Linear"
        case .radial:  return "Radial"
        case .angular: return "Angular"
        case .diamond: return "Diamond"
        case .mesh:    return "Mesh"
        }
    }

    var iconName: String {
        switch self {
        case .linear:  return "arrow.up.arrow.down"
        case .radial:  return "circle"
        case .angular: return "dial.low"
        case .diamond: return "diamond"
        case .mesh:    return "circle.grid.cross"
        }
    }
}

// MARK: - GradientAnimationMode

/// How the gradient animates over time.
enum GradientAnimationMode: Int, CaseIterable, Identifiable, Codable, Sendable {
    case none = 0           // static gradient
    case breathe = 1        // subtle pulsing intensity
    case shift = 2          // colors slowly rotate/shift
    case wave = 3           // undulating wave distortion
    case aurora = 4         // organic aurora-like movement

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none:    return "Static"
        case .breathe: return "Breathe"
        case .shift:   return "Color Shift"
        case .wave:    return "Wave"
        case .aurora:  return "Aurora"
        }
    }

    var iconName: String {
        switch self {
        case .none:    return "pause.circle"
        case .breathe: return "wind"
        case .shift:   return "paintpalette"
        case .wave:    return "water.waves"
        case .aurora:  return "sparkles"
        }
    }
}

// MARK: - GradientColor

/// A serializable RGBA color for gradient stops.
struct GradientColor: Codable, Sendable, Equatable, Hashable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    init(red: Float, green: Float, blue: Float, alpha: Float = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let resolved = NSColor(color)
        var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Float(r)
        self.green = Float(g)
        self.blue = Float(b)
        self.alpha = Float(a)
    }

    var color: Color {
        Color(red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
    }

    var packed: UInt32 {
        let r = UInt32(max(0, min(255, red * 255)))
        let g = UInt32(max(0, min(255, green * 255)))
        let b = UInt32(max(0, min(255, blue * 255)))
        let a = UInt32(max(0, min(255, alpha * 255)))
        return (r << 24) | (g << 16) | (b << 8) | a
    }

    static let black = GradientColor(red: 0, green: 0, blue: 0)
    static let white = GradientColor(red: 1, green: 1, blue: 1)
}

// MARK: - GradientBackgroundConfiguration

/// Complete configuration for the animated gradient background effect.
/// Persisted to UserDefaults via JSON encoding.
struct GradientBackgroundConfiguration: Codable, Sendable, Equatable {
    /// Master toggle.
    var isEnabled: Bool

    /// Gradient style (linear, radial, angular, diamond, mesh).
    var style: GradientStyle

    /// Primary color (top / center / start).
    var color1: GradientColor

    /// Secondary color (bottom / edge / end).
    var color2: GradientColor

    /// Tertiary color for mesh/multi-stop gradients.
    var color3: GradientColor

    /// Fourth color for mesh gradients.
    var color4: GradientColor

    /// Whether to use the tertiary and quaternary colors.
    var useMultipleStops: Bool

    /// Gradient angle in degrees (0 = vertical top-to-bottom, 90 = left-to-right).
    var angle: Float

    /// Animation mode.
    var animationMode: GradientAnimationMode

    /// Animation speed multiplier (0.1 = very slow, 1.0 = normal, 3.0 = fast).
    var animationSpeed: Float

    /// Glow effect intensity around center/focal point (0.0 = off, 1.0 = max).
    var glowIntensity: Float

    /// Glow color. Uses a blend of the gradient colors if nil.
    var glowColor: GradientColor

    /// Glow radius as fraction of viewport (0.1 = tight, 1.0 = wide).
    var glowRadius: Float

    /// Film grain / noise intensity (0.0 = off, 1.0 = heavy).
    var noiseIntensity: Float

    /// Vignette darkness around edges (0.0 = off, 1.0 = strong).
    var vignetteIntensity: Float

    /// How much the terminal cell backgrounds blend with the gradient.
    /// 0.0 = cells are fully opaque (gradient only visible where no cells).
    /// 1.0 = cells are fully transparent (gradient shows through everything).
    var cellBlendOpacity: Float

    /// Saturation boost/reduction (0.0 = grayscale, 1.0 = normal, 2.0 = vivid).
    var saturation: Float

    /// Brightness adjustment (-0.5 to 0.5, 0 = normal).
    var brightness: Float

    /// Contrast adjustment (0.5 to 2.0, 1.0 = normal).
    var contrast: Float

    // MARK: - Defaults

    static let `default` = GradientBackgroundConfiguration(
        isEnabled: false,
        style: .linear,
        color1: GradientColor(red: 0.29, green: 0.0, blue: 0.51),       // #4B0082 indigo
        color2: GradientColor(red: 0.10, green: 0.0, blue: 0.20),       // deep purple
        color3: GradientColor(red: 0.0, green: 0.15, blue: 0.40),       // deep blue
        color4: GradientColor(red: 0.05, green: 0.0, blue: 0.15),       // near black
        useMultipleStops: false,
        angle: 0,
        animationMode: .breathe,
        animationSpeed: 1.0,
        glowIntensity: 0.3,
        glowColor: GradientColor(red: 0.5, green: 0.2, blue: 0.8),
        glowRadius: 0.5,
        noiseIntensity: 0.02,
        vignetteIntensity: 0.3,
        cellBlendOpacity: 0.15,
        saturation: 1.0,
        brightness: 0.0,
        contrast: 1.0
    )
}

// MARK: - GradientPreset

/// Pre-designed gradient themes for one-tap application.
struct GradientPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let iconName: String
    let configuration: GradientBackgroundConfiguration

    /// Apply this preset to a configuration, preserving user's animation speed
    /// and cell blend preferences.
    func apply(to existing: GradientBackgroundConfiguration) -> GradientBackgroundConfiguration {
        var config = configuration
        config.isEnabled = true
        config.animationSpeed = existing.animationSpeed
        config.cellBlendOpacity = existing.cellBlendOpacity
        return config
    }
}

// MARK: - Built-in Presets

extension GradientPreset {
    static let allPresets: [GradientPreset] = [
        royalPurple,
        midnightAurora,
        oceanDeep,
        solarFlare,
        cyberNeon,
        frostedMint,
        bloodMoon,
        twilightHaze,
        matrixGreen,
        cosmicDust,
        goldenHour,
        arcticIce,
    ]

    static let royalPurple = GradientPreset(
        id: "royal_purple",
        name: "Royal Purple",
        iconName: "crown",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .linear,
            color1: GradientColor(red: 0.29, green: 0.0, blue: 0.51),
            color2: GradientColor(red: 0.10, green: 0.0, blue: 0.20),
            color3: GradientColor(red: 0.15, green: 0.0, blue: 0.35),
            color4: GradientColor(red: 0.05, green: 0.0, blue: 0.10),
            useMultipleStops: false,
            angle: 0,
            animationMode: .breathe,
            animationSpeed: 0.8,
            glowIntensity: 0.35,
            glowColor: GradientColor(red: 0.55, green: 0.15, blue: 0.85),
            glowRadius: 0.5,
            noiseIntensity: 0.02,
            vignetteIntensity: 0.35,
            cellBlendOpacity: 0.15,
            saturation: 1.2,
            brightness: 0.0,
            contrast: 1.05
        )
    )

    static let midnightAurora = GradientPreset(
        id: "midnight_aurora",
        name: "Midnight Aurora",
        iconName: "sparkles",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .mesh,
            color1: GradientColor(red: 0.0, green: 0.35, blue: 0.25),
            color2: GradientColor(red: 0.15, green: 0.0, blue: 0.35),
            color3: GradientColor(red: 0.0, green: 0.15, blue: 0.30),
            color4: GradientColor(red: 0.02, green: 0.02, blue: 0.05),
            useMultipleStops: true,
            angle: 15,
            animationMode: .aurora,
            animationSpeed: 0.6,
            glowIntensity: 0.25,
            glowColor: GradientColor(red: 0.1, green: 0.6, blue: 0.4),
            glowRadius: 0.6,
            noiseIntensity: 0.03,
            vignetteIntensity: 0.25,
            cellBlendOpacity: 0.12,
            saturation: 1.3,
            brightness: 0.0,
            contrast: 1.1
        )
    )

    static let oceanDeep = GradientPreset(
        id: "ocean_deep",
        name: "Ocean Deep",
        iconName: "water.waves",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .radial,
            color1: GradientColor(red: 0.0, green: 0.20, blue: 0.40),
            color2: GradientColor(red: 0.0, green: 0.05, blue: 0.15),
            color3: GradientColor(red: 0.0, green: 0.10, blue: 0.25),
            color4: GradientColor(red: 0.0, green: 0.0, blue: 0.08),
            useMultipleStops: false,
            angle: 0,
            animationMode: .wave,
            animationSpeed: 0.5,
            glowIntensity: 0.20,
            glowColor: GradientColor(red: 0.0, green: 0.35, blue: 0.65),
            glowRadius: 0.55,
            noiseIntensity: 0.015,
            vignetteIntensity: 0.40,
            cellBlendOpacity: 0.10,
            saturation: 1.1,
            brightness: 0.0,
            contrast: 1.0
        )
    )

    static let solarFlare = GradientPreset(
        id: "solar_flare",
        name: "Solar Flare",
        iconName: "sun.max",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .radial,
            color1: GradientColor(red: 0.60, green: 0.20, blue: 0.0),
            color2: GradientColor(red: 0.20, green: 0.02, blue: 0.0),
            color3: GradientColor(red: 0.40, green: 0.10, blue: 0.0),
            color4: GradientColor(red: 0.08, green: 0.0, blue: 0.0),
            useMultipleStops: false,
            angle: 0,
            animationMode: .breathe,
            animationSpeed: 0.7,
            glowIntensity: 0.45,
            glowColor: GradientColor(red: 0.9, green: 0.4, blue: 0.1),
            glowRadius: 0.45,
            noiseIntensity: 0.025,
            vignetteIntensity: 0.50,
            cellBlendOpacity: 0.10,
            saturation: 1.4,
            brightness: 0.0,
            contrast: 1.15
        )
    )

    static let cyberNeon = GradientPreset(
        id: "cyber_neon",
        name: "Cyber Neon",
        iconName: "bolt",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .angular,
            color1: GradientColor(red: 0.0, green: 0.8, blue: 0.8),
            color2: GradientColor(red: 0.6, green: 0.0, blue: 0.6),
            color3: GradientColor(red: 0.0, green: 0.0, blue: 0.0),
            color4: GradientColor(red: 0.1, green: 0.0, blue: 0.2),
            useMultipleStops: true,
            angle: 45,
            animationMode: .shift,
            animationSpeed: 1.2,
            glowIntensity: 0.50,
            glowColor: GradientColor(red: 0.0, green: 0.9, blue: 0.9),
            glowRadius: 0.35,
            noiseIntensity: 0.04,
            vignetteIntensity: 0.45,
            cellBlendOpacity: 0.08,
            saturation: 1.5,
            brightness: -0.05,
            contrast: 1.2
        )
    )

    static let frostedMint = GradientPreset(
        id: "frosted_mint",
        name: "Frosted Mint",
        iconName: "leaf",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .linear,
            color1: GradientColor(red: 0.10, green: 0.30, blue: 0.25),
            color2: GradientColor(red: 0.02, green: 0.10, blue: 0.12),
            color3: GradientColor(red: 0.0, green: 0.20, blue: 0.18),
            color4: GradientColor(red: 0.0, green: 0.05, blue: 0.05),
            useMultipleStops: false,
            angle: 20,
            animationMode: .breathe,
            animationSpeed: 0.5,
            glowIntensity: 0.15,
            glowColor: GradientColor(red: 0.3, green: 0.8, blue: 0.6),
            glowRadius: 0.6,
            noiseIntensity: 0.01,
            vignetteIntensity: 0.20,
            cellBlendOpacity: 0.12,
            saturation: 1.0,
            brightness: 0.0,
            contrast: 1.0
        )
    )

    static let bloodMoon = GradientPreset(
        id: "blood_moon",
        name: "Blood Moon",
        iconName: "moon",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .radial,
            color1: GradientColor(red: 0.45, green: 0.02, blue: 0.02),
            color2: GradientColor(red: 0.10, green: 0.0, blue: 0.0),
            color3: GradientColor(red: 0.25, green: 0.0, blue: 0.05),
            color4: GradientColor(red: 0.03, green: 0.0, blue: 0.0),
            useMultipleStops: false,
            angle: 0,
            animationMode: .breathe,
            animationSpeed: 0.4,
            glowIntensity: 0.35,
            glowColor: GradientColor(red: 0.8, green: 0.1, blue: 0.05),
            glowRadius: 0.4,
            noiseIntensity: 0.03,
            vignetteIntensity: 0.55,
            cellBlendOpacity: 0.10,
            saturation: 1.3,
            brightness: -0.05,
            contrast: 1.1
        )
    )

    static let twilightHaze = GradientPreset(
        id: "twilight_haze",
        name: "Twilight Haze",
        iconName: "sunset",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .linear,
            color1: GradientColor(red: 0.35, green: 0.15, blue: 0.45),
            color2: GradientColor(red: 0.15, green: 0.10, blue: 0.30),
            color3: GradientColor(red: 0.45, green: 0.20, blue: 0.30),
            color4: GradientColor(red: 0.05, green: 0.02, blue: 0.10),
            useMultipleStops: true,
            angle: -20,
            animationMode: .shift,
            animationSpeed: 0.4,
            glowIntensity: 0.20,
            glowColor: GradientColor(red: 0.6, green: 0.3, blue: 0.5),
            glowRadius: 0.7,
            noiseIntensity: 0.02,
            vignetteIntensity: 0.30,
            cellBlendOpacity: 0.15,
            saturation: 1.1,
            brightness: 0.0,
            contrast: 1.0
        )
    )

    static let matrixGreen = GradientPreset(
        id: "matrix_green",
        name: "Matrix",
        iconName: "chevron.left.forwardslash.chevron.right",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .linear,
            color1: GradientColor(red: 0.0, green: 0.15, blue: 0.0),
            color2: GradientColor(red: 0.0, green: 0.03, blue: 0.0),
            color3: GradientColor(red: 0.0, green: 0.08, blue: 0.02),
            color4: GradientColor(red: 0.0, green: 0.0, blue: 0.0),
            useMultipleStops: false,
            angle: 0,
            animationMode: .wave,
            animationSpeed: 0.8,
            glowIntensity: 0.30,
            glowColor: GradientColor(red: 0.0, green: 0.9, blue: 0.2),
            glowRadius: 0.3,
            noiseIntensity: 0.05,
            vignetteIntensity: 0.60,
            cellBlendOpacity: 0.08,
            saturation: 1.6,
            brightness: 0.0,
            contrast: 1.3
        )
    )

    static let cosmicDust = GradientPreset(
        id: "cosmic_dust",
        name: "Cosmic Dust",
        iconName: "staroflife",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .mesh,
            color1: GradientColor(red: 0.20, green: 0.05, blue: 0.30),
            color2: GradientColor(red: 0.05, green: 0.08, blue: 0.25),
            color3: GradientColor(red: 0.30, green: 0.05, blue: 0.15),
            color4: GradientColor(red: 0.02, green: 0.02, blue: 0.08),
            useMultipleStops: true,
            angle: 30,
            animationMode: .aurora,
            animationSpeed: 0.3,
            glowIntensity: 0.20,
            glowColor: GradientColor(red: 0.4, green: 0.2, blue: 0.6),
            glowRadius: 0.8,
            noiseIntensity: 0.04,
            vignetteIntensity: 0.35,
            cellBlendOpacity: 0.12,
            saturation: 1.2,
            brightness: 0.0,
            contrast: 1.05
        )
    )

    static let goldenHour = GradientPreset(
        id: "golden_hour",
        name: "Golden Hour",
        iconName: "sun.horizon",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .linear,
            color1: GradientColor(red: 0.45, green: 0.30, blue: 0.05),
            color2: GradientColor(red: 0.15, green: 0.08, blue: 0.02),
            color3: GradientColor(red: 0.35, green: 0.15, blue: 0.0),
            color4: GradientColor(red: 0.05, green: 0.02, blue: 0.0),
            useMultipleStops: false,
            angle: -10,
            animationMode: .breathe,
            animationSpeed: 0.5,
            glowIntensity: 0.30,
            glowColor: GradientColor(red: 0.9, green: 0.7, blue: 0.2),
            glowRadius: 0.5,
            noiseIntensity: 0.015,
            vignetteIntensity: 0.30,
            cellBlendOpacity: 0.10,
            saturation: 1.3,
            brightness: 0.0,
            contrast: 1.05
        )
    )

    static let arcticIce = GradientPreset(
        id: "arctic_ice",
        name: "Arctic Ice",
        iconName: "snowflake",
        configuration: GradientBackgroundConfiguration(
            isEnabled: true,
            style: .linear,
            color1: GradientColor(red: 0.15, green: 0.25, blue: 0.40),
            color2: GradientColor(red: 0.03, green: 0.08, blue: 0.15),
            color3: GradientColor(red: 0.10, green: 0.20, blue: 0.30),
            color4: GradientColor(red: 0.0, green: 0.02, blue: 0.05),
            useMultipleStops: false,
            angle: 0,
            animationMode: .breathe,
            animationSpeed: 0.3,
            glowIntensity: 0.20,
            glowColor: GradientColor(red: 0.5, green: 0.7, blue: 1.0),
            glowRadius: 0.6,
            noiseIntensity: 0.02,
            vignetteIntensity: 0.25,
            cellBlendOpacity: 0.12,
            saturation: 0.9,
            brightness: 0.0,
            contrast: 1.0
        )
    )
}

// MARK: - Persistence

extension GradientBackgroundConfiguration {
    static let defaultsKey = "terminal.effects.gradientBackground"

    static func load(from defaults: UserDefaults = .standard) -> GradientBackgroundConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(GradientBackgroundConfiguration.self, from: data) else {
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
