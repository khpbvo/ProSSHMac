import SwiftUI

/// Settings → AI Assistant rows shown when Anthropic is the selected provider.
struct AnthropicSettingsSection: View {
    @ObservedObject var viewModel: AnthropicSettingsViewModel
    @ObservedObject var modelStore: AnthropicModelStore
    @State private var showingModelPicker = false

    var body: some View {
        Group {
            if viewModel.hasStoredAPIKey {
                HStack {
                    Button {
                        showingModelPicker = true
                    } label: {
                        HStack {
                            Text("Model")
                            Spacer()
                            Text(modelStore.selectedModel?.displayName ?? modelStore.selectedModelID)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Refresh Models") {
                        Task { await modelStore.refresh() }
                    }
                    .disabled(modelStore.isRefreshing)
                }
                if modelStore.selectedModelUnavailable {
                    Text("This model is no longer listed. Choose another model to continue.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let error = modelStore.catalogError {
                    Text("Could not refresh models: \(error). Your previous selection remains available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Picker("Effort", selection: Binding(
                    get: { modelStore.effort },
                    set: { modelStore.setEffort($0) }
                )) {
                    ForEach(AnthropicEffort.allCases, id: \.self) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }
                Text("How much Claude thinks before answering: higher is slower and costs more. A model that doesn't support the level uses its highest one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            AIAPIKeyFields(viewModel: viewModel)

            Text("Refusal fallback is on: if Anthropic's safety filters decline a request, the API retries it on another Claude model, for models that allow it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingModelPicker) {
            AnthropicModelPicker(modelStore: modelStore)
        }
    }
}
