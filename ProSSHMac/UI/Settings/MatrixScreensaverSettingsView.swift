// MatrixScreensaverSettingsView.swift
// ProSSHV2
//
// Settings UI for the Matrix-style falling character screensaver.
// Provides a live preview, master toggle, idle timeout picker,
// and sliders for speed, density, trail length, and color.

import SwiftUI

struct MatrixScreensaverSettingsView: View {
    @State private var config: MatrixScreensaverConfiguration
    @Environment(\.dismiss) private var dismiss

    var onApply: ((MatrixScreensaverConfiguration) -> Void)?

    init(
        configuration: MatrixScreensaverConfiguration = .load(),
        onApply: ((MatrixScreensaverConfiguration) -> Void)? = nil
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
                        timeoutSection
                        colorSection
                        animationSection
                        characterSection
                    }
                }
                .padding()
            }
            .background(.background)
            .navigationTitle("Matrix Screensaver")
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
        MatrixPreviewRenderer(config: config)
            .frame(height: 120)
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
                Toggle("Enable Matrix Screensaver", isOn: $config.isEnabled)
                    .tint(.green)

                Text("Displays a Matrix-style falling character animation after a period of inactivity. Move the mouse or press any key to dismiss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Timeout Section

    @ViewBuilder
    private var timeoutSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Idle Timeout")
                    .font(.headline)

                Picker("Activate After", selection: $config.idleTimeoutMinutes) {
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("60 minutes").tag(60)
                }

                Text("The screensaver will activate after this many minutes of inactivity.")
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
                Text("Color")
                    .font(.headline)

                HStack {
                    Text("Rain Color")
                        .font(.subheadline)
                    Spacer()
                    ColorPicker(
                        "",
                        selection: matrixColorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - Animation Section

    @ViewBuilder
    private var animationSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Animation")
                    .font(.headline)

                LabeledSlider(
                    label: "Speed",
                    value: $config.speed,
                    range: 0.2...3.0,
                    step: 0.1,
                    format: "%.1fx",
                    tintColor: .green
                )

                LabeledSlider(
                    label: "Density",
                    value: $config.density,
                    range: 0.1...1.0,
                    step: 0.05,
                    format: "%.0f%%",
                    displayMultiplier: 100,
                    tintColor: .green
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Trail Length")
                            .font(.subheadline)
                        Spacer()
                        Text("\(config.trailLength) cells")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: trailLengthBinding,
                        in: 3...40,
                        step: 1
                    )
                    .tint(.green)
                }
            }
        }
    }

    // MARK: - Character Set Section

    @ViewBuilder
    private var characterSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Characters")
                    .font(.headline)

                Picker("Character Set", selection: $config.characterSet) {
                    ForEach(MatrixCharacterSet.allCases) { charSet in
                        Text(charSet.title).tag(charSet)
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private var matrixColorBinding: Binding<Color> {
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

    private var trailLengthBinding: Binding<Double> {
        Binding(
            get: { Double(config.trailLength) },
            set: { config.trailLength = Int($0) }
        )
    }
}

// MARK: - Live Preview Renderer

/// Canvas-based CPU preview of the Matrix falling character effect.
struct MatrixPreviewRenderer: View {
    let config: MatrixScreensaverConfiguration

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate

                // Black background
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.black)
                )

                guard config.isEnabled else {
                    let font = Font.system(.title3, design: .monospaced)
                    let text = context.resolve(
                        Text("Screensaver Disabled")
                            .font(font)
                            .foregroundColor(.gray)
                    )
                    context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
                    return
                }

                let cellW: CGFloat = 12
                let cellH: CGFloat = 16
                let columns = Int(size.width / cellW)
                let rows = Int(size.height / cellH)
                let chars = config.characterSet.characters
                guard !chars.isEmpty else { return }

                let activeColumns = max(1, Int(Float(columns) * config.density))

                for col in 0..<activeColumns {
                    let colIndex = (col * 7 + 3) % max(columns, 1)
                    let speed = Double(config.speed) * (0.6 + Double(col % 5) * 0.15) * 8.0
                    let offset = Double(col * 13 % 37)
                    let cycleLen = Double(rows + config.trailLength)
                    let rawPos = offset + elapsed * speed
                    let wrapped = rawPos.truncatingRemainder(dividingBy: cycleLen)
                    let headRow = Int(wrapped < 0 ? wrapped + cycleLen : wrapped)

                    for trail in 0..<config.trailLength {
                        let row = headRow - trail
                        guard row >= 0, row < rows else { continue }

                        let charIdx = abs(colIndex &* 31 &+ row &* 17 &+ Int(elapsed * 3)) % chars.count
                        let char = chars[charIdx]

                        let fade: Double = trail == 0 ? 1.0 : max(0.05, 1.0 - Double(trail) / Double(config.trailLength))

                        let color: Color
                        if trail == 0 {
                            color = Color(
                                red: Double(config.color.red) * 0.3 + 0.7,
                                green: Double(config.color.green) * 0.3 + 0.7,
                                blue: Double(config.color.blue) * 0.3 + 0.7
                            )
                        } else {
                            color = Color(
                                red: Double(config.color.red) * fade,
                                green: Double(config.color.green) * fade,
                                blue: Double(config.color.blue) * fade
                            )
                        }

                        let x = CGFloat(colIndex) * cellW + cellW / 2
                        let y = CGFloat(row) * cellH + cellH / 2
                        let font = Font.system(size: 11, design: .monospaced)
                        let text = context.resolve(
                            Text(String(char))
                                .font(font)
                                .foregroundColor(color.opacity(fade))
                        )
                        context.draw(text, at: CGPoint(x: x, y: y), anchor: .center)
                    }
                }
            }
        }
    }
}
