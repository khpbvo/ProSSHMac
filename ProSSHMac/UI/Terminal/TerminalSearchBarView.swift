// Extracted from TerminalView.swift
import SwiftUI

struct TerminalSearchBarView: View {
    @ObservedObject var terminalSearch: TerminalSearch
    let focusFieldNonce: Int
    var onHide: () -> Void
    var onFocusChanged: (Bool) -> Void

    @FocusState private var isFieldFocused: Bool
    @AppStorage(TransparencyManager.backgroundOpacityKey)
    private var terminalBackgroundOpacityPercent = TransparencyManager.defaultBackgroundOpacityPercent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Find", systemImage: "magnifyingglass")
                    .font(.caption.weight(.semibold))

                TextField("Find in terminal output", text: searchQueryBinding)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFieldFocused)
                    .onSubmit {
                        terminalSearch.selectNextMatch()
                    }

                Button {
                    onHide()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Toggle("Regex", isOn: searchRegexBinding)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Toggle("Case", isOn: searchCaseSensitiveBinding)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Spacer()

                Text(terminalSearch.resultSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    terminalSearch.selectPreviousMatch()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(terminalSearch.matches.isEmpty)

                Button {
                    terminalSearch.selectNextMatch()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(terminalSearch.matches.isEmpty)
            }

            if let validationError = terminalSearch.validationError {
                Text("Regex error: \(validationError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(terminalSurfaceColor, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(terminalSurfaceBorderColor, lineWidth: 1)
        )
        .onChange(of: focusFieldNonce) { _, _ in isFieldFocused = true }
        .onChange(of: isFieldFocused) { _, v in onFocusChanged(v) }
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { terminalSearch.query },
            set: { terminalSearch.query = $0 }
        )
    }

    private var searchRegexBinding: Binding<Bool> {
        Binding(
            get: { terminalSearch.isRegexEnabled },
            set: { terminalSearch.isRegexEnabled = $0 }
        )
    }

    private var searchCaseSensitiveBinding: Binding<Bool> {
        Binding(
            get: { terminalSearch.isCaseSensitive },
            set: { terminalSearch.isCaseSensitive = $0 }
        )
    }

    private var terminalSurfaceColor: Color {
        let opacityMultiplier = TransparencyManager.normalizedOpacity(fromPercent: terminalBackgroundOpacityPercent)
        let baseOpacity = colorScheme == .dark ? 0.34 : 0.08
        return Color.black.opacity(baseOpacity * opacityMultiplier)
    }

    private var terminalSurfaceBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
    }
}
