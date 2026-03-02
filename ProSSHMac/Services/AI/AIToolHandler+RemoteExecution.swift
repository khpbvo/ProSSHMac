// Extracted from AIToolHandler.swift
import Foundation
import os.log

extension AIToolHandler {

    // MARK: - Remote Execution

    struct RemoteToolExecutionResult: Sendable {
        var output: String
        var exitCode: Int?
        var timedOut: Bool
    }

    func searchFilesystemEntriesRemote(
        provider: any AIAgentSessionProviding,
        sessionID: UUID,
        path: String,
        namePattern: String,
        maxResults: Int
    ) async -> LLMJSONValue {
        let command = Self.buildRemoteFilesystemSearchCommand(
            path: path,
            namePattern: namePattern,
            maxResults: maxResults
        )
        let execution = await executeRemoteToolCommand(
            provider: provider,
            sessionID: sessionID,
            commandBody: command
        )

        if execution.timedOut {
            return .object([
                "ok": .bool(false),
                "error": .string("Remote filesystem search timed out."),
            ])
        }
        if execution.exitCode == 127 {
            return .object([
                "ok": .bool(false),
                "error": .string("Remote shell is missing required search utilities (find/head)."),
            ])
        }
        return Self.parseRemoteFilesystemSearchOutput(
            execution.output,
            path: path,
            namePattern: namePattern,
            maxResults: maxResults
        )
    }

    func searchFileContentsRemote(
        provider: any AIAgentSessionProviding,
        sessionID: UUID,
        path: String,
        textPattern: String,
        maxResults: Int
    ) async -> LLMJSONValue {
        let command = Self.buildRemoteFileContentSearchCommand(
            path: path,
            textPattern: textPattern,
            maxResults: maxResults
        )
        let execution = await executeRemoteToolCommand(
            provider: provider,
            sessionID: sessionID,
            commandBody: command
        )

        if execution.timedOut {
            return .object([
                "ok": .bool(false),
                "error": .string("Remote file-content search timed out."),
            ])
        }
        if execution.exitCode == 127 {
            return .object([
                "ok": .bool(false),
                "error": .string("Remote shell is missing required search utilities (rg/grep/head)."),
            ])
        }
        return Self.parseRemoteFileContentSearchOutput(
            execution.output,
            path: path,
            textPattern: textPattern,
            maxResults: maxResults
        )
    }

    func readRemoteFileChunk(
        provider: any AIAgentSessionProviding,
        sessionID: UUID,
        path: String,
        startLine: Int,
        lineCount: Int
    ) async -> LLMJSONValue {
        // Use the same base64 read that apply_patch uses — immune to prompt contamination.
        let readCmd = RemotePatchCommandBuilder.buildReadCommand(path: path)
        let execution = await provider.executeCommandAndWait(
            sessionID: sessionID, command: readCmd, timeoutSeconds: 15
        )

        if execution.timedOut {
            return .object([
                "ok": .bool(false),
                "error": .string("Remote file read timed out."),
            ])
        }

        guard let fullContent = RemotePatchCommandBuilder.decodeBase64FileOutput(
            execution.output
        ) else {
            // Base64 decode failed — file might not exist or is binary.
            // Fall back to sed-based read which handles not-found/not-regular tokens.
            let endLine = startLine + lineCount - 1
            let command = Self.buildRemoteReadFileChunkCommand(
                path: path, startLine: startLine, endLine: endLine
            )
            let fallback = await executeRemoteToolCommand(
                provider: provider, sessionID: sessionID, commandBody: command
            )
            if fallback.timedOut {
                return .object([
                    "ok": .bool(false),
                    "error": .string("Remote file read timed out."),
                ])
            }
            return Self.parseReadFileChunkOutput(
                fallback.output, path: path, startLine: startLine,
                lineCount: lineCount, source: "remote_command"
            )
        }

        // Extract the requested line range from the decoded content.
        let allLines = fullContent.components(separatedBy: "\n")
        let zeroStart = max(0, startLine - 1)   // startLine is 1-based
        let zeroEnd = min(allLines.count, zeroStart + lineCount)
        let slicedLines = zeroStart < allLines.count
            ? Array(allLines[zeroStart..<zeroEnd]) : []
        let content = slicedLines.joined(separator: "\n")
        let hasMore = zeroEnd < allLines.count
        let nextStart: LLMJSONValue = hasMore
            ? .number(Double(zeroEnd + 1)) : .null

        return .object([
            "ok": .bool(true),
            "content": .string(content),
            "lines_returned": .number(Double(slicedLines.count)),
            "has_more": .bool(hasMore),
            "next_start_line": nextStart,
        ])
    }

