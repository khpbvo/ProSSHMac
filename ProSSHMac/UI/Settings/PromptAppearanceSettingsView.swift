// PromptAppearanceSettingsView.swift
// ProSSHV2
//
// Settings UI for customizing the local terminal prompt colors.
// Controls username style (white/single color/rainbow), path color,
// and symbol color. Changes apply on new local terminal sessions.

import SwiftUI

struct PromptAppearanceSettingsView: View {
    @State private var config: PromptAppearanceConfiguration
    @Environment(\.dismiss) private var dismiss

    var onApply: ((PromptAppearanceConfiguration) -> Void)?

    init(
        configuration: PromptAppearanceConfiguration = .load(),
        onApply: ((PromptAppearanceConfiguration) -> Void)? = nil
    ) {
        _config = State(initialValue: configuration)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    previewCard
                    usernameStyleSection
                    if config.usernameStyle == .singleColor {
                        usernameColorSection
                    }
                    if config.usernameStyle == .rainbow {
                        rainbowColorsSection
                    }
                    promptColorsSection
                    infoSection
                }
                .padding()
            }
            .background(.background)
            .navigationTitle("Prompt Colors")
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

        PromptPreviewRenderer(config: config, username: username)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: - Username Style

    @ViewBuilder
    private var usernameStyleSection: some View {
        SettingsCard {
            Text("Username Style")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Style", selection: $config.usernameStyle) {
                ForEach(UsernameStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Single Color

    @ViewBuilder
    private var usernameColorSection: some View {
        SettingsCard {
            ColorPicker(
                "Username Color",
                selection: colorBinding(for: \.usernameColor),
                supportsOpacity: false
            )
        }
    }

    // MARK: - Rainbow Colors

    @ViewBuilder
    private var rainbowColorsSection: some View {
        SettingsCard {
            Text("Rainbow Colors")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Six colors that cycle through the username characters.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let labels = ["Color 1", "Color 2", "Color 3", "Color 4", "Color 5", "Color 6"]
            ForEach(0..<6, id: \.self) { index in
                ColorPicker(
                    labels[index],
                    selection: rainbowColorBinding(at: index),
                    supportsOpacity: false
                )
            }
        }
    }

    // MARK: - Path & Symbol Colors

    @ViewBuilder
    private var promptColorsSection: some View {
        SettingsCard {
            Text("Prompt Elements")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ColorPicker(
                "Path Color (~)",
                selection: colorBinding(for: \.pathColor),
                supportsOpacity: false
            )

            ColorPicker(
                "Symbol Color (%)",
                selection: colorBinding(for: \.symbolColor),
                supportsOpacity: false
            )
        }
    }

    // MARK: - Info

    @ViewBuilder
    private var infoSection: some View {
        SettingsCard {
            Label(
                "Changes take effect when you open a new local terminal session.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Color Bindings

    private func colorBinding(for keyPath: WritableKeyPath<PromptAppearanceConfiguration, GradientColor>) -> Binding<Color> {
        Binding(
            get: {
                let c = config[keyPath: keyPath]
                return Color(red: Double(c.red), green: Double(c.green), blue: Double(c.blue))
            },
            set: { newColor in
                config[keyPath: keyPath] = GradientColor(newColor)
            }
        )
    }

    private func rainbowColorBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: {
                guard index < config.rainbowColors.count else {
                    return .white
                }
                let c = config.rainbowColors[index]
                return Color(red: Double(c.red), green: Double(c.green), blue: Double(c.blue))
            },
            set: { newColor in
                while config.rainbowColors.count <= index {
                    config.rainbowColors.append(GradientColor(red: 1, green: 1, blue: 1))
                }
                config.rainbowColors[index] = GradientColor(newColor)
            }
        )
    }
}

// MARK: - Prompt Preview

/// Canvas-based preview of the prompt with current color settings.
struct PromptPreviewRenderer: View {
    let config: PromptAppearanceConfiguration
    let username: String

    var body: some View {
        Canvas { context, size in
            // Background
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black)
            )

            let font = Font.system(.body, design: .monospaced).weight(.medium)
            let y = size.height / 2.0
            var x: CGFloat = 12

            // Draw username characters
            for (i, char) in username.enumerated() {
                let charColor: Color
                switch config.usernameStyle {
                case .white:
                    charColor = .white
                case .singleColor:
                    charColor = Color(
                        red: Double(config.usernameColor.red),
                        green: Double(config.usernameColor.green),
                        blue: Double(config.usernameColor.blue)
                    )
                case .rainbow:
                    let c = config.rainbowColors[i % max(config.rainbowColors.count, 1)]
                    charColor = Color(red: Double(c.red), green: Double(c.green), blue: Double(c.blue))
                }

                let text = context.resolve(
                    Text(String(char))
                        .font(font)
                        .foregroundColor(charColor)
                )
                context.draw(text, at: CGPoint(x: x, y: y), anchor: .leading)
                x += text.measure(in: size).width
            }

            // Space
            x += 6

            // Draw path "~"
            let pathText = context.resolve(
                Text("~")
                    .font(font)
                    .foregroundColor(Color(
                        red: Double(config.pathColor.red),
                        green: Double(config.pathColor.green),
                        blue: Double(config.pathColor.blue)
                    ))
            )
            context.draw(pathText, at: CGPoint(x: x, y: y), anchor: .leading)
            x += pathText.measure(in: size).width + 6

            // Draw symbol "%"
            let symbolText = context.resolve(
                Text("%")
                    .font(font)
                    .foregroundColor(Color(
                        red: Double(config.symbolColor.red),
                        green: Double(config.symbolColor.green),
                        blue: Double(config.symbolColor.blue)
                    ))
            )
            context.draw(symbolText, at: CGPoint(x: x, y: y), anchor: .leading)
        }
    }
}
