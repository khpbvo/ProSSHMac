#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class AIAgentServiceTests: XCTestCase {
    private func store(client: MockOpenRouterService) async throws -> OpenRouterModelStore {
        let suite = "OpenRouterAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = OpenRouterModelStore(client: client, defaults: defaults)
        await store.refresh()
        try store.select("test/one")
        return store
    }

    private func completion(_ text: String, id: String = UUID().uuidString) -> OpenRouterCompletion {
        .init(id: id, model: "test/one", choices: [.init(message: .init(role: "assistant", content: text), finishReason: "stop")], usage: nil)
    }

    private func toolCompletion(_ name: String, arguments: String, id: String = "call_1") -> OpenRouterCompletion {
        let call = OpenRouterToolCall(id: id, function: .init(name: name, arguments: arguments))
        return .init(id: UUID().uuidString, model: "test/one", choices: [.init(message: .init(role: "assistant", content: nil, toolCalls: [call]), finishReason: "tool_calls")], usage: nil)
    }

    func testToolLoopKeepsCallAndResultInTranscript() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        client.enqueue(toolCompletion("get_session_info", arguments: "{}"))
        client.enqueue(completion("Session healthy"))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: try await store(client: client))
        let reply = try await service.generateReply(sessionID: session.sessionID, prompt: "status")
        XCTAssertEqual(reply.text, "Session healthy")
        XCTAssertEqual(reply.toolCallsExecuted, 1)
        XCTAssertEqual(client.requests.count, 2)
        let replay = client.requests[1].messages
        XCTAssertEqual(replay.first { $0.role == "assistant" }?.toolCalls?.first?.id, "call_1")
        XCTAssertEqual(replay.first { $0.role == "tool" }?.toolCallID, "call_1")
        XCTAssertTrue(replay.first { $0.role == "tool" }?.content?.contains("\"ok\":true") == true)
    }

    func testModelSwitchContinuesHistoryWithoutReasoning() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        let modelStore = try await store(client: client)
        var first = completion("The code is blue")
        first = .init(id: first.id, model: "test/one", choices: [.init(message: .init(role: "assistant", content: "The code is blue", reasoningDetails: [.object(["type": .string("reasoning.text"), "text": .string("private")])]), finishReason: "stop")], usage: nil)
        client.enqueue(first)
        client.enqueue(completion("blue"))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: modelStore)
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "Remember the code")
        try modelStore.select("test/two")
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "What is the code?")
        let second = client.requests[1]
        XCTAssertEqual(second.model, "test/two")
        XCTAssertTrue(second.messages.contains { $0.content == "The code is blue" })
        XCTAssertNil(second.messages.first { $0.content == "The code is blue" }?.reasoningDetails)
    }

    func testModelSwitchKeepsCompletedToolCycle() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        let modelStore = try await store(client: client)
        client.enqueue(toolCompletion("get_session_info", arguments: "{}"))
        client.enqueue(completion("Local shell"))
        client.enqueue(completion("It is a local shell"))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: modelStore)
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "Inspect this session")
        try modelStore.select("test/two")
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "What did you inspect?")
        let replay = client.requests[2].messages
        XCTAssertEqual(replay.first { $0.role == "assistant" && $0.toolCalls != nil }?.toolCalls?.first?.id, "call_1")
        XCTAssertEqual(replay.first { $0.role == "tool" }?.toolCallID, "call_1")
        XCTAssertTrue(replay.contains { $0.content == "Local shell" })
    }

    func testPatchDenialDoesNotWrite() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        client.enqueue(toolCompletion("apply_patch", arguments: #"{"operation":"create","path":"/tmp/denied.txt","content":"blocked"}"#))
        client.enqueue(completion("Denied"))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: try await store(client: client))
        service.patchApprovalCallback = { _, _ in (false, false) }
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "create a file")
        XCTAssertTrue(client.requests[1].messages.first { $0.role == "tool" }?.content?.contains("Patch denied by user") == true)
        XCTAssertFalse(session.sentCommands.contains { $0.contains("denied.txt") })
    }

    func testSessionHistoryIsIsolatedAndClearable() async throws {
        let client = MockOpenRouterService()
        let session = MockAgentSessionProvider()
        let secondID = UUID()
        session.sessions.append(Session(id: secondID, kind: .local, hostLabel: "Second", username: "u", hostname: "localhost", port: 0, state: .connected))
        let service = AIAgentService(openRouterClient: client, sessionProvider: session, modelStore: try await store(client: client))
        client.enqueue(completion("first answer"))
        client.enqueue(completion("second answer"))
        client.enqueue(completion("new answer"))
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "first")
        _ = try await service.generateReply(sessionID: secondID, prompt: "second")
        XCTAssertFalse(client.requests[1].messages.contains { $0.content == "first answer" })
        service.clearConversation(sessionID: session.sessionID)
        _ = try await service.generateReply(sessionID: session.sessionID, prompt: "new")
        XCTAssertFalse(client.requests[2].messages.contains { $0.content == "first answer" })
    }
}

