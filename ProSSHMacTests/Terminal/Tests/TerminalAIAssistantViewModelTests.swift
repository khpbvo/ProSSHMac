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
    }

    func testClearConversationResetsMessagesAndCallsService() throws {
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

    func testSubmitPromptReflowsDenseAssistantReplyIntoParagraphs() async throws {
        let sessionID = UUID()
        let denseReply = """
        This repository contains a CLI orchestrator for document workflows. It includes configuration and runtime integration for external tools. The project also wires approval-aware execution paths for safe editing. It supports retrieval and summarization flows for large document sets.
        """
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(
                text: denseReply,
                responseID: "resp_456",
                toolCallsExecuted: 3
            )
        )
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )

        viewModel.draftPrompt = "Summarize"
        viewModel.submitPrompt(for: sessionID)

        try await waitUntil(timeout: 1.5) {
            !viewModel.isSending
        }

        XCTAssertEqual(viewModel.messages.count, 2)
        let assistantText = viewModel.messages[1].content
        XCTAssertTrue(assistantText.contains("\n\n"))
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
    private(set) var clearedSessionIDs: [UUID] = []

    init(nextReply: OpenAIAgentReply, replyDelayNanoseconds: UInt64 = 0) {
        self.nextReply = nextReply
        self.replyDelayNanoseconds = replyDelayNanoseconds
    }

    nonisolated deinit {}

    func clearConversation(sessionID: UUID) {
        clearedSessionIDs.append(sessionID)
    }

    func generateReply(
        sessionID: UUID,
        prompt: String
    ) async throws -> OpenAIAgentReply {
        if replyDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: replyDelayNanoseconds)
        }
        capturedPrompts.append(prompt)
        return nextReply
    }
}
#endif
