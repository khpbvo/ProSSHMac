// GradientBackgroundSettingsView.swift
// ProSSHV2
//
// Full-featured gradient background customization UI with live preview,
// preset gallery, color pickers, and per-parameter sliders.

import SwiftUI

// MARK: - GradientBackgroundSettingsView

struct GradientBackgroundSettingsView: View {
    @State private var config: GradientBackgroundConfiguration
    @State private var selectedPresetID: String?
    @State private var showingAdvanced = false
    @Environment(\.dismiss) private var dismiss

    /// Called when the user applies changes.
    var onApply: ((GradientBackgroundConfiguration) -> Void)?

    init(
        configuration: GradientBackgroundConfiguration = .load(),
        onApply: ((GradientBackgroundConfiguration) -> Void)? = nil
    ) {
        _config = State(initialValue: configuration)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    gradientPreviewCard
                    masterToggle
                    if config.isEnabled {
                        presetGallery
                        styleSection
                        colorSection
                        animationSection
                        effectsSection
                        if showingAdvanced {
                            advancedSection
                        }
                        advancedToggle
                    }
                }
                .padding()
            }
            .background(.background)
            .navigationTitle("Gradient Background")
            .iosInlineNavigationBarTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        config.save()
                        onApply?(config)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Preview Card

    @ViewBuilder
    private var gradientPreviewCard: some View {
        ZStack {
            if config.isEnabled {
                GradientPreviewRenderer(config: config)
            } else {
                Color.black
            }

            // Simulate terminal text overlay.
            VStack(alignment: .leading, spacing: 2) {
                Text("kevin@nuc ~ %")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.9))
                Text("ssh production-server")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Welcome to ProSSH v2")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.7))
                Text("Last login: Mon Feb 16 08:42")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                HStack(spacing: 0) {
                    Text("root@prod ~ # ")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.9))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.8))
                        .frame(width: 7, height: 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    // MARK: - Master Toggle

    @ViewBuilder
    private var masterToggle: some View {
        SettingsCard {
            Toggle("Enable Gradient Background", isOn: $config.isEnabled)
                .tint(.purple)
        }
    }

    // MARK: - Preset Gallery

    @ViewBuilder
    private var presetGallery: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Presets")
                .font(.headline)
                .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(GradientPreset.allPresets) { preset in
                        PresetThumbnail(
                            preset: preset,
                            isSelected: selectedPresetID == preset.id
                        ) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                config = preset.apply(to: config)
                                selectedPresetID = preset.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Style Section

    @ViewBuilder
    private var styleSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Gradient Style")
                    .font(.subheadline.weight(.semibold))

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 10) {
                    ForEach(GradientStyle.allCases) { style in
                        StyleButton(
                            style: style,
                            isSelected: config.style == style
                        ) {
                            withAnimation { config.style = style }
                            selectedPresetID = nil
                        }
                    }
                }

                if config.style == .linear || config.style == .angular {
                    LabeledSlider(
                        label: "Angle",
                        value: $config.angle,
                        range: -180...180,
                        step: 5,
                        format: "%.0f\u{00B0}"
                    )
                }
            }
        }
    }

    // MARK: - Color Section

    @ViewBuilder
    private var colorSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Colors")
                    .font(.subheadline.weight(.semibold))

                GradientColorPicker(label: "Primary", color: $config.color1)
                GradientColorPicker(label: "Secondary", color: $config.color2)

                Toggle("Multi-Stop", isOn: $config.useMultipleStops)
                    .tint(.purple)

                if config.useMultipleStops {
                    GradientColorPicker(label: "Tertiary", color: $config.color3)
                    GradientColorPicker(label: "Quaternary", color: $config.color4)
                }
            }
        }
    }

    // MARK: - Animation Section

    @ViewBuilder
    private var animationSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Animation")
                    .font(.subheadline.weight(.semibold))

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 10) {
                    ForEach(GradientAnimationMode.allCases) { mode in
                        AnimationModeButton(
                            mode: mode,
                            isSelected: config.animationMode == mode
                        ) {
                            withAnimation { config.animationMode = mode }
                            selectedPresetID = nil
                        }
                    }
                }

                if config.animationMode != .none {
                    LabeledSlider(
                        label: "Speed",
                        value: $config.animationSpeed,
                        range: 0.1...3.0,
                        step: 0.1,
                        format: "%.1f\u{00D7}"
                    )
                }
            }
        }
    }

    // MARK: - Effects Section

    @ViewBuilder
    private var effectsSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Effects")
                    .font(.subheadline.weight(.semibold))

                LabeledSlider(
                    label: "Glow Intensity",
                    value: $config.glowIntensity,
                    range: 0...1,
                    step: 0.05,
                    format: "%.0f%%",
                    displayMultiplier: 100
                )

                if config.glowIntensity > 0 {
                    GradientColorPicker(label: "Glow Color", color: $config.glowColor)

                    LabeledSlider(
                        label: "Glow Radius",
                        value: $config.glowRadius,
                        range: 0.1...1.5,
                        step: 0.05,
                        format: "%.0f%%",
                        displayMultiplier: 100
                    )
                }

                LabeledSlider(
                    label: "Vignette",
                    value: $config.vignetteIntensity,
                    range: 0...1,
                    step: 0.05,
                    format: "%.0f%%",
                    displayMultiplier: 100
                )

                LabeledSlider(
                    label: "Film Grain",
                    value: $config.noiseIntensity,
                    range: 0...0.15,
                    step: 0.005,
                    format: "%.0f%%",
                    displayMultiplier: 100 / 0.15
                )

                LabeledSlider(
                    label: "Cell Transparency",
                    value: $config.cellBlendOpacity,
                    range: 0...0.5,
                    step: 0.01,
                    format: "%.0f%%",
                    displayMultiplier: 200
                )
            }
        }
    }

    // MARK: - Advanced Section

    @ViewBuilder
    private var advancedToggle: some View {
        Button {
            withAnimation { showingAdvanced.toggle() }
        } label: {
            HStack {
                Text(showingAdvanced ? "Hide Advanced" : "Show Advanced")
                    .font(.subheadline)
                Image(systemName: showingAdvanced ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Color Adjustments")
                    .font(.subheadline.weight(.semibold))

                LabeledSlider(
                    label: "Saturation",
                    value: $config.saturation,
                    range: 0...2.5,
                    step: 0.05,
                    format: "%.0f%%",
                    displayMultiplier: 100
                )

                LabeledSlider(
                    label: "Brightness",
                    value: $config.brightness,
                    range: -0.3...0.3,
                    step: 0.01,
                    format: "%+.0f%%",
                    displayMultiplier: 100
                )

                LabeledSlider(
                    label: "Contrast",
                    value: $config.contrast,
                    range: 0.5...2.0,
                    step: 0.05,
                    format: "%.0f%%",
                    displayMultiplier: 100
                )
            }
        }

        SettingsCard {
            Button(role: .destructive) {
                withAnimation {
                    config = .default
                    config.isEnabled = true
                    selectedPresetID = nil
                }
            } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
        }
    }
}

