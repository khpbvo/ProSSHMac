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

    func testRequestPatchApprovalUsesModalStateWithoutInlineMessage() async throws {
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(text: "ok", responseID: "resp_patch", toolCallsExecuted: 0)
        )
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )
        let operation = PatchOperation(
            type: .update,
            path: "/tmp/example.swift",
            diff: "@@\n-print(\"old\")\n+print(\"new\")"
        )

        let approvalTask = Task {
            await viewModel.requestPatchApproval(operation: operation, fingerprint: "fp_patch")
        }

        try await waitUntil(timeout: 1.0) {
            viewModel.activePatchApproval != nil
        }

        let approval = try XCTUnwrap(viewModel.activePatchApproval)
        XCTAssertEqual(approval.operation, "update")
        XCTAssertEqual(approval.path, "/tmp/example.swift")
        XCTAssertEqual(approval.diffPreview, "@@\n-print(\"old\")\n+print(\"new\")")
        XCTAssertTrue(viewModel.messages.isEmpty)

        viewModel.approvePatch(remember: true)
        let decision = await approvalTask.value
        XCTAssertTrue(decision.0)
        XCTAssertTrue(decision.1)
        XCTAssertNil(viewModel.activePatchApproval)
    }

    func testPatchApprovalSheetDismissDeniesPendingApproval() async throws {
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(text: "ok", responseID: "resp_patch_dismiss", toolCallsExecuted: 0)
        )
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )
        let operation = PatchOperation(type: .create, path: "/tmp/new.txt", diff: "+hello")

        let approvalTask = Task {
            await viewModel.requestPatchApproval(operation: operation, fingerprint: "fp_patch_dismiss")
        }

        try await waitUntil(timeout: 1.0) {
            viewModel.activePatchApproval != nil
        }

        viewModel.handlePatchApprovalDismissed()
        let decision = await approvalTask.value
        XCTAssertFalse(decision.0)
        XCTAssertFalse(decision.1)
        XCTAssertNil(viewModel.activePatchApproval)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testSubmitPromptStreamsReasoningBubbleMessages() async throws {
        let sessionID = UUID()
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(
                text: "Done.",
                responseID: "resp_stream",
                toolCallsExecuted: 0
            )
        )
        service.streamEvents = [
            .reasoningSummaryDelta("Checking logs... "),
            .reasoningSummaryDone("Checking logs... done."),
            .assistantTextDelta("Done."),
            .assistantTextDone("Done."),
        ]
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )

        viewModel.draftPrompt = "Investigate"
        viewModel.submitPrompt(for: sessionID)

        try await waitUntil(timeout: 1.5) {
            !viewModel.isSending
        }

        XCTAssertEqual(viewModel.messages.count, 2)
        let assistantMessage = viewModel.messages.first(where: { $0.role == .assistant && $0.kind == .text })
        XCTAssertEqual(assistantMessage?.content, "Done.")
        XCTAssertFalse(viewModel.isReasoningStreaming)
        XCTAssertTrue(viewModel.reasoningPanelText.contains("Checking logs... done."))
        XCTAssertTrue(viewModel.reasoningPanelText.contains("Summary\nChecking logs... done."))
    }

    func testSubmitPromptCapturesLateReasoningInFixedPanel() async throws {
        let sessionID = UUID()
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(
                text: "Final answer.",
                responseID: "resp_late_reasoning",
                toolCallsExecuted: 0
            )
        )
        service.streamEvents = [
            .assistantTextDelta("Final "),
            .assistantTextDone("Final answer."),
            .reasoningSummaryDone("Thinking done."),
        ]
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )

        viewModel.draftPrompt = "Test order"
        viewModel.submitPrompt(for: sessionID)

        try await waitUntil(timeout: 1.5) {
            !viewModel.isSending
        }

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[1].content, "Final answer.")
        XCTAssertFalse(viewModel.isReasoningStreaming)
        XCTAssertTrue(viewModel.reasoningPanelText.contains("Thinking done."))
    }

    func testSubmitPromptKeepsStreamedAssistantTextWhenFinalReplyTextEmpty() async throws {
        let sessionID = UUID()
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(
                text: "",
                responseID: "resp_stream_empty_final",
                toolCallsExecuted: 0
            )
        )
        service.streamEvents = [
            .assistantTextDelta("Hello from stream"),
        ]
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )

        viewModel.draftPrompt = "Say hello"
        viewModel.submitPrompt(for: sessionID)

        try await waitUntil(timeout: 1.5) {
            !viewModel.isSending
        }

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Hello from stream")
        XCTAssertFalse(viewModel.messages[1].isStreaming)
    }

    func testSubmitPromptFormatsDenseCapabilitySentenceIntoReadableList() async throws {
        let sessionID = UUID()
        let rawReply = "I can:Run commands and inspect output.Provide summaries and explain failures.Search files and inspect results."
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(
                text: rawReply,
                responseID: "resp_fmt",
                toolCallsExecuted: 0
            )
        )
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )

        viewModel.draftPrompt = "What can you do?"
        viewModel.submitPrompt(for: sessionID)

        try await waitUntil(timeout: 1.5) {
            !viewModel.isSending
        }

        let assistantText = viewModel.messages[1].content
        XCTAssertTrue(assistantText.contains("\n- "))
        XCTAssertFalse(assistantText.contains(".Provide"))
    }

    func testSubmitPromptFormatsCapabilityRunOnWithToolNamesIntoBulletList() async throws {
        let sessionID = UUID()
        let rawReply = "Sure, here is a concise list of abilities:Execute shell commands and return output directly (execute_and_wait).Run interactive commands (execute_command) and inspect live screen (get_current_screen).View command history (get_recent_commands) and fetch command output (get_command_output).Search files (search_filesystem) and content (search_file_contents)."
        let service = MockOpenAIAgentService(
            nextReply: OpenAIAgentReply(
                text: rawReply,
                responseID: "resp_fmt_tools",
                toolCallsExecuted: 0
            )
        )
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service,
            streamChunkDelayNanoseconds: 0
        )

        viewModel.draftPrompt = "List your abilities"
        viewModel.submitPrompt(for: sessionID)

        try await waitUntil(timeout: 1.5) {
            !viewModel.isSending
        }

        let assistantText = viewModel.messages[1].content
        let lowered = assistantText.lowercased()
        XCTAssertTrue(assistantText.contains("\n- "))
        XCTAssertTrue(lowered.contains("execute_and_wait"))
        XCTAssertTrue(lowered.contains("execute_command"))
        XCTAssertFalse(assistantText.contains(":Execute"))
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
    var streamEvents: [OpenAIAgentStreamEvent] = []
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

    func generateReply(
        sessionID: UUID,
        prompt: String,
        streamHandler: (@Sendable (OpenAIAgentStreamEvent) -> Void)?
    ) async throws -> OpenAIAgentReply {
        if replyDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: replyDelayNanoseconds)
        }
        capturedPrompts.append(prompt)
        if let streamHandler {
            for event in streamEvents {
                streamHandler(event)
            }
        }
        return nextReply
    }
}
#endif
