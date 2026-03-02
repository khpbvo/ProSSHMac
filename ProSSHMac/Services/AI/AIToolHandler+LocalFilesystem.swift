// Extracted from AIToolHandler.swift
import Foundation

extension AIToolHandler {

    // MARK: - Local Filesystem (nonisolated — spawns detached tasks)

    nonisolated static func searchFilesystemEntries(
        path: String,
        namePattern: String,
        maxResults: Int,
        workingDirectory: String?
    ) async throws -> LLMJSONValue {
        try await Task.detached(priority: .userInitiated) {
            let rootURL = try resolvedLocalSearchURL(path: path, workingDirectory: workingDirectory)
            let fileManager = FileManager.default
            var results: [LLMJSONValue] = []
            let maxScannedEntries = max(2_000, maxResults * 300)
            var scannedEntries = 0

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                return LLMJSONValue.object([
                    "ok": .bool(false),
                    "error": .string("Path does not exist: \(rootURL.path)"),
                ])
            }

            if !isDirectory.boolValue {
                if filenameMatches(rootURL.lastPathComponent, pattern: namePattern) {
                    results.append(.object([
                        "path": .string(rootURL.path),
                        "is_directory": .bool(false),
                    ]))
                }
                return .object([
                    "ok": .bool(true),
                    "scanned_entries": .number(1),
                    "truncated": .bool(false),
                    "results": .array(results),
                ])
            }

            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                return .object([
                    "ok": .bool(false),
                    "error": .string("Failed to enumerate directory: \(rootURL.path)"),
                ])
            }

            while let item = enumerator.nextObject() as? URL {
                scannedEntries += 1
                if scannedEntries > maxScannedEntries { break }
                if results.count >= maxResults { break }

                let name = item.lastPathComponent
                if filenameMatches(name, pattern: namePattern) {
                    let values = try? item.resourceValues(forKeys: Set(keys))
                    let directory = values?.isDirectory ?? false
                    results.append(.object([
                        "path": .string(item.path),
                        "is_directory": .bool(directory),
                    ]))
                }
            }