    func executeRemoteToolCommand(
        provider: any AIAgentSessionProviding,
        sessionID: UUID,
        commandBody: String,
        timeoutSeconds: TimeInterval = 20
    ) async -> RemoteToolExecutionResult {
        let marker = "__PROSSH_AI_TOOL_EXIT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let wrappedCommand =
            "{ \(commandBody); __prossh_ai_tool_status=$?; printf '\\n\(marker):%s\\n' \"$__prossh_ai_tool_status\"; }"

        await provider.sendShellInput(
            sessionID: sessionID,
            input: wrappedCommand,
            suppressEcho: true
        )

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let blocks = await provider.searchCommandHistory(
                sessionID: sessionID,
                query: marker,
                limit: 8
            )
            if let block = blocks.first(where: { $0.command.contains(marker) }) {
                let parsed = Self.parseRemoteWrappedCommandOutput(
                    block.output,
                    marker: marker
                )
                return RemoteToolExecutionResult(
                    output: parsed.output,
                    exitCode: parsed.exitCode,
                    timedOut: false
                )
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return RemoteToolExecutionResult(
            output: "",
            exitCode: nil,
            timedOut: true
        )
    }

    // MARK: - Remote Output Parsing

    static let remotePathNotFoundToken = "__PROSSH_PATH_NOT_FOUND__"
    static let remoteNotRegularFileToken = "__PROSSH_NOT_REGULAR_FILE__"
    static let remoteContentLineRegex = try! NSRegularExpression(pattern: #":([0-9]+):"#) // swiftlint:disable:this force_try

    static func parseRemoteWrappedCommandOutput(
        _ output: String,
        marker: String
    ) -> (output: String, exitCode: Int?) {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let markerPrefix = "\(marker):"
        guard let markerRange = normalized.range(of: markerPrefix, options: .backwards) else {
            return (
                normalized.trimmingCharacters(in: .whitespacesAndNewlines),
                nil
            )
        }

        let statusStart = markerRange.upperBound
        let statusSlice = normalized[statusStart...]
        let statusValue = statusSlice.prefix { $0.isNumber || $0 == "-" }
        let exitCode = Int(statusValue)

        let cleanOutput = normalized[..<markerRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(cleanOutput), exitCode)
    }

    static func parseRemoteFilesystemSearchOutput(
        _ output: String,
        path: String,
        namePattern: String,
        maxResults: Int
    ) -> LLMJSONValue {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        if lines.contains(Self.remotePathNotFoundToken) {
            return .object([
                "ok": .bool(false),
                "error": .string("Path does not exist: \(path)"),
            ])
        }

        var results: [LLMJSONValue] = []
        results.reserveCapacity(min(lines.count, maxResults))

        for line in lines.prefix(maxResults) {
            guard let parsed = Self.parseRemoteFilesystemResultLine(line) else { continue }
            results.append(.object([
                "path": .string(parsed.path),
                "is_directory": .bool(parsed.isDirectory),
            ]))
        }

        var payload: [String: LLMJSONValue] = [
            "ok": .bool(true),
            "truncated": .bool(results.count >= maxResults),
            "results": .array(results),
            "source": .string("remote_command"),
        ]
        if results.isEmpty, !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["parse_warning"] = .string("Remote output was returned but could not be fully structured.")
            payload["raw_output_preview"] = .string(Self.remoteOutputPreview(normalized))
        }
        return .object(payload)
    }

    static func parseRemoteFileContentSearchOutput(
        _ output: String,
        path: String,
        textPattern: String,
        maxResults: Int
    ) -> LLMJSONValue {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        if lines.contains(Self.remotePathNotFoundToken) {
            return .object([
                "ok": .bool(false),
                "error": .string("Path does not exist: \(path)"),
            ])
        }

        var matches: [LLMJSONValue] = []
        matches.reserveCapacity(min(lines.count, maxResults))

        for line in lines.prefix(maxResults) {
            guard let parsed = Self.parseRemoteGrepMatchLine(line) else { continue }
            matches.append(.object([
                "path": .string(parsed.path),
                "line_number": .number(Double(parsed.lineNumber)),
                "line": .string(parsed.line),
            ]))
        }

        var payload: [String: LLMJSONValue] = [
            "ok": .bool(true),
            "truncated": .bool(matches.count >= maxResults),
            "matches": .array(groupMatchesByFile(matches)),
            "source": .string("remote_command"),
        ]
        if matches.isEmpty, !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["parse_warning"] = .string("Remote output was returned but could not be fully structured.")
            payload["raw_output_preview"] = .string(Self.remoteOutputPreview(normalized))
        }
        return .object(payload)
    }

