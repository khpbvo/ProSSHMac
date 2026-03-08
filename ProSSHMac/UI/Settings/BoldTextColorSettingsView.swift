import SwiftUI

struct BoldTextColorSettingsView: View {
    @State private var config: BoldTextColorConfiguration
    @Environment(\.dismiss) private var dismiss

    var onApply: ((BoldTextColorConfiguration) -> Void)?

    init(
        configuration: BoldTextColorConfiguration = .load(),
        onApply: ((BoldTextColorConfiguration) -> Void)? = nil
    ) {
        _config = State(initialValue: configuration)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    previewCard

                    SettingsCard {
                        Toggle("Use Custom Color For Bold Text", isOn: $config.isEnabled)
                    }

                    if config.isEnabled {
                        SettingsCard {
                            HStack {
                                Text("Bold Text Color")
                                    .font(.subheadline)
                                Spacer()
                                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                                    .labelsHidden()
                            }
                        }
                    }

                    SettingsCard {
                        Label(
                            "Applied live by the Metal renderer. Bold font weight and ANSI parsing stay unchanged.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .background(.background)
            .navigationTitle("Bold Text Color")
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

    private var colorBinding: Binding<Color> {
        Binding(
            get: { config.customColor.color },
            set: { config.customColor = GradientColor($0) }
        )
    }

    @ViewBuilder
    private var previewCard: some View {
        ZStack {
            Color.black

            VStack(alignment: .leading, spacing: 8) {
                Text("Normal text")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))

                Text("Bold text")
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundStyle(config.isEnabled ? config.customColor.color : .white)

                Text("Bold ANSI color")
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundStyle(config.isEnabled ? config.customColor.color : .red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}