            let truncated = scannedEntries > maxScannedEntries || results.count >= maxResults
            return .object([
                "ok": .bool(true),
                "scanned_entries": .number(Double(scannedEntries)),
                "truncated": .bool(truncated),
                "results": .array(results),
            ])
        }.value
    }

    nonisolated static func searchFileContents(
        path: String,
        textPattern: String,
        maxResults: Int,
        workingDirectory: String?
    ) async throws -> LLMJSONValue {
        try await Task.detached(priority: .userInitiated) {
            let rootURL = try resolvedLocalSearchURL(path: path, workingDirectory: workingDirectory)
            let fileManager = FileManager.default
            var matches: [LLMJSONValue] = []
            let maxScannedFiles = max(500, maxResults * 80)
            let maxFileBytes = 1_500_000
            var scannedFiles = 0

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                return LLMJSONValue.object([
                    "ok": .bool(false),
                    "error": .string("Path does not exist: \(rootURL.path)"),
                ])
            }

            if !isDirectory.boolValue {
                if let fileMatches = contentMatchesForFile(
                    fileURL: rootURL,
                    textPattern: textPattern,
                    maxRemaining: maxResults,
                    maxFileBytes: maxFileBytes
                ) {
                    matches.append(contentsOf: fileMatches)
                }
                return .object([
                    "ok": .bool(true),
                    "scanned_files": .number(1),
                    "truncated": .bool(matches.count >= maxResults),
                    "matches": .array(groupMatchesByFile(Array(matches.prefix(maxResults)))),
                ])
            }

            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                return .object([
                    "ok": .bool(false),
                    "error": .string("Failed to enumerate directory: \(rootURL.path)"),
                ])
            }

            while let item = enumerator.nextObject() as? URL {
                if matches.count >= maxResults { break }
                if scannedFiles >= maxScannedFiles { break }
                guard let values = try? item.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else {
                    continue
                }

                scannedFiles += 1
                let remaining = maxResults - matches.count
                if let fileMatches = contentMatchesForFile(
                    fileURL: item,
                    textPattern: textPattern,
                    maxRemaining: remaining,
                    maxFileBytes: maxFileBytes
                ) {
                    matches.append(contentsOf: fileMatches)
                }
            }

            let truncated = matches.count >= maxResults || scannedFiles >= maxScannedFiles
            return .object([
                "ok": .bool(true),
                "scanned_files": .number(Double(scannedFiles)),
                "truncated": .bool(truncated),
                "matches": .array(groupMatchesByFile(Array(matches.prefix(maxResults)))),
            ])
        }.value
    }

    nonisolated static func readLocalFileChunk(
        path: String,
        startLine: Int,
        lineCount: Int,
        workingDirectory: String?
    ) async throws -> LLMJSONValue {
        try await Task.detached(priority: .userInitiated) {
            let fileURL = try resolvedLocalSearchURL(path: path, workingDirectory: workingDirectory)
            let fileManager = FileManager.default

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
                return LLMJSONValue.object([
                    "ok": .bool(false),
                    "error": .string("Path does not exist: \(fileURL.path)"),
                ])
            }
            guard !isDirectory.boolValue else {
                return LLMJSONValue.object([
                    "ok": .bool(false),
                    "error": .string("Path is a directory, not a regular file: \(fileURL.path)"),
                ])
            }

            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            if data.contains(0) {
                return LLMJSONValue.object([
                    "ok": .bool(false),
                    "error": .string("File appears to be binary and cannot be read as text."),
                ])
            }

            let content: String
            if let utf8 = String(data: data, encoding: .utf8) {
                content = utf8
            } else if let latin = String(data: data, encoding: .isoLatin1) {
                content = latin
            } else {
                return LLMJSONValue.object([
                    "ok": .bool(false),
                    "error": .string("Unable to decode file as UTF-8/Latin-1 text."),
                ])
            }

            let splitLines = content
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
            let safeStartLine = max(1, startLine)
            let safeLineCount = max(1, min(200, lineCount))
            let startIndex = safeStartLine - 1

            if startIndex >= splitLines.count {
                return LLMJSONValue.object([
                    "ok": .bool(true),
                    "content": .string(""),
                    "lines_returned": .number(0),
                    "has_more": .bool(false),
                    "next_start_line": .null,
                ])
            }

            let endExclusive = min(splitLines.count, startIndex + safeLineCount)
            let slice = splitLines[startIndex..<endExclusive]
            let chunkContent = slice.map(String.init).joined(separator: "\n")
            let hasMore = endExclusive < splitLines.count
            let nextStart: LLMJSONValue = hasMore
                ? .number(Double(endExclusive + 1))
                : .null

            return LLMJSONValue.object([
                "ok": .bool(true),
                "content": .string(chunkContent),
                "lines_returned": .number(Double(slice.count)),
                "has_more": .bool(hasMore),
                "next_start_line": nextStart,
            ])
        }.value
    }

    nonisolated static func resolvedLocalSearchURL(path: String, workingDirectory: String?) throws -> URL {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedPath = (trimmedPath as NSString).expandingTildeInPath

        let resolvedPath: String
        if expandedPath.hasPrefix("/") {
            resolvedPath = expandedPath
        } else if let workingDirectory, !workingDirectory.isEmpty {
            resolvedPath = URL(fileURLWithPath: workingDirectory)
                .appendingPathComponent(expandedPath)
                .path
        } else {
            resolvedPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(expandedPath)
                .path
        }

        return URL(fileURLWithPath: resolvedPath).standardizedFileURL
    }

    nonisolated static func filenameMatches(_ filename: String, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("*") || trimmed.contains("?") {
            let wildcard = NSPredicate(format: "SELF LIKE[c] %@", trimmed)
            return wildcard.evaluate(with: filename)
        }
        return filename.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    nonisolated static func groupMatchesByFile(_ matches: [LLMJSONValue]) -> [LLMJSONValue] {
        var fileOrder: [String] = []
        var hitsByFile: [String: [LLMJSONValue]] = [:]

        for match in matches {
            guard case let .object(dict) = match,
                  case let .string(path)? = dict["path"],
                  case let .number(lineNum)? = dict["line_number"],
                  case let .string(lineText)? = dict["line"] else { continue }
            if hitsByFile[path] == nil {
                fileOrder.append(path)
            }
            hitsByFile[path, default: []].append(.object([
                "n": .number(lineNum),
                "line": .string(lineText),
            ]))
        }

        return fileOrder.map { path in
            .object([
                "path": .string(path),
                "hits": .array(hitsByFile[path] ?? []),
            ])
        }
    }

    nonisolated static func contentMatchesForFile(
        fileURL: URL,
        textPattern: String,
        maxRemaining: Int,
        maxFileBytes: Int
    ) -> [LLMJSONValue]? {
        guard maxRemaining > 0 else { return nil }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return nil }
        guard data.count <= maxFileBytes else { return nil }
        if data.contains(0) { return nil }

        let content: String
        if let utf8 = String(data: data, encoding: .utf8) {
            content = utf8
        } else if let latin = String(data: data, encoding: .isoLatin1) {
            content = latin
        } else {
            return nil
        }

        let pattern = textPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }

        var results: [LLMJSONValue] = []
        results.reserveCapacity(min(8, maxRemaining))

        for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if results.count >= maxRemaining { break }
            let lineString = String(line)
            if lineString.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                results.append(.object([
                    "path": .string(fileURL.path),
                    "line_number": .number(Double(index + 1)),
                    "line": .string(lineString),
                ]))
            }
        }
        return results.isEmpty ? nil : results
    }
}
