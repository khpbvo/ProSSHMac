import Foundation

struct TerminalFileBrowserEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64

    var id: String { path }
}

struct TerminalFileBrowserRow: Identifiable, Hashable {
    let entry: TerminalFileBrowserEntry
    let depth: Int

    var id: String { entry.id }
}

enum TerminalFileBrowserTree {
    nonisolated static func normalizePath(
        _ rawPath: String,
        isLocal: Bool,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLocal {
            if trimmed.isEmpty {
                return homeDirectoryPath
            }
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
        }

        if trimmed.isEmpty || trimmed == "/" {
            return "/"
        }

        var components = trimmed.split(separator: "/").map(String.init)
        components.removeAll(where: { $0.isEmpty || $0 == "." })
        let normalized = "/" + components.joined(separator: "/")
        return normalized.isEmpty ? "/" : normalized
    }

    nonisolated static func parentPath(of path: String, isLocal: Bool) -> String? {
        if isLocal {
            let currentURL = URL(fileURLWithPath: path)
            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                return nil
            }
            return parentURL.path.isEmpty ? "/" : parentURL.path
        }

        let normalized = normalizePath(path, isLocal: false)
        guard normalized != "/" else { return nil }
        guard let slash = normalized.lastIndex(of: "/") else { return "/" }
        if slash == normalized.startIndex {
            return "/"
        }
        return String(normalized[..<slash])
    }

    nonisolated static func rebuildRows(
        rootPath: String,
        childrenByPath: [String: [TerminalFileBrowserEntry]],
        expandedPaths: Set<String>
    ) -> [TerminalFileBrowserRow] {
        guard let rootEntries = childrenByPath[rootPath] else { return [] }
        var rows: [TerminalFileBrowserRow] = []
        appendRows(
            from: rootEntries,
            depth: 0,
            into: &rows,
            childrenByPath: childrenByPath,
            expandedPaths: expandedPaths
        )
        return rows
    }

    nonisolated static func collapseExpandedPaths(_ expandedPaths: Set<String>, collapsing path: String) -> Set<String> {
        let prefix = path == "/" ? "/" : "\(path)/"
        return expandedPaths.filter { $0 != path && !$0.hasPrefix(prefix) }
    }

    nonisolated static func containsPath(
        _ path: String,
        rows: [TerminalFileBrowserRow],
        childrenByPath: [String: [TerminalFileBrowserEntry]]
    ) -> Bool {
        if rows.contains(where: { $0.entry.path == path }) {
            return true
        }
        for entries in childrenByPath.values where entries.contains(where: { $0.path == path }) {
            return true
        }
        return false
    }

    nonisolated static func listLocalEntries(
        path: String,
        fileManager: FileManager = .default
    ) throws -> [TerminalFileBrowserEntry] {
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectoryFlag: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectoryFlag),
              isDirectoryFlag.boolValue else {
            throw NSError(
                domain: "TerminalFileBrowser",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Local directory not found: \(path)"]
            )
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        )

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return TerminalFileBrowserEntry(
                path: url.path,
                name: url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                size: Int64(values.fileSize ?? 0)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated private static func appendRows(
        from entries: [TerminalFileBrowserEntry],
        depth: Int,
        into rows: inout [TerminalFileBrowserRow],
        childrenByPath: [String: [TerminalFileBrowserEntry]],
        expandedPaths: Set<String>
    ) {
        for entry in entries {
            rows.append(TerminalFileBrowserRow(entry: entry, depth: depth))
            if entry.isDirectory,
               expandedPaths.contains(entry.path),
               let children = childrenByPath[entry.path] {
                appendRows(
                    from: children,
                    depth: depth + 1,
                    into: &rows,
                    childrenByPath: childrenByPath,
                    expandedPaths: expandedPaths
                )
            }
        }
    }
}
