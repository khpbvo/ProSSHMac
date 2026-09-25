import SwiftUI

struct OpenRouterModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var modelStore: OpenRouterModelStore
    @State private var searchText = ""

    private var visibleModels: [OpenRouterModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return modelStore.models }
        return modelStore.models.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose an OpenRouter model")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            TextField("Search models or providers", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if modelStore.isRefreshing && modelStore.models.isEmpty {
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if modelStore.models.isEmpty {
                ContentUnavailableView(
                    "No models loaded",
                    systemImage: "network",
                    description: Text(modelStore.catalogError ?? "Refresh the OpenRouter model list.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleModels) { model in
                    Button {
                        try? modelStore.select(model.id)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.name).font(.headline)
                                Text(model.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(metadata(for: model))
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
                Text("Only text models that advertise tool calling are shown. Prices are OpenRouter's published rates per million tokens.")
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

    private func metadata(for model: OpenRouterModel) -> String {
        let context = model.contextLength.map { "\($0.formatted()) token context" } ?? "Context unavailable"
        guard let input = model.promptPricePerMillion,
              let output = model.completionPricePerMillion else {
            return "\(context) · Price unavailable"
        }
        if input == 0 && output == 0 { return "\(context) · Free" }
        return "\(context) · Input \(price(input)) / Output \(price(output)) per 1M tokens"
    }

    private func price(_ value: Decimal) -> String {
        let amount = NSDecimalNumber(decimal: value).doubleValue
        return String(format: amount < 0.01 ? "$%.4f" : "$%.2f", amount)
    }
}
