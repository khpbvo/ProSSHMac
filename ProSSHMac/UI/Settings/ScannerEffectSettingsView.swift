// ScannerEffectSettingsView.swift
// ProSSHV2
//
// Settings UI for the Knight Rider KITT-style scanner glow effect.
// Provides a live preview, master toggle, and sliders for speed,
// glow width, intensity, trail length, and color.

import SwiftUI

struct ScannerEffectSettingsView: View {
    @State private var config: ScannerEffectConfiguration
    @Environment(\.dismiss) private var dismiss

    var onApply: ((ScannerEffectConfiguration) -> Void)?

    init(
        configuration: ScannerEffectConfiguration = .load(),
        onApply: ((ScannerEffectConfiguration) -> Void)? = nil
    ) {
        _config = State(initialValue: configuration)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    previewCard
                    masterToggle
                    if config.isEnabled {
                        colorSection
                        speedSection
                        glowSection
                    }
                }
                .padding()
            }
            .background(.background)
            .navigationTitle("Scanner Effect")
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
    private var previewCard: some View {
        let username = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()

        ScannerPreviewRenderer(config: config, username: username)
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: - Master Toggle

    @ViewBuilder
    private var masterToggle: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable Scanner Effect", isOn: $config.isEnabled)
                    .tint(.red)

                Text("Adds a Knight Rider-style sweeping glow across your username on the local terminal prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Color Section

    @ViewBuilder
    private var colorSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Glow Color")
                    .font(.headline)

                HStack {
                    Text("Scanner Color")
                        .font(.subheadline)
                    Spacer()
                    ColorPicker(
                        "",
                        selection: scannerColorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - Speed Section

    @ViewBuilder
    private var speedSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Animation")
                    .font(.headline)

                LabeledSlider(
                    label: "Speed",
                    value: $config.speed,
                    range: 0.2...3.0,
                    step: 0.1,
                    format: "%.1fx",
                    tintColor: .red
                )
            }
        }
    }

    // MARK: - Glow Section

    @ViewBuilder
    private var glowSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Glow")
                    .font(.headline)

                LabeledSlider(
                    label: "Width",
                    value: $config.glowWidth,
                    range: 0.05...0.4,
                    step: 0.01,
                    format: "%.0f%%",
                    displayMultiplier: 100,
                    tintColor: .red
                )

                LabeledSlider(
                    label: "Intensity",
                    value: $config.intensity,
                    range: 0.3...2.0,
                    step: 0.1,
                    format: "%.0f%%",
                    displayMultiplier: 100,
                    tintColor: .red
                )

                LabeledSlider(
                    label: "Trail Length",
                    value: $config.trailLength,
                    range: 0.0...0.5,
                    step: 0.01,
                    format: "%.0f%%",
                    displayMultiplier: 100,
                    tintColor: .red
                )
            }
        }
    }

    // MARK: - Color Binding

    private var scannerColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: Double(config.color.red),
                    green: Double(config.color.green),
                    blue: Double(config.color.blue)
                )
            },
            set: { newColor in
                config.color = GradientColor(newColor)
            }
        )
    }
}

// MARK: - Live Preview Renderer

/// Canvas-based CPU preview of the scanner sweep effect.
struct ScannerPreviewRenderer: View {
    let config: ScannerEffectConfiguration
    let username: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate

                // Background
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.black)
                )

                guard config.isEnabled else { return }

                let charWidth = size.width / max(CGFloat(username.count + 4), 1)
                let nameWidth = CGFloat(username.count) * charWidth
                let y = size.height / 2.0

                // Scanner position: ping-pong
                let progress = abs(fmod(elapsed * Double(config.speed) * 0.5, 1.0) * 2.0 - 1.0)
                let scanX = progress * Double(nameWidth)

                // Draw glow behind text
                for i in 0..<Int(nameWidth) {
                    let px = Double(i)
                    let dist = (px - scanX) / max(Double(nameWidth), 1.0)
                    let glow = exp(-dist * dist / (Double(config.glowWidth) * Double(config.glowWidth)))
                    let alpha = glow * Double(config.intensity) * 0.6

                    if alpha > 0.01 {
                        let rect = CGRect(x: px, y: y - 10, width: max(charWidth, 1), height: 20)
                        context.fill(
                            Path(rect),
                            with: .color(Color(
                                red: Double(config.color.red),
                                green: Double(config.color.green),
                                blue: Double(config.color.blue)
                            ).opacity(alpha))
                        )
                    }
                }

                // Draw username text
                let prompt = username + " ~ %"
                let font = Font.system(.body, design: .monospaced).weight(.medium)
                let text = context.resolve(Text(prompt).font(font).foregroundColor(.white))
                context.draw(text, at: CGPoint(x: nameWidth / 2 + charWidth, y: y), anchor: .center)
            }
        }
    }
}
