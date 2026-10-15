import SwiftUI

struct AnthropicModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var modelStore: AnthropicModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose a Claude model")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }

            if modelStore.isRefreshing && modelStore.models.isEmpty {
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if modelStore.models.isEmpty {
                ContentUnavailableView(
                    "No models loaded",
                    systemImage: "network",
                    description: Text(modelStore.catalogError ?? "Refresh the Anthropic model list.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(modelStore.models) { model in
                    Button {
                        try? modelStore.select(model.id)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName).font(.headline)
                                Text(model.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(limits(for: model))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.id == modelStore.selectedModelID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("All models your API key can use, newest first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await modelStore.refresh() } }
                    .disabled(modelStore.isRefreshing)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 500)
        .task {
            if modelStore.models.isEmpty { await modelStore.refresh() }
        }
    }

    private func limits(for model: AnthropicModel) -> String {
        let context = model.maxInputTokens.map { "\($0.formatted()) token context" } ?? "Context unavailable"
        let output = model.maxTokens.map { "up to \($0.formatted()) output tokens" } ?? "output limit unavailable"
        return "\(context) · \(output)"
    }
}
