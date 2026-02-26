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

        case "send_input":
            return try await executeSendInput(
                sessionID: sessionID,
                arguments: arguments,
                provider: provider
            )

        default:
            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(false),
                "error": .string("Unknown tool"),
                "tool": .string(toolCall.name),
            ]))
        }
    }

}
