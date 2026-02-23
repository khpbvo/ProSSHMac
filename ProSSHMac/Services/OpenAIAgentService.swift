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
            return "You are ProSSH assistant. Use tools when needed, keep responses concise, and do not request command execution."
        case .follow:
            return "You are ProSSH assistant in follow mode. Focus on recent command context and concise operational guidance."
        case .execute:
            return "You are ProSSH assistant in execute mode. You may call execute_command only when directly useful and after validating context."
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
                function: .init(
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
                        "required": .array([.string("query")]),
                        "additionalProperties": commonNoExtraProperties,
                    ]),
                    strict: true
                )
            ),
            OpenAIResponsesToolDefinition(
                function: .init(
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
                )
            ),
            OpenAIResponsesToolDefinition(
                function: .init(
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
                        "required": .array([]),
                        "additionalProperties": commonNoExtraProperties,
                    ]),
                    strict: true
                )
            ),
            OpenAIResponsesToolDefinition(
                function: .init(
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
                        "required": .array([]),
                        "additionalProperties": commonNoExtraProperties,
                    ]),
                    strict: true
                )
            ),
            OpenAIResponsesToolDefinition(
                function: .init(
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
                )
            ),
            OpenAIResponsesToolDefinition(
                function: .init(
                    name: "get_session_info",
                    description: "Get metadata and counters for the current session.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "required": .array([]),
                        "additionalProperties": commonNoExtraProperties,
                    ]),
                    strict: true
                )
            ),
        ]
    }
}
