// Extracted from AIAgentService.swift
import Foundation
import os.log

struct BroadcastContext: Sendable {
    let primarySessionID: UUID
    let allSessionIDs: [UUID]
    let sessionLabels: [UUID: String]

    var isBroadcasting: Bool { allSessionIDs.count > 1 }
}

@MainActor final class AIToolHandler {
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.ToolHandler")
    weak var service: AIAgentService?
    private let iso8601Formatter = ISO8601DateFormatter()

    init() {}
    nonisolated deinit {}

    // MARK: - Tool Dispatch

    func executeToolCalls(
        sessionID: UUID,
        broadcastContext: BroadcastContext?,
        toolCalls: [LLMToolCall],
        skills: AISkillSet = AISkillSet(),
        traceID: String
    ) async -> [LLMToolOutput] {
        var outputs: [LLMToolOutput] = []
        outputs.reserveCapacity(toolCalls.count)

        for toolCall in toolCalls {
            let toolStart = DispatchTime.now().uptimeNanoseconds
            do {
                try Task.checkCancellation()
                let output = try await executeSingleToolCall(
                    sessionID: sessionID,
                    broadcastContext: broadcastContext,
                    toolCall: toolCall,
                    skills: skills
                )
                outputs.append(.init(callID: toolCall.id, output: output))
                let toolMs = AIToolDefinitions.elapsedMillis(since: toolStart)
                Self.logger.debug(
                    "[\(traceID, privacy: .public)] tool_ok name=\(toolCall.name, privacy: .public) call_id=\(toolCall.id, privacy: .public) ms=\(toolMs) output_chars=\(output.count)"
                )
            } catch {
                let message = error is CancellationError ? "Tool call cancelled." : error.localizedDescription
                let fallback = AIToolDefinitions.errorResult(message, hint: Self.hint(for: error))
                outputs.append(.init(callID: toolCall.id, output: fallback))
                let toolMs = AIToolDefinitions.elapsedMillis(since: toolStart)
                Self.logger.error(
                    "[\(traceID, privacy: .public)] tool_failed name=\(toolCall.name, privacy: .public) call_id=\(toolCall.id, privacy: .public) ms=\(toolMs) error=\(error.localizedDescription, privacy: .private)"
                )
            }
        }

        return outputs
    }

