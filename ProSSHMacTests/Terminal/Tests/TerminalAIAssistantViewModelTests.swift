#if canImport(XCTest)
import AppKit
import Combine
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

        let original = viewModel.conversationID
        viewModel.clearConversation()

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(service.clearedConversationIDs, [original])
        XCTAssertNotEqual(viewModel.conversationID, original, "Clear starts a new conversation")
    }

    func testPromptsFromDifferentSessionsShareOneConversation() async throws {
        let service = MockAgentService(nextReply: AIAgentReply(text: "ok", toolCallsExecuted: 0))
        let viewModel = TerminalAIAssistantViewModel(agentService: service, streamChunkDelayNanoseconds: 0)
        let first = UUID(), second = UUID()

        viewModel.draftPrompt = "check the first box"
        viewModel.submitPrompt(for: first)
        try await waitUntilIdle(viewModel)
        viewModel.draftPrompt = "now the second"
        viewModel.submitPrompt(for: second)
        try await waitUntilIdle(viewModel)

        XCTAssertEqual(service.capturedSessionIDs, [first, second])
        XCTAssertEqual(service.capturedConversationIDs, [viewModel.conversationID, viewModel.conversationID])

        let before = viewModel.conversationID
        viewModel.clearConversation()
        viewModel.draftPrompt = "fresh start"
        viewModel.submitPrompt(for: first)
        try await waitUntilIdle(viewModel)
        XCTAssertEqual(service.capturedConversationIDs.last, viewModel.conversationID)
        XCTAssertNotEqual(service.capturedConversationIDs.last, before)
    }

    private func waitUntilIdle(_ viewModel: TerminalAIAssistantViewModel) async throws {
        for _ in 0..<200 where viewModel.isSending {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(viewModel.isSending)
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

    func testReasoningWordFragmentsRenderAsSentencesWithIntentionalNewlines() async throws {
        let service = MockAgentService(nextReply: AIAgentReply(text: "Done.", toolCallsExecuted: 0))
        let fragments = ["Hel", "lo ", "how ", "can ", "I ", "help ", "you?", "\nNext line."]
        service.streamEvents = fragments.flatMap {
            [.reasoningTextDelta($0), .reasoningSummaryDelta($0)]
        }
        let viewModel = TerminalAIAssistantViewModel(agentService: service, streamChunkDelayNanoseconds: 0)
        viewModel.draftPrompt = "Say hello"
        viewModel.submitPrompt(for: UUID())

        try await waitUntil(timeout: 1.5) { !viewModel.isSending }

        let expected = "Hello how can I help you?\nNext line."
        XCTAssertEqual(viewModel.formattedReasoningSummary, expected)
        XCTAssertEqual(viewModel.formattedReasoningDetails, expected)
        XCTAssertEqual(String(AIAssistantRenderer.markdownText(viewModel.formattedReasoningDetails).characters), expected)
    }

    func testSecondLLMTurnRendersScreenshotFragmentsAsNormalProse() async throws {
        let sessionID = UUID()
        let service = MockAgentService(nextReply: AIAgentReply(text: "Done.", toolCallsExecuted: 0))
        service.streamEventDelayNanoseconds = 2_000_000
        let viewModel = TerminalAIAssistantViewModel(agentService: service, streamChunkDelayNanoseconds: 0)
        let panel = ReasoningStreamScrollView()
        panel.setFrameSize(NSSize(width: 400, height: 150))
        let expected = "User wants to cd into the test folder. There's a \"Test\" folder in Documents"
        var checkingSecondTurn = false
        var observedPrefixes: [String] = []
        let observation = viewModel.$reasoningDetails.sink { text in
            panel.update(summary: "", details: text)
            panel.layoutSubtreeIfNeeded()
            guard checkingSecondTurn, !text.isEmpty else { return }
            observedPrefixes.append(text)
            XCTAssertTrue(expected.hasPrefix(text))
            XCTAssertFalse(text.contains("\n"))
            guard let container = panel.reasoningTextView.textContainer,
                  let manager = panel.reasoningTextView.layoutManager else {
                return XCTFail("Missing text layout")
            }
            manager.ensureLayout(for: container)
            var lineCount = 0
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in
                lineCount += 1
            }
            // One heading line and at most two body lines at this viewport width.
            XCTAssertLessThanOrEqual(lineCount, 3, "Stacked prefix: \(text)")
        }
        defer { observation.cancel() }

        let firstReasoning = String(repeating: "Inspecting the Documents directory. ", count: 20)
        service.streamEvents = [.reasoningTextDelta(firstReasoning), .reasoningTextDone(firstReasoning)]
        viewModel.draftPrompt = "cd into Documents/"
        viewModel.submitPrompt(for: sessionID)
        try await waitUntil(timeout: 1.5) { !viewModel.isSending }
        XCTAssertGreaterThan(panel.contentView.bounds.origin.y, 0)

        checkingSecondTurn = true
        let fragments = ["User", " wants to cd into", " the", " test folder", ". There", "'s a \"Test\" folder", " in Documents"]
        service.streamEvents = fragments.map(AIAgentStreamEvent.reasoningTextDelta) + [.reasoningTextDone(expected)]
        viewModel.draftPrompt = "cd into the test folder"
        viewModel.submitPrompt(for: sessionID)
        try await waitUntil(timeout: 1.5) { !viewModel.isSending }

        XCTAssertGreaterThanOrEqual(observedPrefixes.count, fragments.count)
        XCTAssertEqual(viewModel.messages.count, 4)
        XCTAssertEqual(viewModel.formattedReasoningDetails, expected)
        XCTAssertEqual(panel.reasoningTextView.string, "THINKING\n" + expected)
        XCTAssertEqual(panel.contentView.bounds.origin.y, 0, accuracy: 0.5)
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

    // MARK: - Credential prompt card and Stop (Docs/CredentialPrompt.md Phase 2)

    func testCredentialPromptMirrorsTheSessionLayerAndReportsAnAnswer() {
        let prompts = FakeCredentialPrompts()
        let viewModel = makeViewModel(credentialPrompts: prompts)
        let waiting = makeCredentialRequest(phase: .waiting)

        prompts.subject.send(waiting)
        XCTAssertEqual(viewModel.credentialPrompt, waiting)
        let verifying = makeCredentialRequest(id: waiting.id, sessionID: waiting.sessionID, phase: .verifying)
        prompts.subject.send(verifying)
        XCTAssertEqual(viewModel.credentialPrompt, verifying)
        XCTAssertTrue(viewModel.messages.isEmpty, "a phase change is not an ending")

        prompts.subject.send(nil)
        XCTAssertNil(viewModel.credentialPrompt)
        XCTAssertEqual(viewModel.messages.map(\.content), ["Password entered on Testserv2."])
        XCTAssertEqual(viewModel.messages.first?.kind, .status)
        XCTAssertEqual(viewModel.credentialAnsweredNonce, 1)
    }

    func testPromptClosedWithoutAnAnswerDoesNotMoveFocus() {
        let prompts = FakeCredentialPrompts()
        let viewModel = makeViewModel(credentialPrompts: prompts)

        prompts.subject.send(makeCredentialRequest(phase: .waiting))
        prompts.subject.send(nil)

        XCTAssertNil(viewModel.credentialPrompt)
        XCTAssertEqual(viewModel.messages.map(\.content), ["The password prompt on Testserv2 closed."])
        XCTAssertEqual(viewModel.credentialAnsweredNonce, 0)
    }

    func testDeclineGoesToTheSessionLayerAndIsReported() async throws {
        let prompts = FakeCredentialPrompts()
        let viewModel = makeViewModel(credentialPrompts: prompts)
        let request = makeCredentialRequest(phase: .waiting)
        prompts.subject.send(request)

        viewModel.declineCredentialPrompt()
        try await waitUntil(timeout: 1.0) { viewModel.credentialPrompt == nil }

        XCTAssertEqual(prompts.declinedSessionIDs, [request.sessionID])
        XCTAssertEqual(viewModel.messages.map(\.content), ["Declined the password prompt on Testserv2."])
        XCTAssertEqual(viewModel.credentialAnsweredNonce, 0)
    }

    func testStopKeepsTheChatAndTheConversation() async throws {
        let prompts = FakeCredentialPrompts()
        let service = MockAgentService(
            nextReply: AIAgentReply(text: "never shown", toolCallsExecuted: 0),
            replyDelayNanoseconds: 5_000_000_000
        )
        let viewModel = makeViewModel(service: service, credentialPrompts: prompts)
        let conversationID = viewModel.conversationID

        viewModel.draftPrompt = "Update all hosts"
        viewModel.submitPrompt(for: UUID())
        try await waitUntil(timeout: 1.0) { viewModel.messages.count == 2 }
        viewModel.stop()

        XCTAssertFalse(viewModel.isSending)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.messages.map(\.content), ["Update all hosts", "Stopped."])
        XCTAssertFalse(viewModel.messages.contains(where: \.isStreaming))
        XCTAssertEqual(viewModel.conversationID, conversationID)
        XCTAssertTrue(service.clearedConversationIDs.isEmpty, "Stop keeps the model's memory")
        try await waitUntil(timeout: 1.0) { prompts.cancelCount == 1 }
        XCTAssertNil(viewModel.credentialPrompt)
    }

    func testStopWithAPromptUpCancelsItWithoutAClosedNotice() async throws {
        let prompts = FakeCredentialPrompts()
        let service = MockAgentService(
            nextReply: AIAgentReply(text: "never shown", toolCallsExecuted: 0),
            replyDelayNanoseconds: 5_000_000_000
        )
        let viewModel = makeViewModel(service: service, credentialPrompts: prompts)
        viewModel.draftPrompt = "sudo apt update on Testserv2"
        viewModel.submitPrompt(for: UUID())
        prompts.subject.send(makeCredentialRequest(phase: .waiting))

        viewModel.stop()
        try await waitUntil(timeout: 1.0) { viewModel.credentialPrompt == nil }

        XCTAssertEqual(prompts.cancelCount, 1)
        XCTAssertEqual(viewModel.messages.last?.content, "Stopped.")
        XCTAssertFalse(viewModel.messages.contains { $0.content.contains("closed") })
    }

    func testClearWithAPromptUpCancelsIt() async throws {
        let prompts = FakeCredentialPrompts()
        let viewModel = makeViewModel(credentialPrompts: prompts)
        prompts.subject.send(makeCredentialRequest(phase: .waiting))

        viewModel.clearConversation()
        try await waitUntil(timeout: 1.0) { viewModel.credentialPrompt == nil }

        XCTAssertEqual(prompts.cancelCount, 1)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testStopDoesNothingWhenIdle() {
        let prompts = FakeCredentialPrompts()
        let viewModel = makeViewModel(credentialPrompts: prompts)
        viewModel.stop()
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(prompts.cancelCount, 0)
    }

    func testStoppedStreamCannotChangeMessagesOrReasoningOfTheNextRun() async throws {
        let service = SuspendedAgentService()
        let viewModel = TerminalAIAssistantViewModel(agentService: service, streamChunkDelayNanoseconds: 0)
        viewModel.draftPrompt = "first"
        viewModel.submitPrompt(for: UUID())
        try await waitUntil(timeout: 1) { service.requests.count == 1 }
        service.requests[0].stream?(.assistantTextDelta("partial"))
        try await waitUntil(timeout: 1) { viewModel.messages.last?.content == "partial" }
        let firstAssistantID = try XCTUnwrap(viewModel.messages.last?.id)
        viewModel.stop()
        viewModel.draftPrompt = "second"
        viewModel.submitPrompt(for: UUID())
        try await waitUntil(timeout: 1) { service.requests.count == 2 }
        service.requests[0].stream?(.assistantTextDelta(" stale"))
        service.requests[0].stream?(.reasoningTextDelta("old reasoning"))
        service.requests[0].continuation.resume(returning: AIAgentReply(text: "old final", toolCallsExecuted: 0))
        service.requests[1].stream?(.reasoningTextDelta("new reasoning"))
        try await waitUntil(timeout: 1) { viewModel.reasoningDetails.contains("new reasoning") }
        XCTAssertEqual(viewModel.reasoningDetails, "new reasoning")
        XCTAssertEqual(viewModel.messages.first { $0.id == firstAssistantID }?.content, "partial")
        XCTAssertFalse(viewModel.messages.first { $0.id == firstAssistantID }?.isStreaming ?? true)
        XCTAssertTrue(viewModel.isSending)
        service.requests[1].continuation.resume(returning: AIAgentReply(text: "new final", toolCallsExecuted: 0))
        try await waitUntilIdle(viewModel)
        XCTAssertEqual(viewModel.messages.last?.content, "new final")
    }

    func testClearDiscardsLateReasoningFromThePreviousChat() async throws {
        let service = SuspendedAgentService()
        let viewModel = TerminalAIAssistantViewModel(agentService: service, streamChunkDelayNanoseconds: 0)
        viewModel.draftPrompt = "first"
        viewModel.submitPrompt(for: UUID())
        try await waitUntil(timeout: 1) { service.requests.count == 1 }
        viewModel.clearConversation()
        service.requests[0].stream?(.reasoningSummaryDone("stale summary"))
        service.requests[0].continuation.resume(returning: AIAgentReply(text: "stale reply", toolCallsExecuted: 0))
        // Enqueue a second run behind the old stream callback on the main actor.
        viewModel.draftPrompt = "second"
        viewModel.submitPrompt(for: UUID())
        try await waitUntil(timeout: 1) { service.requests.count == 2 }
        XCTAssertTrue(viewModel.reasoningPanelText.isEmpty)
        XCTAssertEqual(viewModel.messages.first?.content, "second")
        service.requests[1].continuation.resume(returning: AIAgentReply(text: "fresh", toolCallsExecuted: 0))
        try await waitUntilIdle(viewModel)
    }

    func testStopDuringFallbackAnimationKeepsTheNextRunActive() async throws {
        let service = SuspendedAgentService()
        let viewModel = TerminalAIAssistantViewModel(
            agentService: service, streamChunkDelayNanoseconds: 30_000_000,
            minChunkSize: 10, maxChunkSize: 10
        )
        viewModel.draftPrompt = "first"
        viewModel.submitPrompt(for: UUID())
        try await waitUntil(timeout: 1) { service.requests.count == 1 }
        service.requests[0].continuation.resume(returning: AIAgentReply(text: String(repeating: "a", count: 1000), toolCallsExecuted: 0))
        try await waitUntil(timeout: 1) { (viewModel.messages.last?.content.count ?? 0) == 10 }
        let oldID = try XCTUnwrap(viewModel.messages.last?.id)
        viewModel.stop()
        viewModel.draftPrompt = "second"
        viewModel.submitPrompt(for: UUID())
        try await waitUntil(timeout: 1) { service.requests.count == 2 }
        XCTAssertTrue(viewModel.isSending)
        XCTAssertEqual(viewModel.messages.first { $0.id == oldID }?.content.count, 10)
        service.requests[1].continuation.resume(returning: AIAgentReply(text: "done", toolCallsExecuted: 0))
        try await waitUntilIdle(viewModel)
    }

    private func makeViewModel(
        service: MockAgentService = MockAgentService(nextReply: AIAgentReply(text: "ok", toolCallsExecuted: 0)),
        credentialPrompts: FakeCredentialPrompts
    ) -> TerminalAIAssistantViewModel {
        TerminalAIAssistantViewModel(
            agentService: service,
            credentialPrompts: credentialPrompts,
            streamChunkDelayNanoseconds: 0
        )
    }

    private func makeCredentialRequest(
        id: UUID = UUID(),
        sessionID: UUID = UUID(),
        phase: CredentialWait.Phase
    ) -> CredentialPromptRequest {
        CredentialPromptRequest(
            id: id,
            sessionID: sessionID,
            hostLabel: "Testserv2",
            prompt: "[sudo] password for kevin:",
            kind: .sudo,
            command: "sudo apt update",
            phase: phase
        )
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
private final class FakeCredentialPrompts: CredentialPromptHandling {
    let subject = CurrentValueSubject<CredentialPromptRequest?, Never>(nil)
    private(set) var declinedSessionIDs: [UUID] = []
    private(set) var cancelCount = 0

    nonisolated deinit {}

    var credentialPromptPublisher: AnyPublisher<CredentialPromptRequest?, Never> {
        subject.eraseToAnyPublisher()
    }

    func declineCredentialPrompt(sessionID: UUID) async {
        declinedSessionIDs.append(sessionID)
        subject.send(nil)
    }

    func cancelCredentialPrompts() async {
        cancelCount += 1
        subject.send(nil)
    }
}

@MainActor
private final class SuspendedAgentService: AIAgentServicing {
    struct Request {
        let stream: (@Sendable (AIAgentStreamEvent) -> Void)?
        let continuation: CheckedContinuation<AIAgentReply, Never>
    }
    var requests: [Request] = []
    var toolDefinitions: [LLMToolDefinition] { [] }
    func clearConversation(conversationID: UUID) {}
    func generateReply(
        conversationID: UUID, sessionID: UUID, prompt: String,
        broadcastSessionIDs: [UUID]?, streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)?
    ) async throws -> AIAgentReply {
        await withCheckedContinuation { requests.append(Request(stream: streamHandler, continuation: $0)) }
    }
}

@MainActor
private final class MockAgentService: AIAgentServicing {
    var toolDefinitions: [LLMToolDefinition] = []
    var nextReply: AIAgentReply
    var replyDelayNanoseconds: UInt64
    var streamEvents: [AIAgentStreamEvent] = []
    var streamEventDelayNanoseconds: UInt64 = 0
    private(set) var capturedPrompts: [String] = []
    private(set) var clearedConversationIDs: [UUID] = []
    private(set) var capturedConversationIDs: [UUID] = []
    private(set) var capturedSessionIDs: [UUID] = []

    init(nextReply: AIAgentReply, replyDelayNanoseconds: UInt64 = 0) {
        self.nextReply = nextReply
        self.replyDelayNanoseconds = replyDelayNanoseconds
    }

    nonisolated deinit {}

    func clearConversation(conversationID: UUID) {
        clearedConversationIDs.append(conversationID)
    }

    func generateReply(
        conversationID: UUID,
        sessionID: UUID,
        prompt: String,
        broadcastSessionIDs: [UUID]?,
        streamHandler: (@Sendable (AIAgentStreamEvent) -> Void)?
    ) async throws -> AIAgentReply {
        if replyDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: replyDelayNanoseconds)
        }
        capturedPrompts.append(prompt)
        capturedConversationIDs.append(conversationID)
        capturedSessionIDs.append(sessionID)
        if let streamHandler {
            for event in streamEvents {
                streamHandler(event)
                if streamEventDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: streamEventDelayNanoseconds)
                }
            }
        }
        return nextReply
    }
}
#endif
