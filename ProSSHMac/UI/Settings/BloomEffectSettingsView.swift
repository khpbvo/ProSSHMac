// BloomEffectSettingsView.swift
// ProSSHV2
//
// Settings UI for the bloom / text glow post-process effect.

import SwiftUI

struct BloomEffectSettingsView: View {
    @State private var config: BloomEffectConfiguration
    @Environment(\.dismiss) private var dismiss
    var onApply: ((BloomEffectConfiguration) -> Void)?

    init(
        configuration: BloomEffectConfiguration = .load(),
        onApply: ((BloomEffectConfiguration) -> Void)? = nil
    ) {
        _config = State(initialValue: configuration)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    masterToggle
                    if config.isEnabled {
                        thresholdSection
                        intensitySection
                        radiusSection
                        gradientCouplingSection
                    }
                }
                .padding()
            }
            .background(.background)
            .navigationTitle("Text Glow")
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

    // MARK: - Master Toggle

    @ViewBuilder
    private var masterToggle: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Text Glow", isOn: $config.isEnabled)
                    .tint(.cyan)
                Text("Adds a soft glow halo around bright terminal text using a multi-pass bloom filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Threshold

    @ViewBuilder
    private var thresholdSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Brightness Cutoff").font(.headline)
                LabeledSlider(
                    label: "Threshold",
                    value: $config.threshold,
                    range: 0.1...0.9,
                    step: 0.05,
                    format: "%.0f%%",
                    displayMultiplier: 100,
                    tintColor: .cyan
                )
                Text("Lower values cause more text to glow. Default: 45%.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Intensity

    @ViewBuilder
    private var intensitySection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Glow Strength").font(.headline)
                LabeledSlider(
                    label: "Intensity",
                    value: $config.intensity,
                    range: 0.0...1.5,
                    step: 0.05,
                    format: "%.0f%%",
                    displayMultiplier: 100,
                    tintColor: .cyan
                )
            }
        }
    }

    // MARK: - Radius

    @ViewBuilder
    private var radiusSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Blur Radius").font(.headline)
                LabeledSlider(
                    label: "Radius",
                    value: $config.radius,
                    range: 0.5...3.0,
                    step: 0.1,
                    format: "%.1fx",
                    tintColor: .cyan
                )
            }
        }
    }

    // MARK: - Gradient Coupling

    @ViewBuilder
    private var gradientCouplingSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Pulse with Gradient Animation", isOn: $config.animateWithGradient)
                    .tint(.cyan)
                Text("When a gradient background animation is active, the bloom intensity and radius pulse in sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