    static func parseRemoteFilesystemResultLine(_ line: String) -> (path: String, isDirectory: Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let kindAndPath: (kind: String, path: String)?
        if let tabIndex = trimmed.firstIndex(of: "\t") {
            let kind = trimmed[..<tabIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let path = trimmed[trimmed.index(after: tabIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            kindAndPath = (String(kind), String(path))
        } else {
            let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true) { $0.isWhitespace }
            guard parts.count == 2 else { return nil }
            kindAndPath = (String(parts[0]), String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let kindAndPath else { return nil }
        guard let indicator = kindAndPath.kind.lowercased().first, indicator == "f" || indicator == "d" else {
            return nil
        }
        let parsedPath = kindAndPath.path
        guard !parsedPath.isEmpty else { return nil }
        guard parsedPath.contains("/") || parsedPath.hasPrefix(".") || parsedPath.hasPrefix("~") else {
            return nil
        }

        return (parsedPath, indicator == "d")
    }

    static func remoteOutputPreview(_ normalizedOutput: String, maxCharacters: Int = 3000) -> String {
        let trimmed = normalizedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters))
    }

    static func parseRemoteGrepMatchLine(_ line: String) -> (path: String, lineNumber: Int, line: String)? {
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        guard let match = remoteContentLineRegex.firstMatch(in: line, options: [], range: fullRange) else {
            return nil
        }

        let lineNumberRange = match.range(at: 1)
        guard lineNumberRange.location != NSNotFound else { return nil }
        let lineNumberString = nsLine.substring(with: lineNumberRange)
        guard let lineNumber = Int(lineNumberString) else { return nil }

        let prefixRange = NSRange(location: 0, length: match.range.location)
        let suffixStart = match.range.location + match.range.length
        guard suffixStart <= nsLine.length else { return nil }
        let suffixRange = NSRange(location: suffixStart, length: nsLine.length - suffixStart)

        let path = nsLine.substring(with: prefixRange)
        let content = nsLine.substring(with: suffixRange)
        guard !path.isEmpty else { return nil }
        return (path, lineNumber, content)
    }

    // MARK: - Remote Command Building

    static func buildRemoteFilesystemSearchCommand(
        path: String,
        namePattern: String,
        maxResults: Int
    ) -> String {
        let escapedPath = shellSingleQuoted(path)
        let escapedPattern = shellSingleQuoted(namePattern)
        let limit = "\(maxResults)"

        return """
        __prossh_root=\(escapedPath); \
        case "$__prossh_root" in "~") __prossh_root="$HOME" ;; "~/"*) __prossh_root="$HOME/${__prossh_root#~/}" ;; esac; \
        if [ ! -e "$__prossh_root" ]; then printf '\(remotePathNotFoundToken)\\n'; \
        else __prossh_pattern=\(escapedPattern); \
        case "$__prossh_pattern" in *[\\*\\?\\[]*) __prossh_find_pattern="$__prossh_pattern" ;; *) __prossh_find_pattern="*$__prossh_pattern*" ;; esac; \
        if find "$__prossh_root" -maxdepth 0 -printf '' >/dev/null 2>&1; then \
        find "$__prossh_root" -iname "$__prossh_find_pattern" -printf '%y\\t%p\\n' 2>/dev/null | head -n \(limit); \
        else \
        find "$__prossh_root" -iname "$__prossh_find_pattern" 2>/dev/null | while IFS= read -r __prossh_path; do \
        if [ -d "$__prossh_path" ]; then __prossh_kind=d; else __prossh_kind=f; fi; \
        printf '%s\\t%s\\n' "$__prossh_kind" "$__prossh_path"; \
        done | head -n \(limit); \
        fi; fi
        """
    }

    static func buildRemoteFileContentSearchCommand(
        path: String,
        textPattern: String,
        maxResults: Int
    ) -> String {
        let escapedPath = shellSingleQuoted(path)
        let escapedPattern = shellSingleQuoted(textPattern)
        let limit = "\(maxResults)"

        return """
        __prossh_root=\(escapedPath); \
        case "$__prossh_root" in "~") __prossh_root="$HOME" ;; "~/"*) __prossh_root="$HOME/${__prossh_root#~/}" ;; esac; \
        if [ ! -e "$__prossh_root" ]; then printf '\(remotePathNotFoundToken)\\n'; \
        else __prossh_pattern=\(escapedPattern); \
        if command -v rg >/dev/null 2>&1; then \
        rg --line-number --with-filename --ignore-case --color never --no-messages -- "$__prossh_pattern" "$__prossh_root" | head -n \(limit); \
        else \
        grep -RIn --binary-files=without-match -- "$__prossh_pattern" "$__prossh_root" 2>/dev/null | head -n \(limit); \
        fi; fi
        """
    }

    static func buildRemoteReadFileChunkCommand(
        path: String,
        startLine: Int,
        endLine: Int
    ) -> String {
        let escapedPath = shellSingleQuoted(path)
        return """
        __prossh_file=\(escapedPath); \
        case "$__prossh_file" in "~") __prossh_file="$HOME" ;; "~/"*) __prossh_file="$HOME/${__prossh_file#~/}" ;; esac; \
        if [ ! -e "$__prossh_file" ]; then printf '\(remotePathNotFoundToken)\\n'; \
        elif [ ! -f "$__prossh_file" ]; then printf '\(remoteNotRegularFileToken)\\n'; \
        else sed -n '\(startLine),\(endLine)p' "$__prossh_file"; fi
        """
    }

    static func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: #"'\"'\"'"#)
        return "'\(escaped)'"
    }
}
