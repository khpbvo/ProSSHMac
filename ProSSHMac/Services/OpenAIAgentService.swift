// swiftlint:disable file_length
import Foundation
import os.log

@MainActor
protocol OpenAIAgentServicing {
    var toolDefinitions: [OpenAIResponsesToolDefinition] { get }
    func clearConversation(sessionID: UUID)
    func generateReply(
        sessionID: UUID,
        prompt: String
    ) async throws -> OpenAIAgentReply
}

struct OpenAIAgentReply: Sendable, Equatable {
    var text: String
    var responseID: String
    var toolCallsExecuted: Int
}

enum OpenAIAgentServiceError: LocalizedError, Equatable {
    case sessionNotFound
    case emptyPrompt
    case requestTimedOut(seconds: Int)
    case toolLoopExceeded(limit: Int)
    case invalidToolArguments(toolName: String, message: String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "No active session is selected for AI tools."
        case .emptyPrompt:
            return "Prompt cannot be empty."
        case let .requestTimedOut(seconds):
            return "AI request timed out after \(seconds) seconds."
        case let .toolLoopExceeded(limit):
            return "AI tool loop exceeded \(limit) iterations."
        case let .invalidToolArguments(toolName, message):
            return "Tool '\(toolName)' received invalid arguments: \(message)"
        }
    }
}

@MainActor
protocol OpenAIAgentSessionProviding: AnyObject {
    var sessions: [Session] { get }
    var shellBuffers: [UUID: [String]] { get }
    var workingDirectoryBySessionID: [UUID: String] { get }
    var bytesReceivedBySessionID: [UUID: Int64] { get }
    var bytesSentBySessionID: [UUID: Int64] { get }

    func recentCommandBlocks(sessionID: UUID, limit: Int) async -> [CommandBlock]
    func searchCommandHistory(sessionID: UUID, query: String, limit: Int) async -> [CommandBlock]
    func commandOutput(sessionID: UUID, blockID: UUID) async -> String?
    func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool) async
    func executeCommandAndWait(sessionID: UUID, command: String, timeoutSeconds: TimeInterval) async -> CommandExecutionResult
}

struct CommandExecutionResult: Sendable {
    var output: String
    var exitCode: Int?
    var timedOut: Bool
    var blockID: UUID?
}

extension SessionManager: OpenAIAgentSessionProviding {}

@MainActor
final class OpenAIAgentService: OpenAIAgentServicing {
    private static let logger = Logger(subsystem: "com.prossh", category: "AICopilot.Agent")
    let toolDefinitions: [OpenAIResponsesToolDefinition]

    private let responsesService: any OpenAIResponsesServicing
    private let sessionProvider: any OpenAIAgentSessionProviding
    private let requestTimeoutSeconds: Int
    private let maxToolIterations: Int
    private let persistConversationContext: Bool
    private var previousResponseIDBySessionID: [UUID: String] = [:]
    private let iso8601Formatter = ISO8601DateFormatter()

    init(
        responsesService: any OpenAIResponsesServicing,
        sessionProvider: any OpenAIAgentSessionProviding,
        requestTimeoutSeconds: Int = 60,
        maxToolIterations: Int = 50,
        persistConversationContext: Bool = true
    ) {
        self.responsesService = responsesService
        self.sessionProvider = sessionProvider
        self.requestTimeoutSeconds = max(10, requestTimeoutSeconds)
        self.maxToolIterations = max(1, maxToolIterations)
        self.persistConversationContext = persistConversationContext
        self.toolDefinitions = Self.buildToolDefinitions()
    }

    func clearConversation(sessionID: UUID) {
        previousResponseIDBySessionID.removeValue(forKey: sessionID)
    }

