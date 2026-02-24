// Extracted from OpenAIAgentService.swift
import Foundation
import os.log

@MainActor final class AIToolHandler {
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.ToolHandler")
    weak var service: OpenAIAgentService?
    private let iso8601Formatter = ISO8601DateFormatter()

    init() {}
    nonisolated deinit {}

    // MARK: - Tool Dispatch

    func executeToolCalls(
        sessionID: UUID,
        toolCalls: [OpenAIResponsesResponse.ToolCall],
        traceID: String
    ) async -> [OpenAIResponsesToolOutput] {
        var outputs: [OpenAIResponsesToolOutput] = []
        outputs.reserveCapacity(toolCalls.count)

        for toolCall in toolCalls {
            let toolStart = DispatchTime.now().uptimeNanoseconds
            do {
                let output = try await executeSingleToolCall(
                    sessionID: sessionID,
                    toolCall: toolCall
                )
                outputs.append(.init(callID: toolCall.id, output: output))
                let toolMs = AIToolDefinitions.elapsedMillis(since: toolStart)
                Self.logger.debug(
                    "[\(traceID, privacy: .public)] tool_ok name=\(toolCall.name, privacy: .public) call_id=\(toolCall.id, privacy: .public) ms=\(toolMs) output_chars=\(output.count)"
                )
            } catch {
                let fallback = AIToolDefinitions.jsonString(
                    from: .object([
                        "ok": .bool(false),
                        "error": .string(error.localizedDescription),
                        "tool": .string(toolCall.name),
                    ])
                )
                outputs.append(.init(callID: toolCall.id, output: fallback))
                let toolMs = AIToolDefinitions.elapsedMillis(since: toolStart)
                Self.logger.error(
                    "[\(traceID, privacy: .public)] tool_failed name=\(toolCall.name, privacy: .public) call_id=\(toolCall.id, privacy: .public) ms=\(toolMs) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return outputs
    }

    private func executeSingleToolCall(
        sessionID: UUID,
        toolCall: OpenAIResponsesResponse.ToolCall
    ) async throws -> String {
        let arguments = try Self.decodeArguments(
            toolName: toolCall.name,
            rawArguments: toolCall.arguments
        )

        guard let provider = service?.sessionProvider else {
            throw OpenAIAgentServiceError.sessionNotFound
        }

        switch toolCall.name {
        case "search_terminal_history":
            let query = try Self.requiredString(
                key: "query",
                in: arguments,
                toolName: toolCall.name
            )
            let limit = Self.clamp(Self.optionalInt(key: "limit", in: arguments) ?? 20, min: 1, max: 50)
            let blocks = await provider.searchCommandHistory(
                sessionID: sessionID,
                query: query,
                limit: limit
            )
            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "results": .array(blocks.map(Self.commandBlockSummary)),
            ]))

        case "get_command_output":
            let blockIDRaw = try Self.requiredString(
                key: "block_id",
                in: arguments,
                toolName: toolCall.name
            )
            guard let blockID = UUID(uuidString: blockIDRaw) else {
                throw OpenAIAgentServiceError.invalidToolArguments(
                    toolName: toolCall.name,
                    message: "block_id must be a UUID"
                )
            }

            let maxChars = Self.clamp(
                Self.optionalInt(key: "max_chars", in: arguments) ?? 4000,
                min: 100,
                max: 16000
            )
            let output = await provider.commandOutput(sessionID: sessionID, blockID: blockID)
            let cappedOutput = output.map { String($0.prefix(maxChars)) }
            let totalChars = output.map { $0.count }
            let returnedChars = cappedOutput.map { $0.count }
            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "output": cappedOutput.map(OpenAIJSONValue.string) ?? .null,
                "max_chars": .number(Double(maxChars)),
                "returned_chars": returnedChars.map { .number(Double($0)) } ?? .null,
                "total_chars": totalChars.map { .number(Double($0)) } ?? .null,
                "truncated": .bool((totalChars ?? 0) > (returnedChars ?? 0)),
            ]))

        case "get_current_screen":
            let limit = Self.clamp(Self.optionalInt(key: "max_lines", in: arguments) ?? 100, min: 10, max: 300)
            let allLines = provider.shellBuffers[sessionID] ?? []
            let lines = Array(allLines.suffix(limit))
            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "working_directory": provider.workingDirectoryBySessionID[sessionID].map(OpenAIJSONValue.string) ?? .null,
                "lines": .array(lines.map(OpenAIJSONValue.string)),
            ]))

        case "get_recent_commands":
            let limit = Self.clamp(Self.optionalInt(key: "limit", in: arguments) ?? 20, min: 1, max: 50)
            let blocks = await provider.recentCommandBlocks(sessionID: sessionID, limit: limit)
            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "results": .array(blocks.map(Self.commandBlockSummary)),
            ]))

        case "search_filesystem":
            guard let session = provider.sessions.first(where: { $0.id == sessionID }) else {
                throw OpenAIAgentServiceError.sessionNotFound
            }

            let searchPath = try Self.requiredString(
                key: "path",
                in: arguments,
                toolName: toolCall.name
            )
            let namePattern = try Self.requiredString(
                key: "name_pattern",
                in: arguments,
                toolName: toolCall.name
            )
            let maxResults = Self.clamp(
                try Self.requiredInt(
                    key: "max_results",
                    in: arguments,
                    toolName: toolCall.name
                ),
                min: 1,
                max: 200
            )

            let result: OpenAIJSONValue
            if session.isLocal {
                let workingDirectory = provider.workingDirectoryBySessionID[sessionID]
                result = try await Self.searchFilesystemEntries(
                    path: searchPath,
                    namePattern: namePattern,
                    maxResults: maxResults,
                    workingDirectory: workingDirectory
                )
            } else {
                result = await searchFilesystemEntriesRemote(
                    provider: provider,
                    sessionID: sessionID,
                    path: searchPath,
                    namePattern: namePattern,
                    maxResults: maxResults
                )
            }
            return AIToolDefinitions.jsonString(from: result)

        case "search_file_contents":
            guard let session = provider.sessions.first(where: { $0.id == sessionID }) else {
                throw OpenAIAgentServiceError.sessionNotFound
            }

            let searchPath = try Self.requiredString(
                key: "path",
                in: arguments,
                toolName: toolCall.name
            )
            let textPattern = try Self.requiredString(
                key: "text_pattern",
                in: arguments,
                toolName: toolCall.name
            )
            let maxResults = Self.clamp(
                try Self.requiredInt(
                    key: "max_results",
                    in: arguments,
                    toolName: toolCall.name
                ),
                min: 1,
                max: 200
            )

            let result: OpenAIJSONValue
            if session.isLocal {
                let workingDirectory = provider.workingDirectoryBySessionID[sessionID]
                result = try await Self.searchFileContents(
                    path: searchPath,
                    textPattern: textPattern,
                    maxResults: maxResults,
                    workingDirectory: workingDirectory
                )
            } else {
                result = await searchFileContentsRemote(
                    provider: provider,
                    sessionID: sessionID,
                    path: searchPath,
                    textPattern: textPattern,
                    maxResults: maxResults
                )
            }
            return AIToolDefinitions.jsonString(from: result)

        case "read_file_chunk":
            guard let session = provider.sessions.first(where: { $0.id == sessionID }) else {
                throw OpenAIAgentServiceError.sessionNotFound
            }

            let path = try Self.requiredString(
                key: "path",
                in: arguments,
                toolName: toolCall.name
            )
            let startLine = Self.clamp(
                try Self.requiredInt(
                    key: "start_line",
                    in: arguments,
                    toolName: toolCall.name
                ),
                min: 1,
                max: 2_000_000_000
            )
            let lineCount = Self.clamp(
                try Self.requiredInt(
                    key: "line_count",
                    in: arguments,
                    toolName: toolCall.name
                ),
                min: 1,
                max: 200
            )

            let result: OpenAIJSONValue
            if session.isLocal {
                let workingDirectory = provider.workingDirectoryBySessionID[sessionID]
                result = try await Self.readLocalFileChunk(
                    path: path,
                    startLine: startLine,
                    lineCount: lineCount,
                    workingDirectory: workingDirectory
                )
            } else {
                result = await readRemoteFileChunk(
                    provider: provider,
                    sessionID: sessionID,
                    path: path,
                    startLine: startLine,
                    lineCount: lineCount
                )
            }
            return AIToolDefinitions.jsonString(from: result)

        case "read_files":
            guard let session = provider.sessions.first(where: { $0.id == sessionID }) else {
                throw OpenAIAgentServiceError.sessionNotFound
            }

            guard case let .array(filesArray) = arguments["files"] else {
                throw OpenAIAgentServiceError.invalidToolArguments(
                    toolName: toolCall.name,
                    message: "missing 'files' array"
                )
            }

            let capped = filesArray.prefix(10)
            var results: [OpenAIJSONValue] = []
            results.reserveCapacity(capped.count)

            for fileEntry in capped {
                guard case let .object(fileDict) = fileEntry,
                      case let .string(path)? = fileDict["path"],
                      case let .number(startNum)? = fileDict["start_line"],
                      case let .number(countNum)? = fileDict["line_count"] else {
                    results.append(.object([
                        "ok": .bool(false),
                        "error": .string("Invalid file entry — requires path, start_line, line_count."),
                    ]))
                    continue
                }

                let startLine = Self.clamp(Int(startNum.rounded()), min: 1, max: 2_000_000_000)
                let lineCount = Self.clamp(Int(countNum.rounded()), min: 1, max: 200)

                let result: OpenAIJSONValue
                if session.isLocal {
                    let workingDirectory = provider.workingDirectoryBySessionID[sessionID]
                    result = (try? await Self.readLocalFileChunk(
                        path: path,
                        startLine: startLine,
                        lineCount: lineCount,
                        workingDirectory: workingDirectory
                    )) ?? .object([
                        "ok": .bool(false),
                        "error": .string("Failed to read: \(path)"),
                    ])
                } else {
                    result = await readRemoteFileChunk(
                        provider: provider,
                        sessionID: sessionID,
                        path: path,
                        startLine: startLine,
                        lineCount: lineCount
                    )
                }
                results.append(result)
            }

            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "results": .array(results),
            ]))

        case "execute_command":
            let command = try Self.requiredString(
                key: "command",
                in: arguments,
                toolName: toolCall.name
            )

            if let message = Self.readBoundViolationMessage(for: command) {
                return AIToolDefinitions.jsonString(from: .object([
                    "ok": .bool(false),
                    "status": .string("read_window_required"),
                    "message": .string(message),
                    "hint": .string("Use read_file_chunk with line_count <= 200 and iterate by start_line."),
                ]))
            }

            await provider.sendShellInput(
                sessionID: sessionID,
                input: command,
                suppressEcho: false
            )

            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "status": .string("queued"),
            ]))

        case "execute_and_wait":
            let command = try Self.requiredString(
                key: "command",
                in: arguments,
                toolName: toolCall.name
            )
            let timeout = TimeInterval(Self.clamp(
                Self.optionalInt(key: "timeout_seconds", in: arguments) ?? 30,
                min: 5,
                max: 60
            ))

            if let message = Self.readBoundViolationMessage(for: command) {
                return AIToolDefinitions.jsonString(from: .object([
                    "ok": .bool(false),
                    "status": .string("read_window_required"),
                    "message": .string(message),
                    "hint": .string("Use read_file_chunk with line_count <= 200."),
                ]))
            }

            let result = await provider.executeCommandAndWait(
                sessionID: sessionID,
                command: command,
                timeoutSeconds: timeout
            )

            if result.timedOut {
                return AIToolDefinitions.jsonString(from: .object([
                    "ok": .bool(false),
                    "status": .string("timed_out"),
                    "message": .string("Command did not complete within \(Int(timeout)) seconds. It may still be running. Use get_current_screen to check."),
                ]))
            }

            let maxOutputChars = 16000
            let truncated = result.output.count > maxOutputChars
            let output = truncated ? String(result.output.prefix(maxOutputChars)) : result.output

            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "output": .string(output),
                "exit_code": result.exitCode.map { .number(Double($0)) } ?? .null,
                "truncated": .bool(truncated),
                "total_chars": .number(Double(result.output.count)),
            ]))

        case "get_session_info":
            guard let session = provider.sessions.first(where: { $0.id == sessionID }) else {
                throw OpenAIAgentServiceError.sessionNotFound
            }

            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "state": .string(session.state.rawValue),
                "host_label": .string(session.hostLabel),
                "username": .string(session.username),
                "hostname": .string(session.hostname),
                "port": .number(Double(session.port)),
                "is_local": .bool(session.isLocal),
                "started_at": .string(iso8601Formatter.string(from: session.startedAt)),
                "working_directory": provider.workingDirectoryBySessionID[sessionID].map(OpenAIJSONValue.string) ?? .null,
            ]))

        case "apply_patch":
            let operationType = try Self.requiredString(key: "operation", in: arguments, toolName: toolCall.name)
            let path = try Self.requiredString(key: "path", in: arguments, toolName: toolCall.name)
            let diff = Self.optionalString(key: "diff", in: arguments)

            guard let opType = PatchOperation.OperationType(rawValue: operationType) else {
                throw OpenAIAgentServiceError.invalidToolArguments(
                    toolName: toolCall.name,
                    message: "operation must be 'create', 'update', or 'delete'"
                )
            }
            let operation = PatchOperation(type: opType, path: path, diff: diff)

            // Delete safety gate
            if opType == .delete && !(service?.patchAllowDelete ?? false) {
                return AIToolDefinitions.jsonString(from: .object([
                    "ok": .bool(false),
                    "error": .string("File deletion is disabled in AI settings."),
                ]))
            }

            guard let session = provider.sessions.first(where: { $0.id == sessionID }) else {
                throw OpenAIAgentServiceError.sessionNotFound
            }

            // Approval gate
            if let svc = service, svc.patchApprovalRequired {
                let fingerprint = svc.patchApprovalTracker.fingerprint(operation: operation)
                if !svc.patchApprovalTracker.isApproved(fingerprint) {
                    let (approved, remember) = await svc.requestPatchApproval(
                        operation: operation, fingerprint: fingerprint
                    )
                    if !approved {
                        Self.logger.info("patch_denied path=\(path, privacy: .public)")
                        return AIToolDefinitions.jsonString(from: .object([
                            "ok": .bool(false),
                            "status": .string("denied_by_user"),
                        ]))
                    }
                    if remember { svc.patchApprovalTracker.remember(fingerprint) }
                }
            }

            // Execute
            let result: PatchResult
            if session.isLocal {
                let workingDir = provider.workingDirectoryBySessionID[sessionID]
                    ?? FileManager.default.currentDirectoryPath
                let patcher = LocalWorkspacePatcher(workspaceRoot: URL(fileURLWithPath: workingDir))
                result = try patcher.apply(operation)
            } else {
                let command = RemotePatchCommandBuilder.buildCommand(for: operation)
                let execution = await provider.executeCommandAndWait(
                    sessionID: sessionID, command: command, timeoutSeconds: 15
                )
                result = RemotePatchCommandBuilder.parseResult(execution.output, operation: operation)
            }

            Self.logger.info(
                "patch_applied op=\(operationType, privacy: .public) path=\(path, privacy: .public) lines=\(result.linesChanged) ok=\(result.success)"
            )
            service?.patchResultCallback?(operation, result)

            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(result.success),
                "output": .string(result.output),
                "lines_changed": .number(Double(result.linesChanged)),
                "warnings": .array(result.warnings.map { .string($0) }),
            ]))

        default:
            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(false),
                "error": .string("Unknown tool"),
                "tool": .string(toolCall.name),
            ]))
        }
    }

    // MARK: - Argument Parsing Helpers

    private static func decodeArguments(
        toolName: String,
        rawArguments: String
    ) throws -> [String: OpenAIJSONValue] {
        let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw OpenAIAgentServiceError.invalidToolArguments(
                toolName: toolName,
                message: "arguments are not valid UTF-8"
            )
        }
        do {
            return try JSONDecoder().decode([String: OpenAIJSONValue].self, from: data)
        } catch {
            throw OpenAIAgentServiceError.invalidToolArguments(
                toolName: toolName,
                message: "arguments must be a JSON object"
            )
        }
    }

    private static func requiredString(
        key: String,
        in arguments: [String: OpenAIJSONValue],
        toolName: String
    ) throws -> String {
        guard let raw = arguments[key] else {
            throw OpenAIAgentServiceError.invalidToolArguments(
                toolName: toolName,
                message: "missing '\(key)'"
            )
        }
        switch raw {
        case let .string(value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        default:
            break
        }
        throw OpenAIAgentServiceError.invalidToolArguments(
            toolName: toolName,
            message: "'\(key)' must be a non-empty string"
        )
    }

    private static func requiredInt(
        key: String,
        in arguments: [String: OpenAIJSONValue],
        toolName: String
    ) throws -> Int {
        guard let raw = arguments[key] else {
            throw OpenAIAgentServiceError.invalidToolArguments(
                toolName: toolName,
                message: "missing '\(key)'"
            )
        }
        switch raw {
        case let .number(number):
            return Int(number.rounded())
        case let .string(string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed) {
                return value
            }
        default:
            break
        }
        throw OpenAIAgentServiceError.invalidToolArguments(
            toolName: toolName,
            message: "'\(key)' must be an integer"
        )
    }

    private static func optionalString(
        key: String,
        in arguments: [String: OpenAIJSONValue]
    ) -> String? {
        guard let value = arguments[key] else { return nil }
        switch value {
        case let .string(s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default: return nil
        }
    }

    private static func optionalInt(
        key: String,
        in arguments: [String: OpenAIJSONValue]
    ) -> Int? {
        guard let value = arguments[key] else {
            return nil
        }
        switch value {
        case let .number(number):
            return Int(number.rounded())
        case let .string(string):
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.min(maxValue, Swift.max(minValue, value))
    }

    // MARK: - Remote Execution

    private struct RemoteToolExecutionResult: Sendable {
        var output: String
        var exitCode: Int?
        var timedOut: Bool
    }

    private func searchFilesystemEntriesRemote(
        provider: any OpenAIAgentSessionProviding,
        sessionID: UUID,
        path: String,
        namePattern: String,
        maxResults: Int
    ) async -> OpenAIJSONValue {
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

    private func searchFileContentsRemote(
        provider: any OpenAIAgentSessionProviding,
        sessionID: UUID,
        path: String,
        textPattern: String,
        maxResults: Int
    ) async -> OpenAIJSONValue {
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

    private func readRemoteFileChunk(
        provider: any OpenAIAgentSessionProviding,
        sessionID: UUID,
        path: String,
        startLine: Int,
        lineCount: Int
    ) async -> OpenAIJSONValue {
        let endLine = startLine + lineCount - 1
        let command = Self.buildRemoteReadFileChunkCommand(
            path: path,
            startLine: startLine,
            endLine: endLine
        )
        let execution = await executeRemoteToolCommand(
            provider: provider,
            sessionID: sessionID,
            commandBody: command
        )

        if execution.timedOut {
            return .object([
                "ok": .bool(false),
                "error": .string("Remote file read timed out."),
            ])
        }
        if execution.exitCode == 127 {
            return .object([
                "ok": .bool(false),
                "error": .string("Remote shell is missing required utility: sed."),
            ])
        }
        return Self.parseReadFileChunkOutput(
            execution.output,
            path: path,
            startLine: startLine,
            lineCount: lineCount,
            source: "remote_command"
        )
    }

    private func executeRemoteToolCommand(
        provider: any OpenAIAgentSessionProviding,
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

    private static let remotePathNotFoundToken = "__PROSSH_PATH_NOT_FOUND__"
    private static let remoteNotRegularFileToken = "__PROSSH_NOT_REGULAR_FILE__"
    private static let remoteContentLineRegex = try! NSRegularExpression(pattern: #":([0-9]+):"#) // swiftlint:disable:this force_try

    private static func parseRemoteWrappedCommandOutput(
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

    private static func parseRemoteFilesystemSearchOutput(
        _ output: String,
        path: String,
        namePattern: String,
        maxResults: Int
    ) -> OpenAIJSONValue {
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

        var results: [OpenAIJSONValue] = []
        results.reserveCapacity(min(lines.count, maxResults))

        for line in lines.prefix(maxResults) {
            guard let parsed = Self.parseRemoteFilesystemResultLine(line) else { continue }
            results.append(.object([
                "path": .string(parsed.path),
                "is_directory": .bool(parsed.isDirectory),
            ]))
        }

        var payload: [String: OpenAIJSONValue] = [
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

    private static func parseRemoteFileContentSearchOutput(
        _ output: String,
        path: String,
        textPattern: String,
        maxResults: Int
    ) -> OpenAIJSONValue {
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

        var matches: [OpenAIJSONValue] = []
        matches.reserveCapacity(min(lines.count, maxResults))

        for line in lines.prefix(maxResults) {
            guard let parsed = Self.parseRemoteContentMatchLine(line) else { continue }
            matches.append(.object([
                "path": .string(parsed.path),
                "line_number": .number(Double(parsed.lineNumber)),
                "line": .string(parsed.line),
            ]))
        }

        var payload: [String: OpenAIJSONValue] = [
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

    private static func parseRemoteFilesystemResultLine(_ line: String) -> (path: String, isDirectory: Bool)? {
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

    private static func remoteOutputPreview(_ normalizedOutput: String, maxCharacters: Int = 3000) -> String {
        let trimmed = normalizedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters))
    }

    private static func parseRemoteContentMatchLine(_ line: String) -> (path: String, lineNumber: Int, line: String)? {
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

    private static func buildRemoteFilesystemSearchCommand(
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

    private static func buildRemoteFileContentSearchCommand(
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

    private static func buildRemoteReadFileChunkCommand(
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

    private static func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: #"'\"'\"'"#)
        return "'\(escaped)'"
    }

    // MARK: - Local Filesystem (nonisolated — spawns detached tasks)

    nonisolated static func searchFilesystemEntries(
        path: String,
        namePattern: String,
        maxResults: Int,
        workingDirectory: String?
    ) async throws -> OpenAIJSONValue {
        try await Task.detached(priority: .userInitiated) {
            let rootURL = try resolvedLocalSearchURL(path: path, workingDirectory: workingDirectory)
            let fileManager = FileManager.default
            var results: [OpenAIJSONValue] = []
            let maxScannedEntries = max(2_000, maxResults * 300)
            var scannedEntries = 0

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                return OpenAIJSONValue.object([
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
    ) async throws -> OpenAIJSONValue {
        try await Task.detached(priority: .userInitiated) {
            let rootURL = try resolvedLocalSearchURL(path: path, workingDirectory: workingDirectory)
            let fileManager = FileManager.default
            var matches: [OpenAIJSONValue] = []
            let maxScannedFiles = max(500, maxResults * 80)
            let maxFileBytes = 1_500_000
            var scannedFiles = 0

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                return OpenAIJSONValue.object([
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
    ) async throws -> OpenAIJSONValue {
        try await Task.detached(priority: .userInitiated) {
            let fileURL = try resolvedLocalSearchURL(path: path, workingDirectory: workingDirectory)
            let fileManager = FileManager.default

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
                return OpenAIJSONValue.object([
                    "ok": .bool(false),
                    "error": .string("Path does not exist: \(fileURL.path)"),
                ])
            }
            guard !isDirectory.boolValue else {
                return OpenAIJSONValue.object([
                    "ok": .bool(false),
                    "error": .string("Path is a directory, not a regular file: \(fileURL.path)"),
                ])
            }

            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            if data.contains(0) {
                return OpenAIJSONValue.object([
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
                return OpenAIJSONValue.object([
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
                return OpenAIJSONValue.object([
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
            let nextStart: OpenAIJSONValue = hasMore
                ? .number(Double(endExclusive + 1))
                : .null

            return OpenAIJSONValue.object([
                "ok": .bool(true),
                "content": .string(chunkContent),
                "lines_returned": .number(Double(slice.count)),
                "has_more": .bool(hasMore),
                "next_start_line": nextStart,
            ])
        }.value
    }

    private nonisolated static func resolvedLocalSearchURL(path: String, workingDirectory: String?) throws -> URL {
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

    private nonisolated static func filenameMatches(_ filename: String, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("*") || trimmed.contains("?") {
            let wildcard = NSPredicate(format: "SELF LIKE[c] %@", trimmed)
            return wildcard.evaluate(with: filename)
        }
        return filename.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private nonisolated static func groupMatchesByFile(_ matches: [OpenAIJSONValue]) -> [OpenAIJSONValue] {
        var fileOrder: [String] = []
        var hitsByFile: [String: [OpenAIJSONValue]] = [:]

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

    private nonisolated static func contentMatchesForFile(
        fileURL: URL,
        textPattern: String,
        maxRemaining: Int,
        maxFileBytes: Int
    ) -> [OpenAIJSONValue]? {
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

        var results: [OpenAIJSONValue] = []
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

    // MARK: - Output Helpers

    private static func commandBlockSummary(_ block: CommandBlock) -> OpenAIJSONValue {
        .object([
            "id": .string(block.id.uuidString.lowercased()),
            "command": .string(block.command),
            "output_preview": .string(String(block.output.prefix(150))),
            "started_at": .string(ISO8601DateFormatter().string(from: block.startedAt)),
            "exit_code": block.exitCode.map { .number(Double($0)) } ?? .null,
        ])
    }

    private static func parseReadFileChunkOutput(
        _ output: String,
        path: String,
        startLine: Int,
        lineCount: Int,
        source: String
    ) -> OpenAIJSONValue {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if lines.contains(remotePathNotFoundToken) {
            return .object([
                "ok": .bool(false),
                "error": .string("Path does not exist: \(path)"),
            ])
        }
        if lines.contains(remoteNotRegularFileToken) {
            return .object([
                "ok": .bool(false),
                "error": .string("Path is not a regular file: \(path)"),
            ])
        }

        let boundedCount = max(1, min(200, lineCount))
        let content = lines.joined(separator: "\n")
        let hasMore = lines.count >= boundedCount
        let nextStart: OpenAIJSONValue = hasMore
            ? .number(Double(max(1, startLine) + lines.count))
            : .null

        return .object([
            "ok": .bool(true),
            "content": .string(content),
            "lines_returned": .number(Double(lines.count)),
            "has_more": .bool(hasMore),
            "next_start_line": nextStart,
        ])
    }

    private static func readBoundViolationMessage(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if lowered.hasPrefix("cat "), !lowered.contains("|"), !lowered.contains(">") {
            return "Full-file reads via 'cat' are disabled for AI execution. Read files in chunks of at most 200 lines."
        }

        if let n = firstCapturedInt(in: lowered, pattern: #"\bhead\s+-n\s+([0-9]+)\b"#), n > 200 {
            return "'head -n \(n)' exceeds the 200-line limit for AI file reads."
        }

        if let n = firstCapturedInt(in: lowered, pattern: #"\btail\s+-n\s+([0-9]+)\b"#), n > 200 {
            return "'tail -n \(n)' exceeds the 200-line limit for AI file reads."
        }

        if let range = firstCapturedRange(
            in: lowered,
            pattern: #"\bsed\s+-n\s+['\"]?([0-9]+),([0-9]+)p['\"]?"#
        ) {
            let requested = (range.end - range.start) + 1
            if requested > 200 {
                return "'sed -n \(range.start),\(range.end)p' exceeds the 200-line limit for AI file reads."
            }
        }

        if (lowered.contains("python") || lowered.contains("python3")) &&
            (lowered.contains("read_text(") || lowered.contains(".read()")) {
            return "Scripted full-file reads are disabled for AI execution. Read files in chunks of at most 200 lines."
        }

        return nil
    }

    private static func firstCapturedInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              match.numberOfRanges > 1 else {
            return nil
        }
        let capture = match.range(at: 1)
        guard capture.location != NSNotFound else { return nil }
        return Int(nsText.substring(with: capture))
    }

    private static func firstCapturedRange(in text: String, pattern: String) -> (start: Int, end: Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              match.numberOfRanges > 2 else {
            return nil
        }
        let startRange = match.range(at: 1)
        let endRange = match.range(at: 2)
        guard startRange.location != NSNotFound, endRange.location != NSNotFound else { return nil }
        guard let start = Int(nsText.substring(with: startRange)),
              let end = Int(nsText.substring(with: endRange)) else {
            return nil
        }
        return (start: start, end: end)
    }
}
