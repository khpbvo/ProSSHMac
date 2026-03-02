import SwiftUI

struct SolidBackgroundSettingsView: View {
    @State private var config: SolidBackgroundConfiguration
    @Environment(\.dismiss) private var dismiss

    var onApply: ((SolidBackgroundConfiguration) -> Void)?

    init(
        configuration: SolidBackgroundConfiguration = .load(),
        onApply: ((SolidBackgroundConfiguration) -> Void)? = nil
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
                        Toggle("Enable Solid Background", isOn: $config.isEnabled)
                    }

                    if config.isEnabled {
                        SettingsCard {
                            HStack {
                                Text("Background Color")
                                    .font(.subheadline)
                                Spacer()
                                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                                    .labelsHidden()
                            }
                        }

                        Text("When both effects are enabled, Gradient Background takes priority over Solid Background.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding()
            }
            .background(.background)
            .navigationTitle("Solid Background")
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
            get: { config.color.color },
            set: { config.color = GradientColor($0) }
        )
    }

    @ViewBuilder
    private var previewCard: some View {
        ZStack {
            if config.isEnabled {
                config.color.color
            } else {
                Color.black
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("kevin@nuc ~ %")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.9))
                Text("ssh production-server")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Last login: Mon Feb 16 08:42")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}
