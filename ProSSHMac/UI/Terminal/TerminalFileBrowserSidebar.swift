// Extracted from TerminalView.swift
import SwiftUI

struct TerminalFileBrowserSidebar: View {
    var session: Session?
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var transferManager: TransferManager
    var onClose: () -> Void
    var onSendShellInput: (UUID, String) -> Void

    @State private var selectedFileBrowserPath: String?
    @State private var fileBrowserSessionID: UUID?
    @State private var fileBrowserCurrentPath: String = "/"
    @State private var fileBrowserRows: [TerminalFileBrowserRow] = []
    @State private var fileBrowserChildrenByPath: [String: [TerminalFileBrowserEntry]] = [:]
    @State private var fileBrowserExpandedPaths: Set<String> = []
    @State private var fileBrowserLoadingPaths: Set<String> = []
    @State private var fileBrowserLoadRequestIDByPath: [String: UUID] = [:]
    @State private var isFileBrowserRootLoading = false
    @State private var fileBrowserError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Files", systemImage: "folder")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            if let session = session {
                Text("\(session.username)@\(session.hostname)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No active session selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let session = session, session.state == .connected {
                HStack(spacing: 8) {
                    Button {
                        navigateUpFileBrowserRoot(for: session)
                        selectedFileBrowserPath = nil
                    } label: {
                        Image(systemName: "arrow.up.to.line")
                    }
                    .buttonStyle(.bordered)
                    .disabled(fileBrowserCurrentPath == "/" || fileBrowserCurrentPath.isEmpty)

                    Button {
                        refreshFileBrowserRoot(for: session)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        downloadSelectedFileFromSidebar()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.isLocal || selectedFileBrowserItem?.isDirectory != false)
                }

                Text(fileBrowserCurrentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Divider()

                if isFileBrowserRootLoading && fileBrowserRows.isEmpty {
                    ProgressView("Loading directory...")
                        .padding(.top, 6)
                } else if let fileBrowserError {
                    Text(fileBrowserError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 6)
                } else if fileBrowserRows.isEmpty {
                    Text("Directory is empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(fileBrowserRows) { row in
                                fileBrowserRow(row, session: session)
                            }
                        }
                    }
                }
            } else {
                Text("Connect to a host to browse remote files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Divider()
        }
        .onAppear { syncSession() }
        .onDisappear { transferManager.setActiveSession(nil) }
        .onChange(of: session?.id) { _, _ in syncSession() }
    }

    private var selectedFileBrowserItem: TerminalFileBrowserEntry? {
        guard let path = selectedFileBrowserPath else { return nil }
        if let rowMatch = fileBrowserRows.first(where: { $0.entry.path == path }) {
            return rowMatch.entry
        }
        for entries in fileBrowserChildrenByPath.values {
            if let match = entries.first(where: { $0.path == path }) {
                return match
            }
        }
        return nil
    }

    @ViewBuilder
    private func fileBrowserRow(_ row: TerminalFileBrowserRow, session: Session) -> some View {
        let entry = row.entry
        let isSelected = selectedFileBrowserPath == entry.path
        let isExpanded = entry.isDirectory && fileBrowserExpandedPaths.contains(entry.path)
        let isLoading = entry.isDirectory && fileBrowserLoadingPaths.contains(entry.path)
        Button {
            if entry.isDirectory {
                selectedFileBrowserPath = nil
                toggleFileBrowserDirectory(entry, for: session)
            } else {
                selectedFileBrowserPath = entry.path
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entry.isDirectory
                      ? (isExpanded ? "folder.fill.badge.minus" : "folder.fill")
                      : "doc")
                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                Text(entry.name)
                    .lineLimit(1)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                if !entry.isDirectory {
                    Text(byteCount(entry.size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(8 + (row.depth * 14)))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if entry.isDirectory {
                Button(isExpanded ? "Collapse" : "Expand") {
                    toggleFileBrowserDirectory(entry, for: session)
                }
            } else {
                if !session.isLocal {
                    Button("Download") {
                        downloadFileBrowserFile(entry)
                    }
                }
                Button("Open in nano") {
                    openFileInTerminal(entry.path, editor: "nano")
                }
                Button("Open in vim") {
                    openFileInTerminal(entry.path, editor: "vim")
                }
                Button("View with less") {
                    openFileInTerminal(entry.path, editor: "less")
                }
                Button("Cat to terminal") {
                    openFileInTerminal(entry.path, editor: "cat")
                }
            }
            Button("Copy Path") {
                PlatformClipboard.writeString(entry.path)
            }
        }
    }

    private func syncSession() {
        guard let session = session, session.state == .connected else {
            transferManager.setActiveSession(nil)
            fileBrowserSessionID = nil
            selectedFileBrowserPath = nil
            fileBrowserCurrentPath = "/"
            fileBrowserRows = []
            fileBrowserChildrenByPath = [:]
            fileBrowserExpandedPaths = []
            fileBrowserLoadingPaths = []
            fileBrowserLoadRequestIDByPath = [:]
            isFileBrowserRootLoading = false
            fileBrowserError = nil
            return
        }

        let didSwitchSession = fileBrowserSessionID != session.id
        if didSwitchSession {
            fileBrowserSessionID = session.id
            selectedFileBrowserPath = nil
        }

        if session.isLocal {
            transferManager.setActiveSession(nil)
        } else if transferManager.activeSessionID != session.id {
            transferManager.setActiveSession(session.id)
        }

        if didSwitchSession {
            loadFileBrowserRoot(for: session, path: initialFileBrowserRootPath(for: session))
            return
        }

        if fileBrowserChildrenByPath[fileBrowserCurrentPath] == nil && !isFileBrowserRootLoading {
            loadFileBrowserRoot(for: session, path: fileBrowserCurrentPath)
        }
    }

    private func initialFileBrowserRootPath(for session: Session) -> String {
        if session.isLocal {
            let workingDirectory = sessionManager.workingDirectoryBySessionID[session.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let workingDirectory, !workingDirectory.isEmpty {
                return normalizeFileBrowserPath(workingDirectory, isLocal: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return normalizeFileBrowserPath(transferManager.currentRemotePath, isLocal: false)
    }

    private func downloadSelectedFileFromSidebar() {
        guard let session = session, !session.isLocal,
              let entry = selectedFileBrowserItem, !entry.isDirectory else { return }
        downloadFileBrowserFile(entry)
    }

    private func downloadFileBrowserFile(_ entry: TerminalFileBrowserEntry) {
        transferManager.enqueueDownload(
            entry: SFTPDirectoryEntry(
                path: entry.path,
                name: entry.name,
                isDirectory: entry.isDirectory,
                size: entry.size,
                permissions: 0,
                modifiedAt: nil
            )
        )
    }

    private func openFileInTerminal(_ path: String, editor: String) {
        guard let session = session, session.state == .connected else { return }
        let escapedPath = shellEscapeForTerminal(path)
        onSendShellInput(session.id, "\(editor) \(escapedPath)")
    }

    private func shellEscapeForTerminal(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func navigateUpFileBrowserRoot(for session: Session) {
        guard let parentPath = parentFileBrowserPath(of: fileBrowserCurrentPath, isLocal: session.isLocal) else {
            return
        }
        loadFileBrowserRoot(for: session, path: parentPath)
    }

    private func refreshFileBrowserRoot(for session: Session) {
        loadFileBrowserRoot(for: session, path: fileBrowserCurrentPath)
    }

    private func loadFileBrowserRoot(for session: Session, path: String) {
        let normalizedPath = normalizeFileBrowserPath(path, isLocal: session.isLocal)
        fileBrowserCurrentPath = normalizedPath
        fileBrowserRows = []
        fileBrowserChildrenByPath = [:]
        fileBrowserExpandedPaths = []
        fileBrowserLoadingPaths = []
        fileBrowserLoadRequestIDByPath = [:]
        fileBrowserError = nil
        selectedFileBrowserPath = nil
        loadFileBrowserDirectory(path: normalizedPath, for: session, isRoot: true)
    }

    private func toggleFileBrowserDirectory(_ entry: TerminalFileBrowserEntry, for session: Session) {
        guard entry.isDirectory else { return }
        if fileBrowserExpandedPaths.contains(entry.path) {
            collapseFileBrowserDirectory(entry.path)
            return
        }

        fileBrowserExpandedPaths.insert(entry.path)
        if fileBrowserChildrenByPath[entry.path] == nil {
            loadFileBrowserDirectory(path: entry.path, for: session, isRoot: false)
        }
        rebuildFileBrowserRows()
    }

    private func collapseFileBrowserDirectory(_ path: String) {
        fileBrowserExpandedPaths = TerminalFileBrowserTree.collapseExpandedPaths(
            fileBrowserExpandedPaths,
            collapsing: path
        )
        rebuildFileBrowserRows()
    }

    private func loadFileBrowserDirectory(path: String, for session: Session, isRoot: Bool) {
        let normalizedPath = normalizeFileBrowserPath(path, isLocal: session.isLocal)
        if !isRoot, fileBrowserLoadRequestIDByPath[normalizedPath] != nil {
            return
        }
        let requestID = UUID()
        fileBrowserLoadRequestIDByPath[normalizedPath] = requestID

        if isRoot {
            isFileBrowserRootLoading = true
        }
        fileBrowserError = nil
        fileBrowserLoadingPaths.insert(normalizedPath)

        Task {
            do {
                let entries = try await listFileBrowserEntries(for: session, path: normalizedPath)
                await MainActor.run {
                    guard fileBrowserLoadRequestIDByPath[normalizedPath] == requestID else {
                        if fileBrowserLoadRequestIDByPath[normalizedPath] == nil {
                            fileBrowserLoadingPaths.remove(normalizedPath)
                            if isRoot && normalizedPath == fileBrowserCurrentPath {
                                isFileBrowserRootLoading = false
                            }
                        }
                        return
                    }

                    fileBrowserLoadRequestIDByPath[normalizedPath] = nil
                    fileBrowserLoadingPaths.remove(normalizedPath)
                    if isRoot {
                        isFileBrowserRootLoading = false
                    }

                    guard fileBrowserSessionID == session.id else { return }

                    if isRoot {
                        fileBrowserCurrentPath = normalizedPath
                    }

                    fileBrowserError = nil
                    fileBrowserChildrenByPath[normalizedPath] = entries
                    if let selectedPath = selectedFileBrowserPath, !fileBrowserContainsPath(selectedPath) {
                        selectedFileBrowserPath = nil
                    }
                    rebuildFileBrowserRows()
                }
            } catch {
                await MainActor.run {
                    guard fileBrowserLoadRequestIDByPath[normalizedPath] == requestID else {
                        if fileBrowserLoadRequestIDByPath[normalizedPath] == nil {
                            fileBrowserLoadingPaths.remove(normalizedPath)
                            if isRoot && normalizedPath == fileBrowserCurrentPath {
                                isFileBrowserRootLoading = false
                            }
                        }
                        return
                    }

                    fileBrowserLoadRequestIDByPath[normalizedPath] = nil
                    fileBrowserLoadingPaths.remove(normalizedPath)
                    if isRoot {
                        isFileBrowserRootLoading = false
                    }

                    guard fileBrowserSessionID == session.id else { return }

                    if isRoot {
                        fileBrowserCurrentPath = normalizedPath
                    }

                    let scopeLabel = session.isLocal ? "local" : "remote"
                    fileBrowserError = "Failed to list \(scopeLabel) directory: \(error.localizedDescription)"
                    if isRoot {
                        fileBrowserChildrenByPath[normalizedPath] = []
                    }
                    rebuildFileBrowserRows()
                }
            }
        }
    }

    private func listFileBrowserEntries(for session: Session, path: String) async throws -> [TerminalFileBrowserEntry] {
        if session.isLocal {
            return try await Task.detached(priority: .userInitiated) {
                try TerminalFileBrowserTree.listLocalEntries(path: path)
            }.value
        }

        let remoteEntries = try await sessionManager.listRemoteDirectory(sessionID: session.id, path: path)
        return remoteEntries.map {
            TerminalFileBrowserEntry(
                path: $0.path,
                name: $0.name,
                isDirectory: $0.isDirectory,
                size: $0.size
            )
        }
    }

    private func rebuildFileBrowserRows() {
        fileBrowserRows = TerminalFileBrowserTree.rebuildRows(
            rootPath: fileBrowserCurrentPath,
            childrenByPath: fileBrowserChildrenByPath,
            expandedPaths: fileBrowserExpandedPaths
        )
    }

    private func fileBrowserContainsPath(_ path: String) -> Bool {
        TerminalFileBrowserTree.containsPath(
            path,
            rows: fileBrowserRows,
            childrenByPath: fileBrowserChildrenByPath
        )
    }

    private func normalizeFileBrowserPath(_ rawPath: String, isLocal: Bool) -> String {
        TerminalFileBrowserTree.normalizePath(rawPath, isLocal: isLocal)
    }

    private func parentFileBrowserPath(of path: String, isLocal: Bool) -> String? {
        TerminalFileBrowserTree.parentPath(of: path, isLocal: isLocal)
    }
}