// MARK: - Supporting Views

/// Card container for settings sections.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Preset thumbnail with mini gradient preview.
private struct PresetThumbnail: View {
    let preset: GradientPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    GradientPreviewRenderer(config: preset.configuration)
                        .frame(width: 64, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.white, lineWidth: 2)
                            .frame(width: 64, height: 48)
                    }
                }
                .shadow(color: isSelected ? .purple.opacity(0.5) : .clear, radius: 4)

                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Gradient style selection button.
private struct StyleButton: View {
    let style: GradientStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: style.iconName)
                    .font(.title3)
                Text(style.title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? Color.purple.opacity(0.2) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.purple : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .purple : .secondary)
    }
}

/// Animation mode selection button.
private struct AnimationModeButton: View {
    let mode: GradientAnimationMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.iconName)
                    .font(.title3)
                Text(mode.title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? Color.purple.opacity(0.2) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.purple : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .purple : .secondary)
    }
}

/// Color picker row with label and inline ColorPicker.
private struct GradientColorPicker: View {
    let label: String
    @Binding var color: GradientColor

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            ColorPicker(
                "",
                selection: colorBinding,
                supportsOpacity: false
            )
            .labelsHidden()
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { color.color },
            set: { color = GradientColor($0) }
        )
    }
}