    func generateReply(
        sessionID: UUID,
        prompt: String
    ) async throws -> OpenAIAgentReply {
        let traceID = Self.shortTraceID()
        let turnStart = DispatchTime.now().uptimeNanoseconds
        guard sessionProvider.sessions.contains(where: { $0.id == sessionID }) else {
            Self.logger.error("[\(traceID, privacy: .public)] session_not_found session=\(Self.shortSessionID(sessionID), privacy: .public)")
            throw OpenAIAgentServiceError.sessionNotFound
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            Self.logger.error("[\(traceID, privacy: .public)] empty_prompt session=\(Self.shortSessionID(sessionID), privacy: .public)")
            throw OpenAIAgentServiceError.emptyPrompt
        }
        Self.logger.info(
            "[\(traceID, privacy: .public)] turn_start session=\(Self.shortSessionID(sessionID), privacy: .public) prompt_chars=\(trimmedPrompt.count) persist_context=\(self.persistConversationContext)"
        )

        let directActionMode = Self.isDirectActionPrompt(trimmedPrompt)
        let activeToolDefinitions = directActionMode
            ? Self.directActionToolDefinitions(from: toolDefinitions)
            : toolDefinitions
        let iterationLimit = directActionMode
            ? min(maxToolIterations, 15)
            : maxToolIterations
        Self.logger.debug(
            "[\(traceID, privacy: .public)] turn_mode direct_action=\(directActionMode) tools=\(activeToolDefinitions.count) iteration_limit=\(iterationLimit)"
        )

        var previousResponseID = persistConversationContext
            ? previousResponseIDBySessionID[sessionID]
            : nil
        var pendingMessages: [OpenAIResponsesMessage] = [
            .init(role: .developer, text: Self.developerPrompt()),
            .init(role: .user, text: trimmedPrompt),
        ]
        var pendingToolOutputs: [OpenAIResponsesToolOutput] = []
        var totalToolCalls = 0

        for iteration in 1...iterationLimit {
            let iterationStart = DispatchTime.now().uptimeNanoseconds
            let request = OpenAIResponsesRequest(
                messages: pendingMessages,
                previousResponseID: previousResponseID,
                tools: activeToolDefinitions,
                toolOutputs: pendingToolOutputs
            )
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_start i=\(iteration) prev_id_present=\(request.previousResponseID != nil) pending_messages=\(request.messages.count) pending_tool_outputs=\(request.toolOutputs.count)"
            )

            let response = try await createResponseWithRecovery(
                request: request,
                previousResponseID: &previousResponseID,
                traceID: traceID
            )
            let responseMs = Self.elapsedMillis(since: iterationStart)

            previousResponseID = response.id
            if persistConversationContext {
                previousResponseIDBySessionID[sessionID] = response.id
            } else {
                previousResponseIDBySessionID.removeValue(forKey: sessionID)
            }

            let toolCalls = response.toolCalls
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_response i=\(iteration) response_ms=\(responseMs) response_id=\(response.id, privacy: .public) tool_calls=\(toolCalls.count) text_chars=\(response.text.count)"
            )
            guard !toolCalls.isEmpty else {
                let totalMs = Self.elapsedMillis(since: turnStart)
                Self.logger.info(
                    "[\(traceID, privacy: .public)] turn_complete session=\(Self.shortSessionID(sessionID), privacy: .public) iterations=\(iteration) tool_calls=\(totalToolCalls) total_ms=\(totalMs) reply_chars=\(response.text.count)"
                )
                return OpenAIAgentReply(
                    text: response.text,
                    responseID: response.id,
                    toolCallsExecuted: totalToolCalls
                )
            }

