// Extracted from TerminalView.swift
import SwiftUI
import UniformTypeIdentifiers

struct TerminalQuickCommandPanel: View {
    @ObservedObject var quickCommands: QuickCommands
    var selectedSession: Session?
    var onSendShellInput: (UUID, String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var isQuickCommandEditorPresented = false
    @State private var quickCommandEditingSnippetID: UUID?
    @State private var quickCommandDraftName = ""
    @State private var quickCommandDraftTemplate = ""
    @State private var quickCommandDraftHostScoped = false
    @State private var quickCommandDraftHostID: UUID?
    @State private var quickCommandDraftHostLabel: String?
    @State private var quickCommandDraftVariableDefaults: [String: String] = [:]
    @State private var quickCommandPendingSnippet: QuickCommandSnippet?
    @State private var quickCommandPendingValues: [String: String] = [:]
    @State private var isQuickCommandImportPresented = false
    @State private var quickCommandStatusLine: String?

    var body: some View {
        ZStack(alignment: .trailing) {
            if quickCommands.isDrawerPresented {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        quickCommands.dismissDrawer()
                    }
            }
            quickCommandDrawerLayer
        }
        .sheet(isPresented: $isQuickCommandEditorPresented) {
            quickCommandEditorSheet
        }
        .sheet(item: $quickCommandPendingSnippet) { snippet in
            quickCommandVariableSheet(for: snippet)
        }
        .fileImporter(
            isPresented: $isQuickCommandImportPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleQuickCommandImport(result: result)
        }
        .animation(.easeInOut(duration: 0.2), value: quickCommands.isDrawerPresented)
    }