/// Labeled slider with value display.
struct LabeledSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let format: String
    var displayMultiplier: Float = 1
    var tintColor: Color = .purple

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(String(format: format, Double(value * displayMultiplier)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: floatBinding,
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .tint(tintColor)
        }
    }

    private var floatBinding: Binding<Double> {
        Binding(
            get: { Double(value) },
            set: { value = Float($0) }
        )
    }
}

// MARK: - SwiftUI Gradient Preview (CPU fallback for settings UI)

/// A simple SwiftUI gradient preview that approximates the Metal shader output.
/// Used in the settings UI for real-time feedback without requiring Metal setup.
struct GradientPreviewRenderer: View {
    let config: GradientBackgroundConfiguration

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                drawGradient(in: &context, size: size)
                drawGlow(in: &context, size: size, time: time)
                drawVignette(in: &context, size: size)
            }
        }
    }

    // MARK: - Drawing Helpers

    private func buildGradient() -> Gradient {
        let color1 = config.color1.color
        let color2 = config.color2.color
        if config.useMultipleStops {
            return Gradient(colors: [color1, config.color3.color, config.color4.color, color2])
        }
        return Gradient(colors: [color1, color2])
    }

    private func drawGradient(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let gradient = buildGradient()
        let angle = Angle(degrees: Double(config.angle))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let path = Path(rect)

        switch config.style {
        case .linear:
            let dx = sin(angle.radians) * size.height / 2
            let dy = cos(angle.radians) * size.height / 2
            let start = CGPoint(x: center.x - dx, y: center.y - dy)
            let end = CGPoint(x: center.x + dx, y: center.y + dy)
            context.fill(path, with: .linearGradient(gradient, startPoint: start, endPoint: end))
        case .radial:
            let endRadius = max(size.width, size.height) * 0.6
            context.fill(path, with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: endRadius))
        case .angular:
            context.fill(path, with: .conicGradient(gradient, center: center, angle: angle))
        case .diamond, .mesh:
            let start = CGPoint(x: 0, y: 0)
            let end = CGPoint(x: size.width, y: size.height)
            context.fill(path, with: .linearGradient(gradient, startPoint: start, endPoint: end))
        }
    }

    private func drawGlow(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard config.glowIntensity > 0 else { return }
        let glowColor = config.glowColor.color.opacity(Double(config.glowIntensity) * 0.6)
        let breathe: Double = config.animationMode != .none
            ? (1.0 + sin(time * 2.0 * Double(config.animationSpeed)) * 0.15)
            : 1.0
        let radius = Double(config.glowRadius) * Double(max(size.width, size.height)) * 0.5 * breathe
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ellipseRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let ellipsePath = Path(ellipseIn: ellipseRect)
        let grad = Gradient(colors: [glowColor, .clear])
        context.fill(ellipsePath, with: .radialGradient(grad, center: center, startRadius: 0, endRadius: radius))
    }

    private func drawVignette(in context: inout GraphicsContext, size: CGSize) {
        guard config.vignetteIntensity > 0 else { return }
        let rect = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let edgeColor = Color.black.opacity(Double(config.vignetteIntensity) * 0.7)
        let grad = Gradient(colors: [.clear, edgeColor])
        let innerRadius = min(size.width, size.height) * 0.3
        let outerRadius = max(size.width, size.height) * 0.7
        context.fill(Path(rect), with: .radialGradient(grad, center: center, startRadius: innerRadius, endRadius: outerRadius))
    }
}
