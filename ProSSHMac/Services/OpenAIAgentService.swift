import Foundation

@MainActor
protocol OpenAIAgentServicing {
    var toolDefinitions: [OpenAIResponsesToolDefinition] { get }
    func clearConversation(sessionID: UUID)
    func generateReply(
        sessionID: UUID,
        prompt: String,
        mode: OpenAIAgentMode
    ) async throws -> OpenAIAgentReply
}

enum OpenAIAgentMode: Sendable, Equatable {
    case ask
    case follow
    case execute
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
        maxToolIterations: Int = 8
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
        prompt: String,
        mode: OpenAIAgentMode
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
            .init(role: .developer, text: Self.developerPrompt(for: mode)),
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
                toolCalls: toolCalls,
                allowCommandExecution: mode == .execute
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
        toolCalls: [OpenAIResponsesResponse.ToolCall],
        allowCommandExecution: Bool
    ) async -> [OpenAIResponsesToolOutput] {
        var outputs: [OpenAIResponsesToolOutput] = []
        outputs.reserveCapacity(toolCalls.count)

        for toolCall in toolCalls {
            do {
                let output = try await executeSingleToolCall(
                    sessionID: sessionID,
                    toolCall: toolCall,
                    allowCommandExecution: allowCommandExecution
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
        toolCall: OpenAIResponsesResponse.ToolCall,
        allowCommandExecution: Bool
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
                "query": .string(query),
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

            let output = await sessionProvider.commandOutput(sessionID: sessionID, blockID: blockID)
            return Self.jsonString(from: .object([
                "ok": .bool(true),
                "block_id": .string(blockID.uuidString.lowercased()),
                "output": output.map(OpenAIJSONValue.string) ?? .null,
            ]))

        case "get_current_screen":
            let limit = Self.clamp(Self.optionalInt(key: "max_lines", in: arguments) ?? 120, min: 10, max: 400)
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
            guard session.isLocal else {
                return Self.jsonString(from: .object([
                    "ok": .bool(false),
                    "error": .string("Filesystem search tool currently supports local sessions only."),
                    "hint": .string("In remote sessions, use execute_command with find/rg/grep."),
                ]))
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

            let workingDirectory = sessionProvider.workingDirectoryBySessionID[sessionID]
            let result = try await Self.searchFilesystemEntries(
                path: searchPath,
                namePattern: namePattern,
                maxResults: maxResults,
                workingDirectory: workingDirectory
            )
            return Self.jsonString(from: result)

        case "search_file_contents":
            guard let session = sessionProvider.sessions.first(where: { $0.id == sessionID }) else {
                throw OpenAIAgentServiceError.sessionNotFound
            }
            guard session.isLocal else {
                return Self.jsonString(from: .object([
                    "ok": .bool(false),
                    "error": .string("File-content search tool currently supports local sessions only."),
                    "hint": .string("In remote sessions, use execute_command with rg/grep."),
                ]))
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

            let workingDirectory = sessionProvider.workingDirectoryBySessionID[sessionID]
            let result = try await Self.searchFileContents(
                path: searchPath,
                textPattern: textPattern,
                maxResults: maxResults,
                workingDirectory: workingDirectory
            )
            return Self.jsonString(from: result)

        case "execute_command":
            let command = try Self.requiredString(
                key: "command",
                in: arguments,
                toolName: toolCall.name
            )

            if !allowCommandExecution {
                return Self.jsonString(from: .object([
                    "ok": .bool(false),
                    "status": .string("confirmation_required"),
                    "message": .string("Command execution is disabled in current AI mode."),
                    "command": .string(command),
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
                "command": .string(command),
            ]))

        case "get_session_info":
            guard let session = sessionProvider.sessions.first(where: { $0.id == sessionID }) else {
                throw OpenAIAgentServiceError.sessionNotFound
            }

            return Self.jsonString(from: .object([
                "ok": .bool(true),
                "session_id": .string(session.id.uuidString.lowercased()),
                "state": .string(session.state.rawValue),
                "host_label": .string(session.hostLabel),
                "username": .string(session.username),
                "hostname": .string(session.hostname),
                "port": .number(Double(session.port)),
                "is_local": .bool(session.isLocal),
                "started_at": .string(iso8601Formatter.string(from: session.startedAt)),
                "working_directory": sessionProvider.workingDirectoryBySessionID[sessionID].map(OpenAIJSONValue.string) ?? .null,
                "bytes_received": .number(Double(sessionProvider.bytesReceivedBySessionID[sessionID] ?? 0)),
                "bytes_sent": .number(Double(sessionProvider.bytesSentBySessionID[sessionID] ?? 0)),
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
                        "name": .string(rootURL.lastPathComponent),
                        "is_directory": .bool(false),
                    ]))
                }
                return .object([
                    "ok": .bool(true),
                    "path": .string(rootURL.path),
                    "name_pattern": .string(namePattern),
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
                        "name": .string(name),
                        "is_directory": .bool(directory),
                    ]))
                }
            }

            let truncated = scannedEntries > maxScannedEntries || results.count >= maxResults
            return .object([
                "ok": .bool(true),
                "path": .string(rootURL.path),
                "name_pattern": .string(namePattern),
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
                    "path": .string(rootURL.path),
                    "text_pattern": .string(textPattern),
                    "scanned_files": .number(1),
                    "truncated": .bool(matches.count >= maxResults),
                    "matches": .array(Array(matches.prefix(maxResults))),
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
                "path": .string(rootURL.path),
                "text_pattern": .string(textPattern),
                "scanned_files": .number(Double(scannedFiles)),
                "truncated": .bool(truncated),
                "matches": .array(Array(matches.prefix(maxResults))),
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
            "output_preview": .string(String(block.output.prefix(800))),
            "started_at": .string(ISO8601DateFormatter().string(from: block.startedAt)),
            "completed_at": .string(ISO8601DateFormatter().string(from: block.completedAt)),
            "exit_code": block.exitCode.map { .number(Double($0)) } ?? .null,
            "boundary_source": .string(block.boundarySource.rawValue),
        ])
    }

    private static func isPreviousResponseIDError(message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("previous_response_id") ||
            lowercased.contains("previous response")
    }

    private static func developerPrompt(for mode: OpenAIAgentMode) -> String {
        switch mode {
        case .ask:
            return """
            You are ProSSH assistant.
            You have tool access to this terminal session and should use tools instead of claiming you cannot access context.
            For screen/context questions, call get_current_screen/get_recent_commands/search_terminal_history/get_session_info as needed.
            For local filesystem questions, use search_filesystem and search_file_contents.
            Keep responses concise.
            Do not execute commands in Ask mode; if execution is needed, ask the user to switch to Execute mode.
            """
        case .follow:
            return """
            You are ProSSH assistant in Follow mode.
            Focus on latest command outcomes and operational next steps.
            Use tools for evidence before answering; do not claim lack of visibility when tools can provide context.
            For local filesystem questions, use search_filesystem and search_file_contents.
            Do not execute commands in Follow mode.
            """
        case .execute:
            return """
            You are ProSSH assistant in Execute mode.
            You can run terminal commands via execute_command and should do so when the user explicitly asks to run/open/edit/check something.
            This includes interactive programs when requested (for example: nano, vim, less, top).
            Before or after execution, use other tools (get_current_screen, get_recent_commands, search_terminal_history, get_command_output, get_session_info, search_filesystem, search_file_contents) to validate and explain outcomes.
            Never claim you cannot run commands in Execute mode.
            Keep output concise and action-oriented.
            """
        }
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
                description: "Get full output for a command block id.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "block_id": .object([
                            "type": .string("string"),
                            "description": .string("UUID of the command block."),
                        ]),
                    ]),
                    "required": .array([.string("block_id")]),
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
                            "maximum": .number(400),
                        ]),
                    ]),
                    "required": .array([.string("max_lines")]),
                    "additionalProperties": commonNoExtraProperties,
                ]),
                strict: true
            ),
            OpenAIResponsesToolDefinition(
                name: "search_filesystem",
                description: "Search local filesystem entries by filename pattern. Supports wildcard patterns like '*.swift'.",
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
                description: "Search text inside local files under a directory tree and return matching lines.",
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