    private var quickCommandDrawerLayer: some View {
        GeometryReader { geometry in
            let drawerWidth = min(380, max(280, geometry.size.width * 0.72))

            ZStack(alignment: .trailing) {
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onEnded { value in
                                guard !quickCommands.isDrawerPresented else { return }
                                guard value.translation.width < -35 else { return }
                                quickCommands.presentDrawer()
                            }
                    )

                if quickCommands.isDrawerPresented {
                    quickCommandDrawer(width: drawerWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    private func quickCommandDrawer(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            quickCommandDrawerHeader
            quickCommandDrawerTarget

            if let quickCommandStatusLine {
                Text(quickCommandStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            quickCommandDrawerBody
        }
        .padding(12)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    if value.translation.width > 35 {
                        quickCommands.dismissDrawer()
                    }
                }
        )
    }

    private var quickCommandDrawerHeader: some View {
        HStack(spacing: 8) {
            Label("Quick Commands", systemImage: "terminal")
                .font(.headline)

            Spacer()

            Menu {
                Button("Import JSON") {
                    isQuickCommandImportPresented = true
                }
                Button("Export JSON") {
                    exportQuickCommandLibrary()
                }
            } label: {
                Image(systemName: "square.and.arrow.up.on.square")
            }
            .buttonStyle(.borderless)

            Button {
                presentQuickCommandEditor(for: nil)
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)

            Button {
                quickCommands.dismissDrawer()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }

    private var quickCommandDrawerTarget: some View {
        Group {
            if let session = selectedSession {
                Text("Target: \(session.hostLabel)")
            } else {
                Text("Select an active session to run commands.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var quickCommandDrawerBody: some View {
        if quickCommandVisibleSnippets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No Quick Commands")
                    .font(.headline)
                Text("Add snippets for repetitive commands. Use {{variable}} placeholders for prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(quickCommandVisibleSnippets) { snippet in
                        quickCommandSnippetRow(snippet)
                    }
                }
            }
        }
    }

    private func quickCommandSnippetRow(_ snippet: QuickCommandSnippet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    runQuickCommandSnippet(snippet)
                } label: {
                    Text(snippet.name)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    presentQuickCommandEditor(for: snippet)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    quickCommands.removeSnippet(id: snippet.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            Text(snippet.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(snippet.isGlobal ? "Global" : (snippet.hostLabel ?? "Host"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.16), in: Capsule())

                if !snippet.variables.isEmpty {
                    Text("Vars: \(snippet.variables.map(\.name).joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
        )
    }

    private var quickCommandVisibleSnippets: [QuickCommandSnippet] {
        quickCommands.snippets(for: selectedSession?.hostID)
    }

    private var quickCommandEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Snippet") {
                    TextField("Name", text: $quickCommandDraftName)
                    TextField("Command Template", text: $quickCommandDraftTemplate, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("Scope") {
                    Toggle("Host-specific", isOn: $quickCommandDraftHostScoped)
                        .onChange(of: quickCommandDraftHostScoped) { _, isOn in
                            guard isOn else { return }
                            if quickCommandDraftHostID == nil, let session = selectedSession {
                                quickCommandDraftHostID = session.hostID
                                quickCommandDraftHostLabel = session.hostLabel
                            }
                        }

                    Text(
                        quickCommandDraftHostScoped
                        ? "Host: \(quickCommandDraftHostLabel ?? "No host selected")"
                        : "Global (all hosts)"
                    )
                    .font(.caption)
                    .foregroundStyle(quickCommandDraftHostScoped && quickCommandDraftHostID == nil ? .red : .secondary)
                }

                if !quickCommandDraftVariableNames.isEmpty {
                    Section("Variable Defaults") {
                        ForEach(quickCommandDraftVariableNames, id: \.self) { variableName in
                            TextField(
                                variableName,
                                text: quickCommandDraftDefaultBinding(for: variableName)
                            )
                            .terminalInputBehavior()
                        }
                    }
                }
            }
            .navigationTitle(quickCommandEditingSnippetID == nil ? "New Quick Command" : "Edit Quick Command")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isQuickCommandEditorPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveQuickCommandFromDraft()
                    }
                    .disabled(!quickCommandDraftCanSave)
                }
            }
        }
    }

    private func quickCommandVariableSheet(for snippet: QuickCommandSnippet) -> some View {
        NavigationStack {
            Form {
                ForEach(snippet.variables) { variable in
                    TextField(
                        variable.name,
                        text: Binding(
                            get: { quickCommandPendingValues[variable.name, default: variable.defaultValue] },
                            set: { quickCommandPendingValues[variable.name] = $0 }
                        )
                    )
                    .terminalInputBehavior()
                }
            }
            .navigationTitle(snippet.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        quickCommandPendingSnippet = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sendQuickCommand(snippet: snippet, values: quickCommandPendingValues)
                        quickCommandPendingSnippet = nil
                    }
                }
            }
        }
    }

    private var quickCommandDraftVariableNames: [String] {
        quickCommands.placeholderVariables(in: quickCommandDraftTemplate)
    }

    private var quickCommandDraftCanSave: Bool {
        let hasName = !quickCommandDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCommand = !quickCommandDraftTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasScope = !quickCommandDraftHostScoped || quickCommandDraftHostID != nil
        return hasName && hasCommand && hasScope
    }

    private func quickCommandDraftDefaultBinding(for variableName: String) -> Binding<String> {
        Binding(
            get: { quickCommandDraftVariableDefaults[variableName, default: ""] },
            set: { quickCommandDraftVariableDefaults[variableName] = $0 }
        )
    }

    private func presentQuickCommandEditor(for snippet: QuickCommandSnippet?) {
        if let snippet {
            quickCommandEditingSnippetID = snippet.id
            quickCommandDraftName = snippet.name
            quickCommandDraftTemplate = snippet.command
            quickCommandDraftHostScoped = !snippet.isGlobal
            quickCommandDraftHostID = snippet.hostID
            quickCommandDraftHostLabel = snippet.hostLabel
            quickCommandDraftVariableDefaults = Dictionary(
                uniqueKeysWithValues: snippet.variables.map { ($0.name, $0.defaultValue) }
            )
        } else {
            quickCommandEditingSnippetID = nil
            quickCommandDraftName = ""
            quickCommandDraftTemplate = ""
            quickCommandDraftHostScoped = false
            quickCommandDraftHostID = selectedSession?.hostID
            quickCommandDraftHostLabel = selectedSession?.hostLabel
            quickCommandDraftVariableDefaults = [:]
        }

        isQuickCommandEditorPresented = true
    }

    private func saveQuickCommandFromDraft() {
        var hostID: UUID?
        var hostLabel: String?

        if quickCommandDraftHostScoped {
            if quickCommandDraftHostID == nil, let session = selectedSession {
                quickCommandDraftHostID = session.hostID
                quickCommandDraftHostLabel = session.hostLabel
            }

            hostID = quickCommandDraftHostID
            hostLabel = quickCommandDraftHostLabel
        }

        do {
            _ = try quickCommands.saveSnippet(
                id: quickCommandEditingSnippetID,
                name: quickCommandDraftName,
                command: quickCommandDraftTemplate,
                variableDefaults: quickCommandDraftVariableDefaults,
                hostID: hostID,
                hostLabel: hostLabel
            )
            quickCommandStatusLine = quickCommandEditingSnippetID == nil
                ? "Quick command saved."
                : "Quick command updated."
            isQuickCommandEditorPresented = false
        } catch {
            quickCommandStatusLine = error.localizedDescription
        }
    }

    private func runQuickCommandSnippet(_ snippet: QuickCommandSnippet) {
        guard let session = selectedSession else {
            quickCommandStatusLine = "Select a connected session first."
            return
        }

        guard snippet.applies(toHostID: session.hostID) else {
            quickCommandStatusLine = "This quick command does not apply to the selected host."
            return
        }

        if snippet.variables.isEmpty {
            sendQuickCommand(snippet: snippet, values: [:])
        } else {
            quickCommandPendingValues = Dictionary(
                uniqueKeysWithValues: snippet.variables.map { ($0.name, $0.defaultValue) }
            )
            quickCommandPendingSnippet = snippet
        }
    }

    private func sendQuickCommand(snippet: QuickCommandSnippet, values: [String: String]) {
        guard let session = selectedSession else {
            quickCommandStatusLine = "Select a connected session first."
            return
        }

        let resolved = quickCommands.resolvedCommand(for: snippet, values: values)
        quickCommandStatusLine = "Sent '\(snippet.name)' to \(session.hostLabel)."

        onSendShellInput(session.id, resolved)
    }

    private func exportQuickCommandLibrary() {
        do {
            let url = try quickCommands.exportLibrary()
            quickCommandStatusLine = "Exported quick commands to \(url.lastPathComponent)."
        } catch {
            quickCommandStatusLine = "Export failed: \(error.localizedDescription)"
        }
    }

    private func handleQuickCommandImport(result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try quickCommands.importLibrary(from: url, strategy: .merge)
                quickCommandStatusLine = "Imported quick commands from \(url.lastPathComponent)."
            } catch {
                quickCommandStatusLine = "Import failed: \(error.localizedDescription)"
            }
        case let .failure(error):
            quickCommandStatusLine = "Import failed: \(error.localizedDescription)"
        }
    }
}
