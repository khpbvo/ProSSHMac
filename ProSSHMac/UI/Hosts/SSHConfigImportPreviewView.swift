import SwiftUI

struct SSHConfigImportPreviewView: View {
    let preview: SSHConfigImportService.ImportPreview
    let onImport: ([Host]) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: Set<UUID> = []
    @State private var showWarnings = false

    private var duplicateIDs: Set<UUID> {
        let service = SSHConfigImportService()
        let candidates = preview.results.map(\.host)
        let dups = service.findDuplicates(imported: candidates, existing: [])
        return Set(dups.map(\.imported.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(preview.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Hosts") {
                    ForEach(preview.results, id: \.host.id) { result in
                        let isDuplicate = duplicateIDs.contains(result.host.id)
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(result.host.id) },
                            set: { checked in
                                if checked {
                                    selectedIDs.insert(result.host.id)
                                } else {
                                    selectedIDs.remove(result.host.id)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(result.host.label)
                                        .font(.subheadline)
                                        .foregroundStyle(isDuplicate ? .secondary : .primary)
                                    if isDuplicate {
                                        Text("duplicate")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.2), in: Capsule())
                                            .foregroundStyle(.orange)
                                    }
                                    if !result.notes.isEmpty {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.yellow)
                                    }
                                }
                                Text("\(result.host.username)@\(result.host.hostname):\(result.host.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !result.notes.isEmpty {
                                    Text(result.notes.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }

                if !preview.parserWarnings.isEmpty {
                    Section(isExpanded: $showWarnings) {
                        ForEach(preview.parserWarnings, id: \.lineNumber) { warning in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Line \(warning.lineNumber): \(warning.reason)")
                                    .font(.caption)
                                Text(warning.line)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } header: {
                        Button {
                            withAnimation { showWarnings.toggle() }
                        } label: {
                            HStack {
                                Text("Parser Warnings (\(preview.parserWarnings.count))")
                                Spacer()
                                Image(systemName: showWarnings ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Import SSH Config")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selectedIDs.count) Host\(selectedIDs.count == 1 ? "" : "s")") {
                        let selected = preview.results
                            .map(\.host)
                            .filter { selectedIDs.contains($0.id) }
                        onImport(selected)
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .onAppear {
            // Pre-select all non-duplicate hosts
            selectedIDs = Set(
                preview.results
                    .map(\.host.id)
                    .filter { !duplicateIDs.contains($0) }
            )
        }
    }
}