    private func executeSingleToolCall(
        sessionID: UUID,
        broadcastContext: BroadcastContext?,
        toolCall: LLMToolCall,
        skills: AISkillSet
    ) async throws -> String {
        try Task.checkCancellation()
        let arguments = try Self.decodeArguments(
            toolName: toolCall.name,
            rawArguments: toolCall.arguments
        )

        guard let provider = service?.sessionProvider else {
            throw AIAgentServiceError.sessionNotFound
        }

        // Any connected session can be targeted by id; anything else is refused before it runs.
        if let suppliedTarget = arguments["target_session"], suppliedTarget != .null {
            guard case let .string(target) = suppliedTarget, !target.isEmpty else {
                throw AIAgentServiceError.invalidToolArguments(
                    toolName: toolCall.name, message: "target_session must be a connected session UUID or null"
                )
            }
            let isOpen = UUID(uuidString: target).map { id in
                provider.sessions.contains { $0.id == id && $0.state == .connected }
            } ?? false
            guard isOpen else {
                return AIToolDefinitions.errorResult(
                    "Unknown or disconnected session \(target)",
                    hint: "Call list_sessions for the ids of the open sessions."
                )
            }
        }

        // Remote file helpers use the same POSIX shell wrapper as execute_and_wait.
        // Refuse before sending any of that syntax to a router or appliance CLI.
        if ["search_filesystem", "search_file_contents", "read_file_chunk", "read_files", "apply_patch"].contains(toolCall.name),
           let target = resolveTargetSessions(arguments: arguments, primarySessionID: sessionID, broadcastContext: broadcastContext).first,
           provider.sessions.first(where: { $0.id == target })?.isLocal == false,
           !deviceCLITargets([target], provider: provider).isEmpty {
            return AIToolDefinitions.errorResult(
                "File tools need a POSIX shell; this session is at a device CLI prompt. Nothing was run.",
                hint: "Use run_cli_command to inspect or configure the device."
            )
        }

        switch toolCall.name {
        case "load_skill":
            let name = try Self.requiredString(key: "name", in: arguments, toolName: toolCall.name)
            guard let skill = skills.skill(named: name) else {
                let names = skills.skills.map(\.name)
                return AIToolDefinitions.errorResult(
                    "Unknown skill \(name)",
                    hint: names.isEmpty
                        ? "No skills are installed; continue without one."
                        : "Available skills: " + names.joined(separator: ", ") + "."
                )
            }
            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "name": .string(skill.name),
                "description": .string(skill.description),
                "platforms": .array(skill.platforms.map(LLMJSONValue.string)),
                "source": .string(skill.source.rawValue),
                "body": .string(skill.body),
            ]))

        case "list_sessions":
            let broadcastIDs = Set(broadcastContext.map { $0.isBroadcasting ? $0.allSessionIDs : [] } ?? [])
            return AIToolDefinitions.jsonString(from: AISessionDirectory.json(
                entries: AISessionDirectory.entries(
                    sessions: provider.sessions,
                    focusedID: sessionID,
                    broadcastIDs: broadcastIDs,
                    shellBuffers: provider.shellBuffers
                ),
                defaultTargets: AISessionDirectory.defaultTargets(focusedID: sessionID, broadcastContext: broadcastContext)
            ))

        case "get_command_output":
            let blockIDRaw = try Self.requiredString(
                key: "block_id",
                in: arguments,
                toolName: toolCall.name
            )
            guard let blockID = UUID(uuidString: blockIDRaw) else {
                throw AIAgentServiceError.invalidToolArguments(
                    toolName: toolCall.name,
                    message: "block_id must be a UUID"
                )
            }

            let maxChars = Self.clamp(
                Self.optionalInt(key: "max_chars", in: arguments) ?? 4000,
                min: 100,
                max: 16000
            )
            let resolvedID = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            ).first ?? sessionID
            let output = await provider.commandOutput(sessionID: resolvedID, blockID: blockID)
            let cappedOutput = output.map { String($0.prefix(maxChars)) }
            let totalChars = output.map { $0.count }
            let returnedChars = cappedOutput.map { $0.count }
            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "output": cappedOutput.map(LLMJSONValue.string) ?? .null,
                "max_chars": .number(Double(maxChars)),
                "returned_chars": returnedChars.map { .number(Double($0)) } ?? .null,
                "total_chars": totalChars.map { .number(Double($0)) } ?? .null,
                "truncated": .bool((totalChars ?? 0) > (returnedChars ?? 0)),
            ]))

        case "get_current_screen":
            let limit = Self.clamp(Self.optionalInt(key: "max_lines", in: arguments) ?? 200, min: 10, max: 800)
            let targets = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            )
            if targets.count == 1 {
                let target = targets[0]
                let allLines = provider.shellBuffers[target] ?? []
                let lines = Array(allLines.suffix(limit))
                var payload: [String: LLMJSONValue] = [
                    "ok": .bool(true),
                    "working_directory": provider.workingDirectoryBySessionID[target].map(LLMJSONValue.string) ?? .null,
                    "lines": .array(lines.map(LLMJSONValue.string)),
                ]
                if let session = provider.sessions.first(where: { $0.id == target }) {
                    payload["session_info"] = .object([
                        "host_label": .string(session.hostLabel),
                        "is_local": .bool(session.isLocal),
                        "state": .string(session.state.rawValue),
                    ])
                }
                return AIToolDefinitions.jsonString(from: .object(payload))
            } else if let ctx = broadcastContext {
                var sessionResults: [(sessionID: UUID, output: String)] = []
                for target in targets {
                    let allLines = provider.shellBuffers[target] ?? []
                    let lines = Array(allLines.suffix(limit))
                    sessionResults.append((target, lines.joined(separator: "\n")))
                }
                return AIToolDefinitions.jsonString(from: .object([
                    "ok": .bool(true),
                    "sessions_targeted": .number(Double(targets.count)),
                    "output": .string(formatBroadcastResult(results: sessionResults, context: ctx)),
                ]))
            } else {
                let allLines = provider.shellBuffers[sessionID] ?? []
                let lines = Array(allLines.suffix(limit))
                return AIToolDefinitions.jsonString(from: .object([
                    "ok": .bool(true),
                    "working_directory": provider.workingDirectoryBySessionID[sessionID].map(LLMJSONValue.string) ?? .null,
                    "lines": .array(lines.map(LLMJSONValue.string)),
                ]))
            }

        case "get_recent_commands", "search_terminal_history":
            let limit = Self.clamp(Self.optionalInt(key: "limit", in: arguments) ?? 20, min: 1, max: 50)
            let query = Self.optionalString(key: "query", in: arguments)
            let targets = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            )
            if targets.count == 1 {
                let blocks: [CommandBlock]
                if let query, !query.isEmpty {
                    blocks = await provider.searchCommandHistory(sessionID: targets[0], query: query, limit: limit)
                } else {
                    blocks = await provider.recentCommandBlocks(sessionID: targets[0], limit: limit)
                }
                return AIToolDefinitions.jsonString(from: .object([
                    "ok": .bool(true),
                    "results": .array(blocks.map(Self.commandBlockSummary)),
                ]))
            } else if let ctx = broadcastContext {
                var sessionResults: [(sessionID: UUID, output: String)] = []
                for target in targets {
                    let blocks: [CommandBlock]
                    if let query, !query.isEmpty {
                        blocks = await provider.searchCommandHistory(sessionID: target, query: query, limit: limit)
                    } else {
                        blocks = await provider.recentCommandBlocks(sessionID: target, limit: limit)
                    }
                    let json = AIToolDefinitions.jsonString(from: .array(blocks.map(Self.commandBlockSummary)))
                    sessionResults.append((target, json))
                }
                return AIToolDefinitions.jsonString(from: .object([
                    "ok": .bool(true),
                    "sessions_targeted": .number(Double(targets.count)),
                    "output": .string(formatBroadcastResult(results: sessionResults, context: ctx)),
                ]))
            } else {
                let blocks: [CommandBlock]
                if let query, !query.isEmpty {
                    blocks = await provider.searchCommandHistory(sessionID: sessionID, query: query, limit: limit)
                } else {
                    blocks = await provider.recentCommandBlocks(sessionID: sessionID, limit: limit)
                }
                return AIToolDefinitions.jsonString(from: .object([
                    "ok": .bool(true),
                    "results": .array(blocks.map(Self.commandBlockSummary)),
                ]))
            }

        case "search_filesystem":
            let resolvedID = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            ).first ?? sessionID
            guard let session = provider.sessions.first(where: { $0.id == resolvedID }) else {
                throw AIAgentServiceError.sessionNotFound
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

            let result: LLMJSONValue
            if session.isLocal {
                let workingDirectory = provider.workingDirectoryBySessionID[resolvedID]
                result = try await Self.searchFilesystemEntries(
                    path: searchPath,
                    namePattern: namePattern,
                    maxResults: maxResults,
                    workingDirectory: workingDirectory
                )
            } else {
                result = await searchFilesystemEntriesRemote(
                    provider: provider,
                    sessionID: resolvedID,
                    path: searchPath,
                    namePattern: namePattern,
                    maxResults: maxResults
                )
            }
            return AIToolDefinitions.jsonString(from: result)

        case "search_file_contents":
            let resolvedID = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            ).first ?? sessionID
            guard let session = provider.sessions.first(where: { $0.id == resolvedID }) else {
                throw AIAgentServiceError.sessionNotFound
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

            let result: LLMJSONValue
            if session.isLocal {
                let workingDirectory = provider.workingDirectoryBySessionID[resolvedID]
                result = try await Self.searchFileContents(
                    path: searchPath,
                    textPattern: textPattern,
                    maxResults: maxResults,
                    workingDirectory: workingDirectory
                )
            } else {
                result = await searchFileContentsRemote(
                    provider: provider,
                    sessionID: resolvedID,
                    path: searchPath,
                    textPattern: textPattern,
                    maxResults: maxResults
                )
            }
            return AIToolDefinitions.jsonString(from: result)

        case "read_file_chunk":
            let resolvedID = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            ).first ?? sessionID
            guard let session = provider.sessions.first(where: { $0.id == resolvedID }) else {
                throw AIAgentServiceError.sessionNotFound
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
                max: 500
            )

            let result: LLMJSONValue
            if session.isLocal {
                let workingDirectory = provider.workingDirectoryBySessionID[resolvedID]
                result = try await Self.readLocalFileChunk(
                    path: path,
                    startLine: startLine,
                    lineCount: lineCount,
                    workingDirectory: workingDirectory
                )
            } else {
                result = await readRemoteFileChunk(
                    provider: provider,
                    sessionID: resolvedID,
                    path: path,
                    startLine: startLine,
                    lineCount: lineCount
                )
            }
            return AIToolDefinitions.jsonString(from: result)

        case "read_files":
            let resolvedID = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            ).first ?? sessionID
            guard let session = provider.sessions.first(where: { $0.id == resolvedID }) else {
                throw AIAgentServiceError.sessionNotFound
            }

            guard case let .array(filesArray) = arguments["files"] else {
                throw AIAgentServiceError.invalidToolArguments(
                    toolName: toolCall.name,
                    message: "missing 'files' array"
                )
            }

            let capped = filesArray.prefix(10)
            var results: [LLMJSONValue] = []
            results.reserveCapacity(capped.count)

            for fileEntry in capped {
                try Task.checkCancellation()
                guard case let .object(fileDict) = fileEntry,
                      case let .string(path)? = fileDict["path"],
                      !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let start = Self.optionalInt(key: "start_line", in: fileDict),
                      let count = Self.optionalInt(key: "line_count", in: fileDict) else {
                    results.append(AIToolDefinitions.errorObject("Invalid file entry — requires path, start_line, line_count.", hint: "Give each files entry path, start_line and line_count."))
                    continue
                }

                let startLine = Self.clamp(start, min: 1, max: 2_000_000_000)
                let lineCount = Self.clamp(count, min: 1, max: 500)

                let result: LLMJSONValue
                if session.isLocal {
                    let workingDirectory = provider.workingDirectoryBySessionID[resolvedID]
                    result = (try? await Self.readLocalFileChunk(
                        path: path,
                        startLine: startLine,
                        lineCount: lineCount,
                        workingDirectory: workingDirectory
                    )) ?? AIToolDefinitions.errorObject("Failed to read: \(path)", hint: "Check the path and its permissions with search_filesystem.")
                } else {
                    result = await readRemoteFileChunk(
                        provider: provider,
                        sessionID: resolvedID,
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
                return AIToolDefinitions.errorResult(
                    message,
                    hint: "Use read_files with line_count <= 500 and iterate by start_line."
                )
            }

            let targets = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            )
            for target in targets {
                try Task.checkCancellation()
                await provider.sendShellInput(
                    sessionID: target,
                    input: command,
                    suppressEcho: false
                )
            }

            return AIToolDefinitions.jsonString(from: .object([
                "ok": .bool(true),
                "status": .string("queued"),
                "sessions_targeted": .number(Double(targets.count)),
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
                return AIToolDefinitions.errorResult(
                    message,
                    hint: "Use read_files with line_count <= 500."
                )
            }

            let targets = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            )

            // The wrapper is POSIX shell syntax; a router or switch would reject it and the
            // command would sit until the timeout.
            let deviceTargets = deviceCLITargets(targets, provider: provider)
            if !deviceTargets.isEmpty {
                let names = deviceTargets.map { target, prompt in
                    let label = provider.sessions.first { $0.id == target }?.hostLabel ?? String(target.uuidString.prefix(8))
                    return "\(label) (\(prompt))"
                }.joined(separator: ", ")
                return AIToolDefinitions.errorResult(
                    "Not a POSIX shell: \(names) is at a device CLI prompt. Nothing was run.",
                    hint: "Use run_cli_command for router, switch and appliance prompts; execute_and_wait needs a POSIX shell."
                )
            }

            if targets.count <= 1 {
                try Task.checkCancellation()
                let target = targets.first ?? sessionID
                let result = await provider.executeCommandAndWait(
                    sessionID: target,
                    command: command,
                    timeoutSeconds: timeout
                )

                if result.declinedCredential {
                    return Self.credentialDeclinedResult(label: Self.sessionLabel(target, in: provider))
                }
                if result.timedOut {
                    return AIToolDefinitions.errorResult(
                        "Command timed out after \(Int(timeout)) seconds",
                        hint: "May still be running. Use get_current_screen to check."
                    )
                }

                let maxOutputChars = 16000
                let truncated = result.output.count > maxOutputChars
                let output = truncated ? String(result.output.prefix(maxOutputChars)) : result.output

                var fields: [String: LLMJSONValue] = [
                    "ok": .bool(true),
                    "output": .string(output),
                    "exit_code": result.exitCode.map { .number(Double($0)) } ?? .null,
                    "truncated": .bool(truncated),
                    "total_chars": .number(Double(result.output.count)),
                ]
                if result.waitedForCredential {
                    fields["note"] = .string(Self.credentialWaitNote)
                }
                return AIToolDefinitions.jsonString(from: .object(fields))
            } else {
                // Sequential execution across broadcast sessions (MainActor-safe)
                var collected: [(UUID, CommandExecutionResult)] = []
                for target in targets {
                    try Task.checkCancellation()
                    let r = await provider.executeCommandAndWait(
                        sessionID: target,
                        command: command,
                        timeoutSeconds: timeout
                    )
                    collected.append((target, r))
                }

                guard let ctx = broadcastContext else {
                    // Shouldn't happen (targets.count > 1 implies broadcast)
                    return AIToolDefinitions.errorResult("Internal error: missing broadcast context", hint: "Pass one target_session per call.")
                }

                let maxOutputChars = 16000
                var sessionResults: [LLMJSONValue] = []
                for (sid, result) in collected {
                    let label = ctx.sessionLabels[sid]
                        ?? String(sid.uuidString.prefix(8))
                    let truncated = result.output.count > maxOutputChars
                    let output = truncated
                        ? String(result.output.prefix(maxOutputChars))
                        : result.output
                    var fields: [String: LLMJSONValue] = [
                        "session": .string(label),
                        "session_id": .string(sid.uuidString),
                        "output": .string(output),
                        "exit_code": result.exitCode.map { .number(Double($0)) } ?? .null,
                        "timed_out": .bool(result.timedOut),
                        "truncated": .bool(truncated),
                    ]
                    // A decline skips this host only; the others' results stand.
                    if result.declinedCredential {
                        fields["error"] = .string(Self.credentialDeclinedMessage(label: Self.sessionLabel(sid, in: provider)))
                        fields["hint"] = .string(Self.credentialDeclinedHint)
                    } else if result.waitedForCredential {
                        fields["note"] = .string(Self.credentialWaitNote)
                    }
                    sessionResults.append(.object(fields))
                }

                return AIToolDefinitions.jsonString(from: .object([
                    "ok": .bool(true),
                    "sessions_targeted": .number(Double(targets.count)),
                    "results": .array(sessionResults),
                ]))
            }

        case "get_session_info":
            // Backward-compat: still dispatches for in-flight conversations
            let resolvedID = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            ).first ?? sessionID
            guard let session = provider.sessions.first(where: { $0.id == resolvedID }) else {
                throw AIAgentServiceError.sessionNotFound
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
                "working_directory": provider.workingDirectoryBySessionID[resolvedID].map(LLMJSONValue.string) ?? .null,
            ]))

        case "apply_patch":
            let operationType = try Self.requiredString(key: "operation", in: arguments, toolName: toolCall.name)
            let path = try Self.requiredString(key: "path", in: arguments, toolName: toolCall.name)
            // Whitespace is file content, including the final added line's indentation.
            let diff: String?
            if case let .string(value)? = arguments["diff"] { diff = value } else { diff = nil }

            guard let opType = PatchOperation.OperationType(rawValue: operationType) else {
                throw AIAgentServiceError.invalidToolArguments(
                    toolName: toolCall.name,
                    message: "operation must be 'create', 'update', or 'delete'"
                )
            }
            let operation = PatchOperation(type: opType, path: path, diff: diff)

            // Delete safety gate
            if opType == .delete && !(service?.patchAllowDelete ?? false) {
                return AIToolDefinitions.errorResult("File deletion is disabled in AI settings.", hint: "Tell the user; they can turn on \"Allow file deletion\" in Settings › AI Assistant.")
            }

            let resolvedID = resolveTargetSessions(
                arguments: arguments,
                primarySessionID: sessionID,
                broadcastContext: broadcastContext
            ).first ?? sessionID
            guard let session = provider.sessions.first(where: { $0.id == resolvedID }) else {
                throw AIAgentServiceError.sessionNotFound
            }
            // An update without a diff changes nothing but would report success. A local create
            // without one makes an empty file.
            if (opType == .update && (diff ?? "").isEmpty) || (!session.isLocal && opType != .delete && diff == nil) {
                return AIToolDefinitions.errorResult(
                    "diff is required for \(operationType). Nothing was changed.",
                    hint: "Pass the change as a V4A diff in the diff field; for create, every line prefixed with +."
                )
            }

            // Approval gate
            if let svc = service, svc.patchApprovalRequired {
                let fingerprint = svc.patchApprovalTracker.fingerprint(
                    operation: operation,
                    context: resolvedID.uuidString + "\0" + (provider.workingDirectoryBySessionID[resolvedID] ?? "")
                )
                if !svc.patchApprovalTracker.isApproved(fingerprint) {
                    let (approved, remember) = await svc.requestPatchApproval(
                        operation: operation, fingerprint: fingerprint
                    )
                    try Task.checkCancellation()
                    if !approved {
                        Self.logger.info("patch_denied path=\(path, privacy: .public)")
                        return AIToolDefinitions.errorResult(
                            "Patch denied by user",
                            hint: "The user rejected this change. Ask what they want instead; don't send the same patch again."
                        )
                    }
                    if remember { svc.patchApprovalTracker.remember(fingerprint) }
                }
            }

            // Execute
            try Task.checkCancellation()
            var result: PatchResult
            var waitedForCredential = false
            if session.isLocal {
                let workingDir = provider.workingDirectoryBySessionID[resolvedID]
                    ?? FileManager.default.currentDirectoryPath
                let patcher = LocalWorkspacePatcher(workspaceRoot: URL(fileURLWithPath: workingDir))
                result = try patcher.apply(operation)
            } else {
                let outcome = await applyRemotePatch(operation, sessionID: resolvedID, provider: provider)
                try Task.checkCancellation()
                if outcome.declinedCredential {
                    Self.logger.info("patch_declined_password path=\(path, privacy: .public)")
                    return Self.credentialDeclinedResult(label: session.hostLabel)
                }
                result = outcome.result
                waitedForCredential = outcome.waitedForCredential
            }

            Self.logger.info(
                "patch_applied op=\(operationType, privacy: .public) path=\(path, privacy: .public) lines=\(result.linesChanged) ok=\(result.success)"
            )
            service?.patchResultCallback?(operation, result)

            var payload: [String: LLMJSONValue] = [
                "ok": .bool(result.success),
                "output": .string(result.output),
                "lines_changed": .number(Double(result.linesChanged)),
                "warnings": .array(result.warnings.map { .string($0) }),
            ]
            if !result.success {
                payload["hint"] = .string("Read the file again with read_files and build the diff from its current lines.")
            }
            if waitedForCredential {
                payload["note"] = .string(Self.credentialWaitNote)
            }
            return AIToolDefinitions.jsonString(from: .object(payload))

        case "run_cli_command":
            return try await executeRunCLICommand(
                sessionID: sessionID,
                broadcastContext: broadcastContext,
                arguments: arguments,
                provider: provider
            )

        case "send_input":
            return try await executeSendInput(
                sessionID: sessionID,
                broadcastContext: broadcastContext,
                arguments: arguments,
                provider: provider
            )

        default:
            return AIToolDefinitions.errorResult(
                "Unknown tool: \(toolCall.name)",
                hint: "Use one of: " + AIToolDefinitions.buildToolDefinitions().map(\.name).joined(separator: ", ") + "."
            )
        }
    }

    /// What the model can do about an error thrown while running a tool.
    static func hint(for error: Error) -> String {
        if error is CancellationError { return "Wait for the user's next instruction before running more tools." }
        switch error as? AIAgentServiceError {
        case let .invalidToolArguments(toolName, _)?:
            return "Fix the arguments to match the \(toolName) schema and call it again."
        case .sessionNotFound?:
            return "Call list_sessions and pass the id of an open session as target_session."
        default:
            return "Check the session with get_current_screen before retrying; don't repeat the call unchanged."
        }
    }

    // MARK: - Broadcast Session Resolution

    func resolveTargetSessions(
        arguments: [String: LLMJSONValue],
        primarySessionID: UUID,
        broadcastContext: BroadcastContext?
    ) -> [UUID] {
        // An explicit target_session is any open session (validated before dispatch), also one
        // outside the broadcast set; otherwise the default targets.
        if let targetStr = Self.optionalString(key: "target_session", in: arguments),
           let targetID = UUID(uuidString: targetStr) {
            return [targetID]
        }
        return AISessionDirectory.defaultTargets(focusedID: primarySessionID, broadcastContext: broadcastContext)
    }

    func formatBroadcastResult(
        results: [(sessionID: UUID, output: String)],
        context: BroadcastContext
    ) -> String {
        if results.count == 1 { return results[0].output }
        return results.map { r in
            let label = context.sessionLabels[r.sessionID]
                ?? String(r.sessionID.uuidString.prefix(8))
            return "[\(label)]\n\(r.output)"
        }.joined(separator: "\n---\n")
    }

}
