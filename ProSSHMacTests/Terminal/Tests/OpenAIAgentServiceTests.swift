#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class OpenAIAgentServiceTests: XCTestCase {
    func testGenerateReplyRunsToolLoopAndReturnsAssistantAnswer() async throws {
        let sessionProvider = MockAgentSessionProvider()
        let responses = MockOpenAIResponsesService()
        responses.enqueueResponse(
            makeFunctionCallResponse(
                id: "resp_1",
                callID: "call_1",
                toolName: "get_session_info",
                arguments: "{}"
            )
        )
        responses.enqueueResponse(
            makeTextResponse(id: "resp_2", text: "Session looks healthy.")
        )

        let service = OpenAIAgentService(
            responsesService: responses,
            sessionProvider: sessionProvider
        )

        let reply = try await service.generateReply(
            sessionID: sessionProvider.sessionID,
            prompt: "How is this session?"
        )

        XCTAssertEqual(reply.text, "Session looks healthy.")
        XCTAssertEqual(reply.toolCallsExecuted, 1)

        let requests = responses.capturedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].previousResponseID)
        XCTAssertEqual(requests[1].previousResponseID, "resp_1")
        XCTAssertEqual(requests[1].toolOutputs.count, 1)
        XCTAssertEqual(requests[1].toolOutputs[0].callID, "call_1")
        XCTAssertTrue(requests[1].toolOutputs[0].output.contains("\"ok\":true"))
    }

    func testGetCommandOutputToolCapsOutputAndMarksTruncated() async throws {
        let sessionProvider = MockAgentSessionProvider()
        guard let blockID = sessionProvider.commandBlocks.first?.id else {
            XCTFail("Expected seeded command block")
            return
        }
        sessionProvider.commandOutputByBlockID[blockID] = String(repeating: "x", count: 2000)

        let responses = MockOpenAIResponsesService()
        responses.enqueueResponse(
            makeFunctionCallResponse(
                id: "resp_1",
                callID: "call_out",
                toolName: "get_command_output",
                arguments: #"{"block_id":"\#(blockID.uuidString.lowercased())","max_chars":300}"#
            )
        )
        responses.enqueueResponse(
            makeTextResponse(id: "resp_2", text: "Done.")
        )

        let service = OpenAIAgentService(
            responsesService: responses,
            sessionProvider: sessionProvider
        )

        _ = try await service.generateReply(
            sessionID: sessionProvider.sessionID,
            prompt: "show output"
        )

        let toolOutput = responses.capturedRequests[1].toolOutputs.first?.output ?? ""
        XCTAssertTrue(toolOutput.contains(#""truncated":true"#))
        XCTAssertTrue(toolOutput.contains(#""max_chars":300"#))
        XCTAssertTrue(toolOutput.contains(#""total_chars":2000"#))
        XCTAssertTrue(toolOutput.contains(#""returned_chars":300"#))
    }

    func testExecuteCommandToolRunsWhenRequested() async throws {
        let sessionProvider = MockAgentSessionProvider()
        let responses = MockOpenAIResponsesService()
        responses.enqueueResponse(
            makeFunctionCallResponse(
                id: "resp_1",
                callID: "call_exec",
                toolName: "execute_command",
                arguments: #"{"command":"ls -la"}"#
            )
        )
        responses.enqueueResponse(
            makeTextResponse(id: "resp_2", text: "Done.")
        )

        let service = OpenAIAgentService(
            responsesService: responses,
            sessionProvider: sessionProvider
        )

        _ = try await service.generateReply(
            sessionID: sessionProvider.sessionID,
            prompt: "run ls"
        )

        XCTAssertEqual(sessionProvider.sentCommands, ["ls -la"])
        let toolOutput = responses.capturedRequests[1].toolOutputs.first?.output ?? ""
        XCTAssertTrue(toolOutput.contains("\"queued\""))
    }

    func testExecuteCommandToolMissingCommandReturnsValidationErrorOutput() async throws {
        let sessionProvider = MockAgentSessionProvider()
        let responses = MockOpenAIResponsesService()
        responses.enqueueResponse(
            makeFunctionCallResponse(
                id: "resp_1",
                callID: "call_exec",
                toolName: "execute_command",
                arguments: "{}"
            )
        )
        responses.enqueueResponse(
            makeTextResponse(id: "resp_2", text: "Handled.")
        )

        let service = OpenAIAgentService(
            responsesService: responses,
            sessionProvider: sessionProvider
        )

        let reply = try await service.generateReply(
            sessionID: sessionProvider.sessionID,
            prompt: "execute"
        )

        XCTAssertEqual(reply.text, "Handled.")
        XCTAssertTrue(sessionProvider.sentCommands.isEmpty)
        let toolOutput = responses.capturedRequests[1].toolOutputs.first?.output ?? ""
        XCTAssertTrue(toolOutput.contains("invalid arguments"))
        XCTAssertTrue(toolOutput.contains("execute_command"))
    }

    func testExecuteCommandToolBlocksUnboundedFileReads() async throws {
        let sessionProvider = MockAgentSessionProvider()
        let responses = MockOpenAIResponsesService()
        responses.enqueueResponse(
            makeFunctionCallResponse(
                id: "resp_1",
                callID: "call_exec",
                toolName: "execute_command",
                arguments: #"{"command":"cat Makefile"}"#
            )
        )
        responses.enqueueResponse(
            makeTextResponse(id: "resp_2", text: "Handled.")
        )

        let service = OpenAIAgentService(
            responsesService: responses,
            sessionProvider: sessionProvider
        )

        let reply = try await service.generateReply(
            sessionID: sessionProvider.sessionID,
            prompt: "show me the makefile"
        )

        XCTAssertEqual(reply.text, "Handled.")
        XCTAssertTrue(sessionProvider.sentCommands.isEmpty)
        let toolOutput = responses.capturedRequests[1].toolOutputs.first?.output ?? ""
        XCTAssertTrue(toolOutput.contains("read_window_required"))
        XCTAssertTrue(toolOutput.contains("read_file_chunk"))
    }

    func testGenerateReplyThrowsToolLoopExceededWhenNoTerminalResponse() async throws {
        let sessionProvider = MockAgentSessionProvider()
        let responses = MockOpenAIResponsesService()
        responses.enqueueResponse(
            makeFunctionCallResponse(
                id: "resp_1",
                callID: "call_1",
                toolName: "get_session_info",
                arguments: "{}"
            )
        )
        responses.enqueueResponse(
            makeFunctionCallResponse(
                id: "resp_2",
                callID: "call_2",
                toolName: "get_session_info",
                arguments: "{}"
            )
        )

        let service = OpenAIAgentService(
            responsesService: responses,
            sessionProvider: sessionProvider,
            requestTimeoutSeconds: 60,
            maxToolIterations: 2
        )

        do {
            _ = try await service.generateReply(
                sessionID: sessionProvider.sessionID,
                prompt: "status"
            )
            XCTFail("Expected tool loop exceeded")
        } catch let error as OpenAIAgentServiceError {
            XCTAssertEqual(error, .toolLoopExceeded(limit: 2))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidPreviousResponseIDIsClearedAndRetried() async throws {
        let sessionProvider = MockAgentSessionProvider()
        let responses = MockOpenAIResponsesService()
        responses.enqueueResponse(
            makeTextResponse(id: "resp_prev", text: "First response")
        )
        responses.enqueueError(
            OpenAIResponsesServiceError.httpError(
                statusCode: 400,
                message: "Invalid previous_response_id"
            )
        )
        responses.enqueueResponse(
            makeTextResponse(id: "resp_new", text: "Recovered response")
        )

        let service = OpenAIAgentService(
            responsesService: responses,
            sessionProvider: sessionProvider
        )

        _ = try await service.generateReply(
            sessionID: sessionProvider.sessionID,
            prompt: "first"
        )
        let recovered = try await service.generateReply(
            sessionID: sessionProvider.sessionID,
            prompt: "second"
        )

        XCTAssertEqual(recovered.text, "Recovered response")
        let requests = responses.capturedRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].previousResponseID, "resp_prev")
        XCTAssertNil(requests[2].previousResponseID)
    }

    func testSearchFilesystemToolRunsInRemoteSession() async throws {
        let sessionProvider = MockAgentSessionProvider(isLocal: false)
        sessionProvider.simulatedRemoteFilesystemLines = [
            "d    /home/kevin/projects",
            "f    ./ProSSH prd.md",
        ]

        let responses = MockOpenAIResponsesService()
        responses.enqueueResponse(
            makeFunctionCallResponse(
                id: "resp_1",
                callID: "call_fs",
                toolName: "search_filesystem",
                arguments: #"{"path":"/home/kevin","name_pattern":"read","max_results":20}"#
            )
        )
        responses.enqueueResponse(
            makeTextResponse(id: "resp_2", text: "Found.")
        )

        let service = OpenAIAgentService(
            responsesService: responses,
            sessionProvider: sessionProvider
        )

        let reply = try await service.generateReply(
            sessionID: sessionProvider.sessionID,
            prompt: "find files"
        )

        XCTAssertEqual(reply.text, "Found.")
        XCTAssertEqual(reply.toolCallsExecuted, 1)
        XCTAssertTrue(sessionProvider.sentCommands.contains { $0.contains("__PROSSH_AI_TOOL_EXIT_") })
        XCTAssertTrue(sessionProvider.sentCommandsSuppressEcho.contains(true))
        let toolOutput = responses.capturedRequests[1].toolOutputs.first?.output ?? ""
        let normalizedOutput = toolOutput.replacingOccurrences(of: #"\/"#, with: "/")
        XCTAssertTrue(toolOutput.contains(#""ok":true"#))
        XCTAssertTrue(toolOutput.contains(#""source":"remote_command""#))
        XCTAssertTrue(normalizedOutput.contains("./ProSSH prd.md"))
        XCTAssertFalse(toolOutput.contains("local sessions only"))
    }

    func testSearchFileContentsToolRunsInRemoteSession() async throws {
        let sessionProvider = MockAgentSessionProvider(isLocal: false)
        sessionProvider.simulatedRemoteFileContentLines = [
            "/home/kevin/projects/README.md:12:OpenAI key setup",
        ]

        let responses = MockOpenAIResponsesService()
        responses.enqueueResponse(
            makeFunctionCallResponse(
                id: "resp_1",
                callID: "call_content",
                toolName: "search_file_contents",
                arguments: #"{"path":"/home/kevin/projects","text_pattern":"key","max_results":20}"#
            )
        )
        responses.enqueueResponse(
            makeTextResponse(id: "resp_2", text: "Done.")
        )

        let service = OpenAIAgentService(
            responsesService: responses,
            sessionProvider: sessionProvider
        )

        _ = try await service.generateReply(
            sessionID: sessionProvider.sessionID,
            prompt: "search in files"
        )

        XCTAssertTrue(sessionProvider.sentCommands.contains { $0.contains("__PROSSH_AI_TOOL_EXIT_") })
        XCTAssertTrue(sessionProvider.sentCommandsSuppressEcho.contains(true))
        let toolOutput = responses.capturedRequests[1].toolOutputs.first?.output ?? ""
        let normalizedOutput = toolOutput.replacingOccurrences(of: #"\/"#, with: "/")
        XCTAssertTrue(toolOutput.contains(#""ok":true"#))
        XCTAssertTrue(toolOutput.contains(#""source":"remote_command""#))
        XCTAssertTrue(normalizedOutput.contains("/home/kevin/projects/README.md"))
        XCTAssertTrue(toolOutput.contains(#""line_number":12"#))
        XCTAssertFalse(toolOutput.contains("local sessions only"))
    }

    private func makeTextResponse(id: String, text: String) -> OpenAIResponsesResponse {
        OpenAIResponsesResponse(
            id: id,
            status: "completed",
            outputText: nil,
            output: [
                .init(
                    type: "message",
                    id: nil,
                    role: "assistant",
                    content: [.init(type: "output_text", text: text)],
                    name: nil,
                    callID: nil,
                    arguments: nil
                ),
            ]
        )
    }

    private func makeFunctionCallResponse(
        id: String,
        callID: String,
        toolName: String,
        arguments: String
    ) -> OpenAIResponsesResponse {
        OpenAIResponsesResponse(
            id: id,
            status: "completed",
            outputText: nil,
            output: [
                .init(
                    type: "function_call",
                    id: nil,
                    role: nil,
                    content: nil,
                    name: toolName,
                    callID: callID,
                    arguments: arguments
                ),
            ]
        )
    }
}

@MainActor
private final class MockAgentSessionProvider: OpenAIAgentSessionProviding {
    let sessionID = UUID()
    var sessions: [Session]
    var shellBuffers: [UUID: [String]]
    var workingDirectoryBySessionID: [UUID: String]
    var bytesReceivedBySessionID: [UUID: Int64]
    var bytesSentBySessionID: [UUID: Int64]
    var sentCommands: [String] = []
    var sentCommandsSuppressEcho: [Bool] = []
    var commandBlocks: [CommandBlock]
    var commandOutputByBlockID: [UUID: String]
    var simulatedRemoteFilesystemLines: [String] = []
    var simulatedRemoteFileContentLines: [String] = []

    init(isLocal: Bool = true) {
        let session = Session(
            id: sessionID,
            kind: isLocal ? .local : .ssh(hostID: UUID()),
            hostLabel: isLocal ? "Local: zsh" : "Remote: ssh",
            username: "kevin",
            hostname: isLocal ? "localhost" : "example.remote",
            port: isLocal ? 0 : 22,
            state: .connected
        )
        sessions = [session]
        shellBuffers = [sessionID: ["line 1", "line 2"]]
        workingDirectoryBySessionID = [sessionID: "/Users/kevin"]
        bytesReceivedBySessionID = [sessionID: 100]
        bytesSentBySessionID = [sessionID: 200]

        let block = CommandBlock(
            id: UUID(),
            sessionID: sessionID,
            command: "ls",
            output: "file.txt",
            startedAt: .now.addingTimeInterval(-5),
            completedAt: .now.addingTimeInterval(-4),
            exitCode: 0,
            boundarySource: .userInput
        )
        commandBlocks = [block]
        commandOutputByBlockID = [block.id: block.output]
    }

    func recentCommandBlocks(sessionID: UUID, limit: Int) async -> [CommandBlock] {
        Array(commandBlocks.prefix(limit))
    }

    func searchCommandHistory(sessionID: UUID, query: String, limit: Int) async -> [CommandBlock] {
        Array(commandBlocks.filter { $0.command.contains(query) || $0.output.contains(query) }.prefix(limit))
    }

    func commandOutput(sessionID: UUID, blockID: UUID) async -> String? {
        commandOutputByBlockID[blockID]
    }

    func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool) async {
        sentCommands.append(input)
        sentCommandsSuppressEcho.append(suppressEcho)
        guard let marker = Self.extractRemoteToolMarker(from: input) else {
            return
        }

        let simulatedLines: [String]
        if input.contains("__prossh_find_pattern") {
            simulatedLines = simulatedRemoteFilesystemLines
        } else if input.contains("rg --line-number") || input.contains("grep -RIn") {
            simulatedLines = simulatedRemoteFileContentLines
        } else if !simulatedRemoteFilesystemLines.isEmpty {
            simulatedLines = simulatedRemoteFilesystemLines
        } else if !simulatedRemoteFileContentLines.isEmpty {
            simulatedLines = simulatedRemoteFileContentLines
        } else {
            simulatedLines = []
        }

        var output = simulatedLines.joined(separator: "\n")
        if !output.isEmpty {
            output += "\n"
        }
        output += "\(marker):0"

        let block = CommandBlock(
            id: UUID(),
            sessionID: sessionID,
            command: input,
            output: output,
            startedAt: .now,
            completedAt: .now,
            exitCode: 0,
            boundarySource: .userInput
        )
        commandBlocks.append(block)
        commandOutputByBlockID[block.id] = block.output
    }

    private static func extractRemoteToolMarker(from command: String) -> String? {
        let pattern = #"__PROSSH_AI_TOOL_EXIT_[A-F0-9]+__"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsCommand = command as NSString
        let range = NSRange(location: 0, length: nsCommand.length)
        guard let match = regex.firstMatch(in: command, options: [], range: range) else {
            return nil
        }
        return nsCommand.substring(with: match.range)
    }
}

@MainActor
private final class MockOpenAIResponsesService: OpenAIResponsesServicing {
    enum Event {
        case response(OpenAIResponsesResponse)
        case failure(Error)
    }

    private(set) var capturedRequests: [OpenAIResponsesRequest] = []
    private var events: [Event] = []

    func enqueueResponse(_ response: OpenAIResponsesResponse) {
        events.append(.response(response))
    }

    func enqueueError(_ error: Error) {
        events.append(.failure(error))
    }

    func createResponse(_ request: OpenAIResponsesRequest) async throws -> OpenAIResponsesResponse {
        capturedRequests.append(request)
        guard !events.isEmpty else {
            XCTFail("No mocked response event enqueued")
            throw OpenAIResponsesServiceError.invalidResponse
        }
        let event = events.removeFirst()
        switch event {
        case let .response(response):
            return response
        case let .failure(error):
            throw error
        }
    }
}
#endif
