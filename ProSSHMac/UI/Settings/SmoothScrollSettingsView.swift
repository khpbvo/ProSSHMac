// SmoothScrollSettingsView.swift
// ProSSHV2
//
// Settings UI for smooth scrolling physics configuration.

import SwiftUI

struct SmoothScrollSettingsView: View {
    @State private var config: SmoothScrollConfiguration
    @Environment(\.dismiss) private var dismiss
    var onApply: ((SmoothScrollConfiguration) -> Void)?

    init(
        configuration: SmoothScrollConfiguration = .load(),
        onApply: ((SmoothScrollConfiguration) -> Void)? = nil
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
                        momentumToggle
                        stiffnessSection
                        frictionSection
                        velocitySection
                    }
                }
                .padding()
            }
            .background(.background)
            .navigationTitle("Smooth Scrolling")
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
                Toggle("Enable Smooth Scrolling", isOn: $config.isEnabled)
                    .tint(.mint)
                Text("Replaces discrete line-jumps with sub-pixel smooth movement using spring physics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Momentum Toggle

    @ViewBuilder
    private var momentumToggle: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Momentum", isOn: $config.momentumEnabled)
                    .tint(.mint)
                Text("Carry velocity after the trackpad is released for a natural coasting feel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Spring Stiffness

    @ViewBuilder
    private var stiffnessSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Spring Stiffness").font(.headline)
                LabeledSlider(
                    label: "Stiffness",
                    value: $config.springStiffness,
                    range: 0.15...0.50,
                    step: 0.01,
                    format: "%.2f",
                    tintColor: .mint
                )
                Text("How quickly the fractional offset snaps back to an integer row. Higher = snappier.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Momentum Friction

    @ViewBuilder
    private var frictionSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Momentum Friction").font(.headline)
                LabeledSlider(
                    label: "Friction",
                    value: $config.friction,
                    range: 0.85...0.97,
                    step: 0.01,
                    format: "%.2f",
                    tintColor: .mint
                )
                Text("Velocity multiplier per frame during momentum. Higher = longer coast.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Max Velocity

    @ViewBuilder
    private var velocitySection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Max Velocity").font(.headline)
                LabeledSlider(
                    label: "Max Velocity",
                    value: $config.maxVelocity,
                    range: 20...200,
                    step: 5,
                    format: "%.0f rows/s",
                    tintColor: .mint
                )
                Text("Velocity cap to prevent runaway scrolling.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