@MainActor
private final class MockAgentSessionProvider: AIAgentSessionProviding {
    let sessionID = UUID()
    var sessions: [Session]
    var shellBuffers: [UUID: [String]]
    var workingDirectoryBySessionID: [UUID: String]
    var bytesReceivedBySessionID: [UUID: Int64]
    var bytesSentBySessionID: [UUID: Int64]
    var sentCommands: [String] = []
    var commandBlocks: [CommandBlock]
    var commandOutputByBlockID: [UUID: String]
    var simulatedExecuteAndWaitOutput: String = ""
    var simulatedExecuteAndWaitExitCode: Int? = 0
    var simulatedExecuteAndWaitTimedOut: Bool = false
    var simulatedExecuteAndWaitResultsQueue: [CommandExecutionResult] = []

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

    func sendRawShellInput(sessionID: UUID, input: String) async {
        sentCommands.append(input)
    }

    func sendShellInput(sessionID: UUID, input: String, suppressEcho: Bool) async {
        sentCommands.append(input)
    }

    func executeCommandAndWait(
        sessionID: UUID,
        command: String,
        timeoutSeconds: TimeInterval
    ) async -> CommandExecutionResult {
        sentCommands.append(command)

        if !simulatedExecuteAndWaitResultsQueue.isEmpty {
            return simulatedExecuteAndWaitResultsQueue.removeFirst()
        }

        if simulatedExecuteAndWaitTimedOut {
            return CommandExecutionResult(output: "", exitCode: nil, timedOut: true, blockID: nil)
        }

        let blockID = UUID()
        let block = CommandBlock(
            id: blockID,
            sessionID: sessionID,
            command: command,
            output: simulatedExecuteAndWaitOutput,
            startedAt: .now,
            completedAt: .now,
            exitCode: simulatedExecuteAndWaitExitCode,
            boundarySource: .userInput
        )
        commandBlocks.append(block)
        commandOutputByBlockID[blockID] = simulatedExecuteAndWaitOutput

        return CommandExecutionResult(
            output: simulatedExecuteAndWaitOutput,
            exitCode: simulatedExecuteAndWaitExitCode,
            timedOut: false,
            blockID: blockID
        )
    }

}

@MainActor
private final class MockOpenRouterService: OpenRouterServicing {
    struct Request { var model: String; var messages: [OpenRouterMessage]; var tools: [LLMToolDefinition] }
    var requests: [Request] = []
    var responses: [OpenRouterCompletion] = []
    func enqueue(_ response: OpenRouterCompletion) { responses.append(response) }
    func fetchModels() async throws -> [OpenRouterModel] {
        ["test/one", "test/two"].map { OpenRouterModel(id: $0, name: $0, contextLength: 32_768, supportedParameters: ["tools"], architecture: .init(inputModalities: ["text"], outputModalities: ["text"]), pricing: nil) }
    }
    func complete(model: String, messages: [OpenRouterMessage], tools: [LLMToolDefinition], onEvent: @escaping @Sendable (LLMStreamEvent) -> Void) async throws -> OpenRouterCompletion {
        requests.append(.init(model: model, messages: messages, tools: tools))
        guard !responses.isEmpty else { throw OpenRouterError.invalidResponse }
        let response = responses.removeFirst()
        if let text = response.choices.first?.message.content { onEvent(.textDone(text)) }
        return response
    }
}
#endif
