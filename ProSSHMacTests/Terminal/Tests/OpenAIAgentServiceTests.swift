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
            prompt: "How is this session?",
            mode: .ask
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

    func testExecuteCommandToolRequiresExecuteMode() async throws {
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
            prompt: "run ls",
            mode: .ask
        )

        XCTAssertEqual(sessionProvider.sentCommands, [])
        let toolOutput = responses.capturedRequests[1].toolOutputs.first?.output ?? ""
        XCTAssertTrue(toolOutput.contains("confirmation_required"))
    }

    func testExecuteCommandToolRunsInExecuteMode() async throws {
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
            prompt: "run ls",
            mode: .execute
        )

        XCTAssertEqual(sessionProvider.sentCommands, ["ls -la"])
        let toolOutput = responses.capturedRequests[1].toolOutputs.first?.output ?? ""
        XCTAssertTrue(toolOutput.contains("\"queued\""))
    }

    func testExecuteCommandToolRequiresExecuteModeInFollowMode() async throws {
        let sessionProvider = MockAgentSessionProvider()
        let responses = MockOpenAIResponsesService()
        responses.enqueueResponse(
            makeFunctionCallResponse(
                id: "resp_1",
                callID: "call_exec",
                toolName: "execute_command",
                arguments: #"{"command":"whoami"}"#
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
            prompt: "run whoami",
            mode: .follow
        )

        XCTAssertEqual(sessionProvider.sentCommands, [])
        let toolOutput = responses.capturedRequests[1].toolOutputs.first?.output ?? ""
        XCTAssertTrue(toolOutput.contains("confirmation_required"))
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
            prompt: "execute",
            mode: .execute
        )

        XCTAssertEqual(reply.text, "Handled.")
        XCTAssertTrue(sessionProvider.sentCommands.isEmpty)
        let toolOutput = responses.capturedRequests[1].toolOutputs.first?.output ?? ""
        XCTAssertTrue(toolOutput.contains("invalid arguments"))
        XCTAssertTrue(toolOutput.contains("execute_command"))
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
                prompt: "status",
                mode: .ask
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
            prompt: "first",
            mode: .ask
        )
        let recovered = try await service.generateReply(
            sessionID: sessionProvider.sessionID,
            prompt: "second",
            mode: .ask
        )

        XCTAssertEqual(recovered.text, "Recovered response")
        let requests = responses.capturedRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].previousResponseID, "resp_prev")
        XCTAssertNil(requests[2].previousResponseID)
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
    var commandBlocks: [CommandBlock]
    var commandOutputByBlockID: [UUID: String]

    init() {
        let session = Session(
            id: sessionID,
            kind: .local,
            hostLabel: "Local: zsh",
            username: "kevin",
            hostname: "localhost",
            port: 0,
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
