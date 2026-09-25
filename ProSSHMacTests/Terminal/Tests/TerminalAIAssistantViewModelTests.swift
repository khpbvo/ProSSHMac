#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class TerminalAIAssistantViewModelTests: XCTestCase {
    func testMarkdownTableIsParsedWithoutLeakingPipeRowsIntoText() {
        let segments = AIAssistantRenderer.parseSegments(from: """
        Current usage:

        | Category | Pages | Approx. |
        |:---|---:|:---:|
        | Active | 640,160 | ~9.8 GiB |

        Summary follows.
        """)
        XCTAssertEqual(segments.count, 3)
        guard case let .table(table) = segments[1].kind else {
            return XCTFail("Expected a rendered table segment")
        }
        XCTAssertEqual(table.headers, ["Category", "Pages", "Approx."])
        XCTAssertEqual(table.rows, [["Active", "640,160", "~9.8 GiB"]])
    }

    func testMarkdownParagraphBreakDoesNotDoubleSpace() {
        let rendered = AIAssistantRenderer.markdownText("First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(String(rendered.characters), "First paragraph.\nSecond paragraph.")
    }

    func testSubmitPromptAppendsUserAndAssistantMessages() async throws {
        let sessionID = UUID()
        let service = MockAgentService(
            nextReply: AIAgentReply(
                text: "Use `tail -f /var/log/system.log` for live logs.",
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
        let service = MockAgentService(
            nextReply: AIAgentReply(text: "ok", toolCallsExecuted: 0)
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

    /// `normalizeAssistantReply` was reduced to a trim in b6a7165 ("simplify markdown
    /// text processing"), which deliberately removed the paragraph/bullet reflow that
    /// rewrote the model's prose. The reply must now reach the message list verbatim
    /// apart from surrounding whitespace.
    func testSubmitPromptPassesAssistantReplyThroughUnmodified() async throws {
        let sessionID = UUID()
        let denseReply = """
        This repository contains a CLI orchestrator for document workflows. It includes configuration and runtime integration for external tools. The project also wires approval-aware execution paths for safe editing. It supports retrieval and summarization flows for large document sets.
        """
        let service = MockAgentService(
            nextReply: AIAgentReply(
                text: "  \n" + denseReply + "\n  ",
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
        XCTAssertEqual(viewModel.messages[1].content, denseReply,
                       "Reply should be trimmed but otherwise unmodified")
    }

    func testRequestPatchApprovalUsesModalStateWithoutInlineMessage() async throws {
        let service = MockAgentService(
            nextReply: AIAgentReply(text: "ok", toolCallsExecuted: 0)
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
        let service = MockAgentService(
            nextReply: AIAgentReply(text: "ok", toolCallsExecuted: 0)
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
        let service = MockAgentService(
            nextReply: AIAgentReply(
                text: "Done.",
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
        let service = MockAgentService(
            nextReply: AIAgentReply(
                text: "Final answer.",
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
        let service = MockAgentService(
            nextReply: AIAgentReply(
                text: "",
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
private final class MockAgentService: AIAgentServicing {
    var toolDefinitions: [LLMToolDefinition] = []
    var nextReply: AIAgentReply
    var replyDelayNanoseconds: UInt64
    var streamEvents: [AIAgentStreamEvent] = []
    private(set) var capturedPrompts: [String] = []
    private(set) var clearedSessionIDs: [UUID] = []

    init(nextReply: AIAgentReply, replyDelayNanoseconds: UInt64 = 0) {
        self.nextReply = nextReply
        self.replyDelayNanoseconds = replyDelayNanoseconds
    }

    nonisolated deinit {}

    func clearConversation(sessionID: UUID) {
        clearedSessionIDs.append(sessionID)
    }

    func generateReply(
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]? = nil
    ) async throws -> AIAgentReply {
        if replyDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: replyDelayNanoseconds)
        }
        capturedPrompts.append(prompt)
        return nextReply
    }

    func generateReply(
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]? = nil,
        streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)?
    ) async throws -> AIAgentReply {
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
