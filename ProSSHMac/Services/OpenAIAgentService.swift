import Foundation

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
}

extension SessionManager: OpenAIAgentSessionProviding {}

@MainActor
final class OpenAIAgentService: OpenAIAgentServicing {
    let toolDefinitions: [OpenAIResponsesToolDefinition]

    private let responsesService: any OpenAIResponsesServicing
    private let sessionProvider: any OpenAIAgentSessionProviding
    private let requestTimeoutSeconds: Int
    private let maxToolIterations: Int
    private var previousResponseIDBySessionID: [UUID: String] = [:]
    private let iso8601Formatter = ISO8601DateFormatter()

    init(
        responsesService: any OpenAIResponsesServicing,
        sessionProvider: any OpenAIAgentSessionProviding,
        requestTimeoutSeconds: Int = 60,
        maxToolIterations: Int = 200
    ) {
        self.responsesService = responsesService
        self.sessionProvider = sessionProvider
        self.requestTimeoutSeconds = max(10, requestTimeoutSeconds)
        self.maxToolIterations = max(1, maxToolIterations)
        self.toolDefinitions = Self.buildToolDefinitions()
    }

    func clearConversation(sessionID: UUID) {
        previousResponseIDBySessionID.removeValue(forKey: sessionID)
    }

    func generateReply(
        sessionID: UUID,
        prompt: String
    ) async throws -> OpenAIAgentReply {
        guard sessionProvider.sessions.contains(where: { $0.id == sessionID }) else {
            throw OpenAIAgentServiceError.sessionNotFound
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw OpenAIAgentServiceError.emptyPrompt
        }

        var previousResponseID = previousResponseIDBySessionID[sessionID]
        var pendingMessages: [OpenAIResponsesMessage] = [
            .init(role: .developer, text: Self.developerPrompt()),
            .init(role: .user, text: trimmedPrompt),
        ]
        var pendingToolOutputs: [OpenAIResponsesToolOutput] = []
        var totalToolCalls = 0

        for _ in 0..<maxToolIterations {
            let request = OpenAIResponsesRequest(
                messages: pendingMessages,
                previousResponseID: previousResponseID,
                tools: toolDefinitions,
                toolOutputs: pendingToolOutputs
            )

            let response = try await createResponseWithRecovery(
                request: request,
                previousResponseID: &previousResponseID
            )

            previousResponseID = response.id
            previousResponseIDBySessionID[sessionID] = response.id

            let toolCalls = response.toolCalls
            guard !toolCalls.isEmpty else {
                return OpenAIAgentReply(
                    text: response.text,
                    responseID: response.id,
                    toolCallsExecuted: totalToolCalls
                )
            }

            totalToolCalls += toolCalls.count
            pendingToolOutputs = await executeToolCalls(
                sessionID: sessionID,
                toolCalls: toolCalls
            )
            pendingMessages = []
        }

        throw OpenAIAgentServiceError.toolLoopExceeded(limit: maxToolIterations)
    }