            totalToolCalls += toolCalls.count
            let toolStart = DispatchTime.now().uptimeNanoseconds
            pendingToolOutputs = await executeToolCalls(
                sessionID: sessionID,
                toolCalls: toolCalls,
                traceID: traceID
            )
            let toolMs = Self.elapsedMillis(since: toolStart)
            Self.logger.debug(
                "[\(traceID, privacy: .public)] iteration_tools i=\(iteration) tool_calls=\(toolCalls.count) tool_ms=\(toolMs)"
            )
            pendingMessages = []
        }

        let totalMs = Self.elapsedMillis(since: turnStart)
        Self.logger.error(
            "[\(traceID, privacy: .public)] turn_failed_tool_loop session=\(Self.shortSessionID(sessionID), privacy: .public) limit=\(iterationLimit) total_ms=\(totalMs)"
        )
        throw OpenAIAgentServiceError.toolLoopExceeded(limit: iterationLimit)
    }

    private func createResponseWithRecovery(
        request: OpenAIResponsesRequest,
        previousResponseID: inout String?,
        traceID: String
    ) async throws -> OpenAIResponsesResponse {
        let service = responsesService
        do {
            return try await runWithTimeout {
                try await service.createResponse(request)
            }
        } catch let error as OpenAIResponsesServiceError {
            guard case let .httpError(statusCode, message) = error,
                  statusCode == 400 || statusCode == 404,
                  request.previousResponseID != nil,
                  Self.isPreviousResponseIDError(message: message) else {
                Self.logger.error(
                    "[\(traceID, privacy: .public)] response_failed status_recoverable=false error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }

            Self.logger.warning(
                "[\(traceID, privacy: .public)] previous_response_recovery triggered=true status=\(statusCode) message=\(message, privacy: .public)"
            )
            previousResponseID = nil
            let retryRequest = OpenAIResponsesRequest(
                messages: request.messages,
                previousResponseID: nil,
                tools: request.tools,
                toolOutputs: request.toolOutputs
            )
            return try await runWithTimeout {
                try await service.createResponse(retryRequest)
            }
        }
    }

    private func runWithTimeout<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutSeconds = requestTimeoutSeconds
        let timeoutNanoseconds = UInt64(timeoutSeconds) * 1_000_000_000
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw OpenAIAgentServiceError.requestTimedOut(seconds: timeoutSeconds)
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw OpenAIAgentServiceError.requestTimedOut(seconds: timeoutSeconds)
            }
            group.cancelAll()
            return result
        }
    }

    private func executeToolCalls(
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
                let toolMs = Self.elapsedMillis(since: toolStart)
                Self.logger.debug(
                    "[\(traceID, privacy: .public)] tool_ok name=\(toolCall.name, privacy: .public) call_id=\(toolCall.id, privacy: .public) ms=\(toolMs) output_chars=\(output.count)"
                )
            } catch {
                let fallback = Self.jsonString(
                    from: .object([
                        "ok": .bool(false),
                        "error": .string(error.localizedDescription),
                        "tool": .string(toolCall.name),
                    ])
                )
                outputs.append(.init(callID: toolCall.id, output: fallback))
                let toolMs = Self.elapsedMillis(since: toolStart)
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

        switch toolCall.name {
        case "search_terminal_history":
            let query = try Self.requiredString(
                key: "query",
                in: arguments,
                toolName: toolCall.name
            )
            let limit = Self.clamp(Self.optionalInt(key: "limit", in: arguments) ?? 20, min: 1, max: 50)
            let blocks = await sessionProvider.searchCommandHistory(
                sessionID: sessionID,
                query: query,
                limit: limit
            )
            return Self.jsonString(from: .object([
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
            let output = await sessionProvider.commandOutput(sessionID: sessionID, blockID: blockID)
            let cappedOutput = output.map { String($0.prefix(maxChars)) }
            let totalChars = output.map { $0.count }
            let returnedChars = cappedOutput.map { $0.count }
            return Self.jsonString(from: .object([
                "ok": .bool(true),
                "output": cappedOutput.map(OpenAIJSONValue.string) ?? .null,
                "max_chars": .number(Double(maxChars)),
                "returned_chars": returnedChars.map { .number(Double($0)) } ?? .null,
                "total_chars": totalChars.map { .number(Double($0)) } ?? .null,
                "truncated": .bool((totalChars ?? 0) > (returnedChars ?? 0)),
            ]))

        case "get_current_screen":
            let limit = Self.clamp(Self.optionalInt(key: "max_lines", in: arguments) ?? 100, min: 10, max: 300)
            let allLines = sessionProvider.shellBuffers[sessionID] ?? []
            let lines = Array(allLines.suffix(limit))
            return Self.jsonString(from: .object([
                "ok": .bool(true),
                "working_directory": sessionProvider.workingDirectoryBySessionID[sessionID].map(OpenAIJSONValue.string) ?? .null,
                "lines": .array(lines.map(OpenAIJSONValue.string)),
            ]))

        case "get_recent_commands":
            let limit = Self.clamp(Self.optionalInt(key: "limit", in: arguments) ?? 20, min: 1, max: 50)
            let blocks = await sessionProvider.recentCommandBlocks(sessionID: sessionID, limit: limit)
            return Self.jsonString(from: .object([
                "ok": .bool(true),
                "results": .array(blocks.map(Self.commandBlockSummary)),
            ]))

        case "search_filesystem":
            guard let session = sessionProvider.sessions.first(where: { $0.id == sessionID }) else {
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
                let workingDirectory = sessionProvider.workingDirectoryBySessionID[sessionID]
                result = try await Self.searchFilesystemEntries(
                    path: searchPath,
                    namePattern: namePattern,
                    maxResults: maxResults,
                    workingDirectory: workingDirectory
                )
            } else {
                result = await searchFilesystemEntriesRemote(
                    sessionID: sessionID,
                    path: searchPath,
                    namePattern: namePattern,
                    maxResults: maxResults
                )
            }
            return Self.jsonString(from: result)

        case "search_file_contents":
            guard let session = sessionProvider.sessions.first(where: { $0.id == sessionID }) else {
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
                let workingDirectory = sessionProvider.workingDirectoryBySessionID[sessionID]
                result = try await Self.searchFileContents(
                    path: searchPath,
                    textPattern: textPattern,
                    maxResults: maxResults,
                    workingDirectory: workingDirectory
                )
            } else {
                result = await searchFileContentsRemote(
                    sessionID: sessionID,
                    path: searchPath,
                    textPattern: textPattern,
                    maxResults: maxResults
                )
            }
            return Self.jsonString(from: result)

        case "read_file_chunk":
            guard let session = sessionProvider.sessions.first(where: { $0.id == sessionID }) else {
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
                let workingDirectory = sessionProvider.workingDirectoryBySessionID[sessionID]
                result = try await Self.readLocalFileChunk(
                    path: path,
                    startLine: startLine,
                    lineCount: lineCount,
                    workingDirectory: workingDirectory
                )
            } else {
                result = await readRemoteFileChunk(
                    sessionID: sessionID,
                    path: path,
                    startLine: startLine,
                    lineCount: lineCount
                )
            }
            return Self.jsonString(from: result)

        case "read_files":
            guard let session = sessionProvider.sessions.first(where: { $0.id == sessionID }) else {
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
                    let workingDirectory = sessionProvider.workingDirectoryBySessionID[sessionID]
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
                        sessionID: sessionID,
                        path: path,
                        startLine: startLine,
                        lineCount: lineCount
                    )
                }
                results.append(result)
            }

            return Self.jsonString(from: .object([
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
                return Self.jsonString(from: .object([
                    "ok": .bool(false),
                    "status": .string("read_window_required"),
                    "message": .string(message),
                    "hint": .string("Use read_file_chunk with line_count <= 200 and iterate by start_line."),
                ]))
            }

            await sessionProvider.sendShellInput(
                sessionID: sessionID,
                input: command,
                suppressEcho: false
            )

            return Self.jsonString(from: .object([
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
                return Self.jsonString(from: .object([
                    "ok": .bool(false),
                    "status": .string("read_window_required"),
                    "message": .string(message),
                    "hint": .string("Use read_file_chunk with line_count <= 200."),
                ]))
            }

            let result = await sessionProvider.executeCommandAndWait(
                sessionID: sessionID,
                command: command,
                timeoutSeconds: timeout
            )

            if result.timedOut {
                return Self.jsonString(from: .object([
                    "ok": .bool(false),
                    "status": .string("timed_out"),
                    "message": .string("Command did not complete within \(Int(timeout)) seconds. It may still be running. Use get_current_screen to check."),
                ]))
            }

            let maxOutputChars = 16000
            let truncated = result.output.count > maxOutputChars
            let output = truncated ? String(result.output.prefix(maxOutputChars)) : result.output

            return Self.jsonString(from: .object([
                "ok": .bool(true),
                "output": .string(output),
                "exit_code": result.exitCode.map { .number(Double($0)) } ?? .null,
                "truncated": .bool(truncated),
                "total_chars": .number(Double(result.output.count)),
            ]))

        case "get_session_info":
            guard let session = sessionProvider.sessions.first(where: { $0.id == sessionID }) else {
                throw OpenAIAgentServiceError.sessionNotFound
            }

            return Self.jsonString(from: .object([
                "ok": .bool(true),
                "state": .string(session.state.rawValue),
                "host_label": .string(session.hostLabel),
                "username": .string(session.username),
                "hostname": .string(session.hostname),
                "port": .number(Double(session.port)),
                "is_local": .bool(session.isLocal),
                "started_at": .string(iso8601Formatter.string(from: session.startedAt)),
                "working_directory": sessionProvider.workingDirectoryBySessionID[sessionID].map(OpenAIJSONValue.string) ?? .null,
            ]))

        default:
            return Self.jsonString(from: .object([
                "ok": .bool(false),
                "error": .string("Unknown tool"),
                "tool": .string(toolCall.name),
            ]))
        }
    }

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

    private struct RemoteToolExecutionResult: Sendable {
        var output: String
        var exitCode: Int?
        var timedOut: Bool
    }

    private func searchFilesystemEntriesRemote(
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
        sessionID: UUID,
        commandBody: String,
        timeoutSeconds: TimeInterval = 20
    ) async -> RemoteToolExecutionResult {
        let marker = "__PROSSH_AI_TOOL_EXIT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let wrappedCommand =
            "{ \(commandBody); __prossh_ai_tool_status=$?; printf '\\n\(marker):%s\\n' \"$__prossh_ai_tool_status\"; }"

        await sessionProvider.sendShellInput(
            sessionID: sessionID,
            input: wrappedCommand,
            suppressEcho: true
        )

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let blocks = await sessionProvider.searchCommandHistory(
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

    private static let remotePathNotFoundToken = "__PROSSH_PATH_NOT_FOUND__"
    private static let remoteNotRegularFileToken = "__PROSSH_NOT_REGULAR_FILE__"
    private static let remoteContentLineRegex = try! NSRegularExpression(pattern: #":([0-9]+):"#)

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

    private nonisolated static func searchFilesystemEntries(
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

    private nonisolated static func searchFileContents(
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

    private nonisolated static func readLocalFileChunk(
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

    private static func commandBlockSummary(_ block: CommandBlock) -> OpenAIJSONValue {
        .object([
            "id": .string(block.id.uuidString.lowercased()),
            "command": .string(block.command),
            "output_preview": .string(String(block.output.prefix(150))),
            "started_at": .string(ISO8601DateFormatter().string(from: block.startedAt)),
            "exit_code": block.exitCode.map { .number(Double($0)) } ?? .null,
        ])
    }

    private static func isPreviousResponseIDError(message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("previous_response_id") ||
            lowercased.contains("previous response")
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

    private static func developerPrompt() -> String {
        """
        You are ProSSH Terminal Copilot — an expert terminal agent with full read/write access to the user's terminal session.

        CAPABILITIES:
        - Execute any shell command and read its output directly (execute_and_wait).
        - Read the live terminal screen, structured command history, and individual command outputs.
        - Search and read files on the local or remote filesystem.
        - Run multi-step workflows: execute a command, inspect the result, decide next steps, repeat.
        - Access structured command blocks with UUIDs, exit codes, and timestamps.

        COMMAND EXECUTION:
        - For one-shot commands (ls, grep, git, make, curl, cat via pipe, etc.), use execute_and_wait — it runs the command AND returns the output and exit code in one step.
        - For interactive or long-running commands (vim, nano, top, tail -f, ssh, htop), use execute_command (fire-and-forget), then get_current_screen to see the result.
        - Always check the exit_code after execute_and_wait: 0 means success, non-zero means failure. Investigate failures by reading the output.
        - You can chain multiple commands to accomplish complex tasks. Do not stop after one command if the task requires more.

        TERMINAL CONTEXT:
        - The terminal has shell integration that tracks command blocks with IDs and exit codes.
        - Use get_recent_commands to see recent command history with structured metadata (id, command, output_preview, exit_code, started_at).
        - Use get_command_output with a block_id to retrieve the full output of any previous command.
        - Use get_current_screen to see what is currently visible on the terminal.
        - Use search_terminal_history to find specific commands or output text from earlier in the session.

        APPROACH:
        - Think step-by-step. When asked to accomplish a task, plan your approach, execute, verify, and iterate.
        - Proactively explore when it helps answer the question — check file contents, run diagnostic commands, inspect logs.
        - If a command fails, read the error output, diagnose the issue, and suggest or attempt a fix.
        - Gather sufficient evidence before answering. If you need to run a command to confirm something, do it.
        - When the user asks you to do something (install, configure, debug, deploy, fix), actually do it — don't just explain how.
        - Do not repeat the same tool call with identical arguments.

        SAFETY:
        - Never run destructive commands (rm -rf /, mkfs, dd if=/dev/zero, DROP TABLE, etc.) without explicit user confirmation.
        - Never expose secrets, API keys, passwords, or private keys in your responses.
        - If a command could have irreversible side effects, mention the risk and ask for confirmation before executing.
        - Do not modify system files (/etc, /boot, etc.) unless the user specifically asks.

        FORMAT:
        - Use readable markdown with short paragraphs, bullet points, and code blocks.
        - Add a brief heading when it improves scanning.
        - Show relevant command output in fenced code blocks.
        - Be concise but thorough.
        """
    }

    private static func jsonString(from value: OpenAIJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"failed_to_encode_tool_output"}"#
        }
        return string
    }

    private nonisolated static func shortTraceID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private nonisolated static func shortSessionID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private nonisolated static func elapsedMillis(since startNanoseconds: UInt64) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = now >= startNanoseconds ? now - startNanoseconds : 0
        return Int(delta / 1_000_000)
    }

    private nonisolated static func directActionToolDefinitions(
        from tools: [OpenAIResponsesToolDefinition]
    ) -> [OpenAIResponsesToolDefinition] {
        let allowedNames: Set<String> = [
            "execute_command", "execute_and_wait", "get_current_screen",
            "get_session_info", "get_recent_commands", "get_command_output",
        ]
        let filtered = tools.filter { allowedNames.contains($0.name) }
        return filtered.isEmpty ? tools : filtered
    }

    private nonisolated static func isDirectActionPrompt(_ prompt: String) -> Bool {
        let lowered = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let directPrefixes = ["run ", "execute ", "cd "]
        return directPrefixes.contains(where: { lowered.hasPrefix($0) })
    }

    private static func buildToolDefinitions() -> [OpenAIResponsesToolDefinition] {
        let commonNoExtraProperties = OpenAIJSONValue.bool(false)

        return [
            OpenAIResponsesToolDefinition(
                name: "search_terminal_history",
                description: "Search through the session's command history. Searches both command text and output. Returns matching CommandBlocks with: id (UUID), command, output_preview, started_at, exit_code. Use the returned block id with get_command_output to retrieve full output.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query for command text or output."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (1-50)."),
                        ]),
                    ]),
                    "required": .array([.string("query"), .string("limit")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_command_output",
                description: "Retrieve the full output of a previously executed command by its block ID. Get block IDs from search_terminal_history or get_recent_commands. Returns the output text, capped to max_chars (100-16000). Indicates if output was truncated and total character count.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "block_id": .object([
                            "type": .string("string"),
                            "description": .string("UUID of the command block."),
                        ]),
                        "max_chars": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum characters to return (100-16000)."),
                        ]),
                    ]),
                    "required": .array([.string("block_id"), .string("max_chars")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_current_screen",
                description: "Read the current visible terminal screen contents. Returns an array of visible lines and the current working directory. Use after execute_command (fire-and-forget) to see what happened, or to understand the current state of the terminal.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "max_lines": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum lines to return (10-300)."),
                        ]),
                    ]),
                    "required": .array([.string("max_lines")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "search_filesystem",
                description: "Search for files and directories by name pattern in the active session's filesystem. Works on both local and remote (SSH) sessions. Supports glob patterns (*.swift, *.log) and substring matching. Returns paths with is_directory flag.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Root path to search (absolute, ~, or relative to current working directory)."),
                        ]),
                        "name_pattern": .object([
                            "type": .string("string"),
                            "description": .string("Filename pattern to match (substring or wildcard)."),
                        ]),
                        "max_results": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum results to return (1-200)."),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("name_pattern"), .string("max_results")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "search_file_contents",
                description: "Search for text inside files under a directory tree. Works on both local and remote sessions. Uses ripgrep (rg) if available, falls back to grep. Returns matching lines grouped by file with line numbers.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Root path to search (absolute, ~, or relative to current working directory)."),
                        ]),
                        "text_pattern": .object([
                            "type": .string("string"),
                            "description": .string("Text pattern to find in files."),
                        ]),
                        "max_results": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum results to return (1-200)."),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("text_pattern"), .string("max_results")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "read_file_chunk",
                description: "Read a window of lines from a text file. Returns content, lines_returned, has_more flag, and next_start_line for pagination. Max 200 lines per call. Use read_files for batch reading multiple files.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("File path to read (absolute, ~, or relative to current working directory)."),
                        ]),
                        "start_line": .object([
                            "type": .string("integer"),
                            "description": .string("Line number to start reading from (1 or greater)."),
                        ]),
                        "line_count": .object([
                            "type": .string("integer"),
                            "description": .string("Number of lines to read (1-200)."),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("start_line"), .string("line_count")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "read_files",
                description: "Read chunks from up to 10 files in a single call. More efficient than multiple read_file_chunk calls. Each file entry needs path, start_line, and line_count.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "files": .object([
                            "type": .string("array"),
                            "description": .string("Array of file read requests (1-10 items)."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "path": .object([
                                        "type": .string("string"),
                                        "description": .string("File path (absolute, ~, or relative)."),
                                    ]),
                                    "start_line": .object([
                                        "type": .string("integer"),
                                        "description": .string("Line number to start reading from (1 or greater)."),
                                    ]),
                                    "line_count": .object([
                                        "type": .string("integer"),
                                        "description": .string("Number of lines to read (1-200)."),
                                    ]),
                                ]),
                                "required": .array([.string("path"), .string("start_line"), .string("line_count")]),
                                "additionalProperties": commonNoExtraProperties,
                            ]),
                        ]),
                    ]),
                    "required": .array([.string("files")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_recent_commands",
                description: "List recent command blocks in reverse chronological order. Each block includes: id (UUID), command text, output_preview (first 150 chars), started_at timestamp, and exit_code (null if unknown). Use get_command_output with the block id to see full output.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max command blocks to return (1-50)."),
                        ]),
                    ]),
                    "required": .array([.string("limit")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "execute_command",
                description: "Execute a shell command in the terminal (fire-and-forget). The command is sent to the shell but this tool does NOT wait for output — it returns immediately with status 'queued'. Use get_current_screen or get_command_output afterward to see results. Best for: interactive programs (vim, top, nano), long-running tasks, or when you just need to send input. For one-shot commands where you need the output, prefer execute_and_wait instead.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object([
                            "type": .string("string"),
                            "description": .string("Shell command to execute."),
                        ]),
                    ]),
                    "required": .array([.string("command")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "execute_and_wait",
                description: "Execute a shell command and wait for it to complete, returning the output and exit code directly. Use this for one-shot commands (ls, grep, git, make, curl, etc.). Do NOT use for interactive or long-running programs (vim, nano, top, tail -f, ssh) — use execute_command instead. Returns: output text, exit_code (integer), timed_out (bool), truncated (bool).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object([
                            "type": .string("string"),
                            "description": .string("Shell command to execute and wait for completion."),
                        ]),
                        "timeout_seconds": .object([
                            "type": .string("integer"),
                            "description": .string("Max seconds to wait for completion (5-60, default 30)."),
                        ]),
                    ]),
                    "required": .array([.string("command"), .string("timeout_seconds")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_session_info",
                description: "Get metadata about the current terminal session: host label, username, hostname, port, connection state, whether it is local or SSH, start time, and current working directory.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
        ]
    }
}
