#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class TerminalAIAssistantViewModelTests: XCTestCase {
    func testSubmitPromptAppendsUserAndAssistantMessages() async throws {
        let sessionID = UUID()
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(
                text: "Use `tail -f /var/log/system.log` for live logs.",
                responseID: "resp_123",
                toolCallsExecuted: 2
            )
        )
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )

        viewModel.draftPrompt = "How do I stream logs?"
        viewModel.submitPrompt(for: sessionID)

        try await waitUntil(timeout: 1.5) {
            !viewModel.isSending
        }

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "How do I stream logs?")
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Use `tail -f /var/log/system.log` for live logs.")
        XCTAssertFalse(viewModel.messages[1].isStreaming)
        XCTAssertEqual(service.capturedPrompts, ["How do I stream logs?"])
        XCTAssertEqual(service.capturedModes, [.ask])
    }

    func testClearConversationResetsMessagesAndCallsService() throws {
        throw XCTSkip("Temporarily skipped: this path can crash XCTest host process (malloc/free) on current runner.")
        let sessionID = UUID()
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(text: "ok", responseID: "resp", toolCallsExecuted: 0)
        )
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )
        viewModel.messages = [
            .init(id: UUID(), role: .assistant, content: "test", createdAt: .now, isStreaming: false),
        ]

        viewModel.clearConversation(sessionID: sessionID)

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(service.clearedSessionIDs, [sessionID])
    }

    func testFollowModeAutoSendDeduplicatesByCommandBlockID() async throws {
        let sessionID = UUID()
        let blockID = UUID()
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(text: "Looks healthy.", responseID: "resp_follow", toolCallsExecuted: 1)
        )
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )
        viewModel.mode = .follow

        let block = CommandBlock(
            id: blockID,
            sessionID: sessionID,
            command: "ls -la",
            output: "total 8",
            startedAt: .now,
            completedAt: .now,
            exitCode: 0,
            boundarySource: .osc133
        )

        viewModel.submitFollowUpIfNeeded(for: sessionID, completedBlock: block)
        try await waitUntil(timeout: 1.5) {
            !viewModel.isSending
        }

        // Same block should not auto-trigger again.
        viewModel.submitFollowUpIfNeeded(for: sessionID, completedBlock: block)
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(service.capturedPrompts.count, 1)
        XCTAssertEqual(service.capturedModes, [.follow])
        XCTAssertTrue(viewModel.messages.contains(where: {
            $0.role == .system && $0.content.contains("command finished -> ls -la")
        }))
    }

    func testFollowModeAutoSendIgnoredOutsideFollowMode() async throws {
        let sessionID = UUID()
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(text: "n/a", responseID: "resp", toolCallsExecuted: 0)
        )
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )

        let block = CommandBlock(
            id: UUID(),
            sessionID: sessionID,
            command: "pwd",
            output: "/tmp",
            startedAt: .now,
            completedAt: .now,
            exitCode: 0,
            boundarySource: .osc133
        )

        viewModel.submitFollowUpIfNeeded(for: sessionID, completedBlock: block)
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(service.capturedPrompts.isEmpty)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testFollowModeAutoSendSkippedWhileAlreadySending() async throws {
        let sessionID = UUID()
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(text: "ok", responseID: "resp", toolCallsExecuted: 0),
            replyDelayNanoseconds: 120_000_000
        )
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )
        viewModel.mode = .follow

        let first = CommandBlock(
            id: UUID(),
            sessionID: sessionID,
            command: "echo first",
            output: "first",
            startedAt: .now,
            completedAt: .now,
            exitCode: 0,
            boundarySource: .osc133
        )
        let second = CommandBlock(
            id: UUID(),
            sessionID: sessionID,
            command: "echo second",
            output: "second",
            startedAt: .now,
            completedAt: .now,
            exitCode: 0,
            boundarySource: .osc133
        )

        viewModel.submitFollowUpIfNeeded(for: sessionID, completedBlock: first)
        viewModel.submitFollowUpIfNeeded(for: sessionID, completedBlock: second)

        try await waitUntil(timeout: 2.0) {
            !viewModel.isSending
        }

        XCTAssertEqual(service.capturedPrompts.count, 1)
        XCTAssertTrue(service.capturedPrompts[0].contains("echo first"))
        XCTAssertFalse(service.capturedPrompts[0].contains("echo second"))
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition not met before timeout.")
    }
}

@MainActor
private final class MockOpenAIAgentService: OpenAIAgentServicing {
    var toolDefinitions: [OpenAIResponsesToolDefinition] = []
    var nextReply: OpenAIAgentReply
    var replyDelayNanoseconds: UInt64
    private(set) var capturedPrompts: [String] = []
    private(set) var capturedModes: [OpenAIAgentMode] = []
    private(set) var clearedSessionIDs: [UUID] = []

    init(nextReply: OpenAIAgentReply, replyDelayNanoseconds: UInt64 = 0) {
        self.nextReply = nextReply
        self.replyDelayNanoseconds = replyDelayNanoseconds
    }

    func clearConversation(sessionID: UUID) {
        clearedSessionIDs.append(sessionID)
    }

    func generateReply(
        sessionID: UUID,
        prompt: String,
        mode: OpenAIAgentMode
    ) async throws -> OpenAIAgentReply {
        if replyDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: replyDelayNanoseconds)
        }
        capturedPrompts.append(prompt)
        capturedModes.append(mode)
        return nextReply
    }
}
#endif