    private func createResponseWithRecovery(
        request: OpenAIResponsesRequest,
        previousResponseID: inout String?
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
                throw error
            }

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
        toolCalls: [OpenAIResponsesResponse.ToolCall]
    ) async -> [OpenAIResponsesToolOutput] {
        var outputs: [OpenAIResponsesToolOutput] = []
        outputs.reserveCapacity(toolCalls.count)

        for toolCall in toolCalls {
            do {
                let output = try await executeSingleToolCall(
                    sessionID: sessionID,
                    toolCall: toolCall
                )
                outputs.append(.init(callID: toolCall.id, output: output))
            } catch {
                let fallback = Self.jsonString(
                    from: .object([
                        "ok": .bool(false),
                        "error": .string(error.localizedDescription),
                        "tool": .string(toolCall.name),
                    ])
                )
                outputs.append(.init(callID: toolCall.id, output: fallback))
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
                Self.optionalInt(key: "max_chars", in: arguments) ?? 1200,
                min: 100,
                max: 4000
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
            let limit = Self.clamp(Self.optionalInt(key: "max_lines", in: arguments) ?? 60, min: 10, max: 160)
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
        You are ProSSH assistant.
        You have tool access to this terminal session and should use tools instead of claiming you cannot access context.
        For screen/context questions, call get_current_screen/get_recent_commands/search_terminal_history/get_session_info as needed.
        For filesystem questions, use search_filesystem/search_file_contents to discover targets, and use read_file_chunk to read file text.
        Never ingest an entire file at once. Always read in windows of at most 200 lines using read_file_chunk and iterate by line numbers.
        Execute commands only when the user explicitly asks to run, open, edit, or check something.
        This includes interactive commands when requested (for example: nano, vim, less, top).

        COST RULES — every tool call adds to conversation cost. Minimize calls:
        - Prefer read_files (batch) over multiple read_file_chunk calls when reading 2+ files.
        - Start with 30-50 lines for exploration; expand only if needed.
        - Use search_file_contents to pinpoint lines before reading whole files.
        - Stop calling tools once you have enough to answer — do not exhaustively explore.
        - If a first chunk already answers the question, do not read further chunks.
        - Do not repeat the same tool call with identical arguments unless the user asked for a retry.
        - Batch discovery (for example one filesystem search, then one focused content search) before summarizing.
        - If sufficient evidence is already gathered, stop calling tools and answer directly.

        Format responses as readable markdown:
        - Use short paragraphs.
        - Use bullet points for lists.
        - Add a brief heading when it improves scanning.
        - Avoid one long unbroken paragraph.
        Keep responses concise.
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

    private static func buildToolDefinitions() -> [OpenAIResponsesToolDefinition] {
        let commonNoExtraProperties = OpenAIJSONValue.bool(false)

        return [
            OpenAIResponsesToolDefinition(
                name: "search_terminal_history",
                description: "Search command history and outputs for text.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query for command text or output."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "minimum": .number(1),
                            "maximum": .number(50),
                        ]),
                    ]),
                    "required": .array([.string("query"), .string("limit")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_command_output",
                description: "Get output for a command block id, capped to max_chars.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "block_id": .object([
                            "type": .string("string"),
                            "description": .string("UUID of the command block."),
                        ]),
                        "max_chars": .object([
                            "type": .string("integer"),
                            "minimum": .number(100),
                            "maximum": .number(4000),
                        ]),
                    ]),
                    "required": .array([.string("block_id"), .string("max_chars")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_current_screen",
                description: "Read the current visible terminal screen lines.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "max_lines": .object([
                            "type": .string("integer"),
                            "minimum": .number(10),
                            "maximum": .number(160),
                        ]),
                    ]),
                    "required": .array([.string("max_lines")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "search_filesystem",
                description: "Search filesystem entries by filename pattern in the active session. Supports wildcard patterns like '*.swift'.",
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
                            "minimum": .number(1),
                            "maximum": .number(200),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("name_pattern"), .string("max_results")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "search_file_contents",
                description: "Search text inside files under a directory tree in the active session and return matching lines.",
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
                            "minimum": .number(1),
                            "maximum": .number(200),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("text_pattern"), .string("max_results")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "read_file_chunk",
                description: "Read a specific window of lines from a text file. Use this for file inspection instead of full-file reads.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("File path to read (absolute, ~, or relative to current working directory)."),
                        ]),
                        "start_line": .object([
                            "type": .string("integer"),
                            "minimum": .number(1),
                        ]),
                        "line_count": .object([
                            "type": .string("integer"),
                            "minimum": .number(1),
                            "maximum": .number(200),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("start_line"), .string("line_count")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "read_files",
                description: "Read chunks from multiple files in one call. Use instead of multiple read_file_chunk calls. Max 10 files.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "files": .object([
                            "type": .string("array"),
                            "description": .string("Array of file read requests."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "path": .object([
                                        "type": .string("string"),
                                        "description": .string("File path (absolute, ~, or relative)."),
                                    ]),
                                    "start_line": .object([
                                        "type": .string("integer"),
                                        "minimum": .number(1),
                                    ]),
                                    "line_count": .object([
                                        "type": .string("integer"),
                                        "minimum": .number(1),
                                        "maximum": .number(200),
                                    ]),
                                ]),
                                "required": .array([.string("path"), .string("start_line"), .string("line_count")]),
                                "additionalProperties": commonNoExtraProperties,
                            ]),
                            "minItems": .number(1),
                            "maxItems": .number(10),
                        ]),
                    ]),
                    "required": .array([.string("files")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "get_recent_commands",
                description: "List recent command blocks in reverse chronological order.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "minimum": .number(1),
                            "maximum": .number(50),
                        ]),
                    ]),
                    "required": .array([.string("limit")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "execute_command",
                description: "Execute a shell command in the current terminal session.",
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
                name: "get_session_info",
                description: "Get metadata and counters for the current session.",
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
