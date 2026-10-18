#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class AIConversationContextTests: XCTestCase {
    private let reasoningDetail = LLMJSONValue.object(["type": .string("reasoning.text"), "text": .string("private")])

    func testSessionIsolationAndClear() {
        let context = AIConversationContext()
        let first = UUID(), second = UUID()
        context.update(state: AIConversationState(turns: [[.user("one")]], lastModelID: "a"), for: first)
        context.update(state: AIConversationState(turns: [[.user("two")]], lastModelID: "a"), for: second)
        XCTAssertEqual(context.state(for: first)?.turns[0][0], .user("one"))
        XCTAssertEqual(context.state(for: second)?.turns[0][0], .user("two"))
        context.clear(conversationID: first)
        XCTAssertNil(context.state(for: first))
        XCTAssertNotNil(context.state(for: second))
    }

    func testModelSwitchRemovesOnlyReasoning() {
        let call = LLMToolCall(id: "c", name: "get_session_info", arguments: "{}")
        var state = AIConversationState(turns: [[
            .user("question"),
            .assistant(.init(text: "", toolCalls: [call], reasoning: .openRouter(details: [reasoningDetail], text: nil))),
            .toolResult(.init(callID: "c", output: "result")),
            .assistant(.init(text: "answer"))
        ]], lastModelID: "a")
        state.prepare(for: "a")
        XCTAssertNotNil(assistant(state.turns[0][1])?.reasoning)
        state.prepare(for: "b")
        XCTAssertNil(assistant(state.turns[0][1])?.reasoning)
        XCTAssertEqual(assistant(state.turns[0][1])?.toolCalls.first?.id, "c")
        XCTAssertEqual(state.turns[0][2], .toolResult(.init(callID: "c", output: "result")))
    }

    func testReplayTrimsCompleteOldestExchange() throws {
        let call = LLMToolCall(id: "c", name: "lookup", arguments: "{}")
        var state = AIConversationState(turns: [
            [.user(String(repeating: "old", count: 100)), .assistant(.init(text: nil, toolCalls: [call])), .toolResult(.init(callID: "c", output: "result"))],
            [.user("recent"), .assistant(.init(text: "answer"))]
        ], lastModelID: "a")
        let provider = OpenRouterChatProvider(client: UnusedOpenRouterService())
        let history = try state.fittedHistory(currentTurn: [.user("current")], contextLength: 256) {
            provider.estimatedRequestBytes(systemPrompt: "system", messages: $0, tools: [])
        }
        XCTAssertEqual(state.turns.count, 1)
        XCTAssertFalse(history.contains(.toolResult(.init(callID: "c", output: "result"))))
        XCTAssertTrue(history.contains(.user("recent")))
        XCTAssertEqual(history.last, .user("current"))
    }

    // MARK: - OpenRouter mapping

    func testClearedOrSupersededRunCannotRestoreConversation() {
        let context = AIConversationContext()
        let conversationID = UUID()
        let original = context.beginRun(for: conversationID)
        let state = AIConversationState(turns: [[.user("old")]])
        context.update(state: state, for: conversationID, runID: original)
        context.clear(conversationID: conversationID)
        context.update(state: state, for: conversationID, runID: original)
        XCTAssertNil(context.state(for: conversationID))

        let current = context.beginRun(for: conversationID)
        context.finishRun(original, for: conversationID)
        context.update(state: state, for: conversationID, runID: original)
        XCTAssertNil(context.state(for: conversationID))
        XCTAssertTrue(context.isCurrentRun(current, for: conversationID))
        context.update(state: state, for: conversationID, runID: current)
        XCTAssertEqual(context.state(for: conversationID), state)
        context.finishRun(current, for: conversationID)
        XCTAssertFalse(context.isCurrentRun(current, for: conversationID))
    }

    func testPrefixChangeStripsThinkingBeforeFittingHistory() throws {
        let thinking = AnthropicBlock(json: #"{"type":"thinking","thinking":""#
            + String(repeating: "x", count: 2000) + #"","signature":"old"}"#)
        var state = AIConversationState(
            turns: [[.user("keep this"), .assistant(.init(text: "answer", reasoning: .anthropic(blocks: [thinking, .text("answer")])))]],
            lastPrefixFingerprint: "old-prefix"
        )
        var current: [AITranscriptMessage] = [.user("next")]
        let messages = try state.requestHistory(currentTurn: &current, prefixFingerprint: "new-prefix", contextLength: 400, size: anthropicSize)
        XCTAssertEqual(state.turns.count, 1, "invalid thinking must not evict useful history")
        XCTAssertTrue(messages.contains(.user("keep this")))
        XCTAssertFalse(AnthropicChatProvider.messages(from: messages).flatMap(\.content).contains(where: \.isThinking))
    }

    func testTrimmingStripsCurrentThinkingBeforeRejectingOversizedTurn() throws {
        let thinking = AnthropicBlock(json: #"{"type":"thinking","thinking":""#
            + String(repeating: "x", count: 2000) + #"","signature":"old"}"#)
        var state = AIConversationState(turns: [[.user("old"), .assistant(.init(text: "done"))]])
        var current: [AITranscriptMessage] = [
            .user("current"),
            .assistant(.init(text: "answer", reasoning: .anthropic(blocks: [thinking, .text("answer")]))),
        ]
        let messages = try state.requestHistory(currentTurn: &current, prefixFingerprint: "prefix", contextLength: 400, size: anthropicSize)
        XCTAssertTrue(state.turns.isEmpty)
        XCTAssertTrue(messages.contains(.user("current")))
        XCTAssertFalse(AnthropicChatProvider.messages(from: messages).flatMap(\.content).contains(where: \.isThinking))
    }

    private func anthropicSize(_ messages: [AITranscriptMessage]) -> Int {
        AnthropicChatProvider.messages(from: messages).reduce(0) { size, message in
            size + message.content.reduce(0) { $0 + $1.json.utf8.count }
        }
    }

    func testOpenRouterAssistantMessagesRoundTripUnchanged() {
        let call = OpenRouterToolCall(id: "call_1", function: .init(name: "read_files", arguments: #"{"paths":["/tmp/a"]}"#))
        let messages: [OpenRouterMessage] = [
            .init(role: "assistant", content: "text only"),
            .init(role: "assistant", content: nil, toolCalls: [call]),
            .init(role: "assistant", content: "", toolCalls: [call]),
            .init(role: "assistant", content: "with details", reasoningDetails: [reasoningDetail]),
            .init(role: "assistant", content: "with reasoning", reasoning: "plain reasoning"),
        ]
        for message in messages {
            let turn = OpenRouterChatProvider.assistantTurn(from: message)
            XCTAssertEqual(OpenRouterChatProvider.wireMessage(.assistant(turn)), message)
        }
    }

    func testMappedToolCycleEncodesLikeHandBuiltMessages() throws {
        let call = OpenRouterToolCall(id: "call_1", function: .init(name: "execute_and_wait", arguments: #"{"command":"uptime"}"#))
        let handBuilt: [OpenRouterMessage] = [
            .system("system"),
            .user("question"),
            .init(role: "assistant", content: nil, toolCalls: [call], reasoningDetails: [reasoningDetail]),
            .tool(#"{"ok":true}"#, callID: "call_1"),
            .init(role: "assistant", content: "done"),
        ]
        let neutral: [AITranscriptMessage] = [
            .user("question"),
            .assistant(OpenRouterChatProvider.assistantTurn(from: handBuilt[2])),
            .toolResult(.init(callID: "call_1", output: #"{"ok":true}"#)),
            .assistant(.init(text: "done")),
        ]
        let mapped = OpenRouterChatProvider.wireMessages(systemPrompt: "system", messages: neutral)
        // JSONEncoder's key order can differ between two encodes; only sorted keys compare.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(mapped), try encoder.encode(handBuilt))
    }

    func testEstimatedRequestBytesMatchesWireEncodingPlusTools() throws {
        let tool = LLMToolDefinition(
            name: "lookup",
            description: "Look something up",
            parameters: .object(["type": .string("object")]),
            strict: true
        )
        let neutral: [AITranscriptMessage] = [.user("question"), .assistant(.init(text: "answer"))]
        let wire: [OpenRouterMessage] = [.system("system"), .user("question"), .init(role: "assistant", content: "answer")]
        let expected = try JSONEncoder().encode(wire).count
            + "lookup".utf8.count + "Look something up".utf8.count
            + JSONEncoder().encode(tool.parameters).count
        let provider = OpenRouterChatProvider(client: UnusedOpenRouterService())
        XCTAssertEqual(provider.estimatedRequestBytes(systemPrompt: "system", messages: neutral, tools: [tool]), expected)
    }

    private func assistant(_ message: AITranscriptMessage) -> AIAssistantTurn? {
        guard case let .assistant(turn) = message else { return nil }
        return turn
    }
}

@MainActor
private final class UnusedOpenRouterService: OpenRouterServicing {
    func fetchModels() async throws -> [OpenRouterModel] { [] }
    func complete(
        model: String,
        messages: [OpenRouterMessage],
        tools: [LLMToolDefinition],
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> OpenRouterCompletion {
        throw OpenRouterError.invalidResponse
    }
}
#endif
