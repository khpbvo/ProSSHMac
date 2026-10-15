#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class AnthropicTranscriptTests: XCTestCase {
    private let thinking = AnthropicBlock(json: #"{"signature":"S","thinking":"why","type":"thinking"}"#)
    private let redacted = AnthropicBlock(json: #"{"data":"opaque","type":"redacted_thinking"}"#)
    private let toolUse = AnthropicBlock(json: #"{"id":"toolu_1","input":{"paths":["/etc/hosts"]},"name":"read_files","type":"tool_use"}"#)

    private func claudeTurn(_ blocks: [AnthropicBlock], text: String? = nil, calls: [LLMToolCall] = []) -> AITranscriptMessage {
        .assistant(.init(text: text, toolCalls: calls, reasoning: .anthropic(blocks: blocks)))
    }

    private func blocks(_ message: AITranscriptMessage) -> [AnthropicBlock]? {
        guard case let .assistant(turn) = message, case let .anthropic(blocks)? = turn.reasoning else { return nil }
        return blocks
    }

    // MARK: - Mapping

    func testMappingGroupsRoundsAndReplaysClaudeTurnsVerbatim() {
        let transcript: [AITranscriptMessage] = [
            .user("check hosts"),
            claudeTurn([thinking, .text("Reading."), toolUse], text: "Reading.", calls: [.init(id: "toolu_1", name: "read_files", arguments: "{}")]),
            .toolResult(.init(callID: "toolu_1", output: "127.0.0.1 localhost")),
            .toolResult(.init(callID: "toolu_2", output: "second")),
            claudeTurn([.text("Done.")], text: "Done."),
        ]
        let messages = AnthropicChatProvider.messages(from: transcript)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(messages[0].content, [.text("check hosts")])
        XCTAssertEqual(messages[1].content, [thinking, .text("Reading."), toolUse])
        XCTAssertEqual(messages[2].content, [
            .toolResult(toolUseID: "toolu_1", content: "127.0.0.1 localhost"),
            .toolResult(toolUseID: "toolu_2", content: "second"),
        ])
    }

    func testInterruptedTurnContinuesInTheSameUserMessage() {
        let transcript: [AITranscriptMessage] = [
            .user("first"),
            claudeTurn([toolUse]),
            .toolResult(.init(callID: "toolu_1", output: "result")),
            .user("second prompt"),
        ]
        let messages = AnthropicChatProvider.messages(from: transcript)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(messages[2].content, [.toolResult(toolUseID: "toolu_1", content: "result"), .text("second prompt")])
    }

    func testTurnsFromAnotherProviderAreRebuiltWithValidIDs() {
        let transcript: [AITranscriptMessage] = [
            .user("q"),
            .assistant(.init(
                text: "Let me look.",
                toolCalls: [
                    .init(id: "functions.read_files:0", name: "read_files", arguments: #"{"paths":["/a"]}"#),
                    .init(id: "call_2", name: "get_current_screen", arguments: "not json"),
                ],
                reasoning: .openRouter(details: [.object(["type": .string("reasoning.text")])], text: nil)
            )),
            .toolResult(.init(callID: "functions.read_files:0", output: "a")),
            .toolResult(.init(callID: "call_2", output: "screen")),
            .assistant(.init(text: nil)),
            .user("next"),
        ]
        let messages = AnthropicChatProvider.messages(from: transcript)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user"], "the empty assistant entry is skipped")
        XCTAssertEqual(messages[1].content.map(\.json), [
            #"{"text":"Let me look.","type":"text"}"#,
            #"{"id":"functions_read_files_0","input":{"paths":["/a"]},"name":"read_files","type":"tool_use"}"#,
            #"{"id":"call_2","input":{},"name":"get_current_screen","type":"tool_use"}"#,
        ])
        XCTAssertEqual(messages[2].content, [
            .toolResult(toolUseID: "functions_read_files_0", content: "a"),
            .toolResult(toolUseID: "call_2", content: "screen"),
            .text("next"),
        ])
    }

    func testRequestBodyOnlyAppendsAsTheConversationGrows() throws {
        let provider = AnthropicChatProvider(client: RecordingAnthropicService(), modelStore: AnthropicModelStore(client: RecordingAnthropicService(), defaults: defaults()))
        let first: [AITranscriptMessage] = [.user("q"), claudeTurn([thinking, toolUse]), .toolResult(.init(callID: "toolu_1", output: "r"))]
        let second = first + [claudeTurn([thinking, .text("answer")], text: "answer"), .user("follow-up")]
        func messagesJSON(_ transcript: [AITranscriptMessage]) throws -> String {
            let body = AnthropicClient.requestBody(for: provider.request(model: "claude-opus-5-5", systemPrompt: "s", messages: transcript, tools: []))
            let text = try XCTUnwrap(String(data: body, encoding: .utf8))
            let start = try XCTUnwrap(text.range(of: #""messages":["#)).upperBound
            return String(text[start...])
        }
        let before = try messagesJSON(first)
        let after = try messagesJSON(second)
        // Every earlier message is byte-identical; the new ones follow after a comma.
        let arrayEnd = try XCTUnwrap(before.range(of: #"}]}],""#)).lowerBound
        let earlierMessages = String(before[..<arrayEnd]) + "}]}"
        XCTAssertTrue(after.hasPrefix(earlierMessages + ","))
        XCTAssertTrue(after.dropFirst(earlierMessages.count).hasPrefix(#",{"role":"assistant","content":["#))
    }

    // MARK: - Replay rules

    func testPrefixChangeStripsThinkingOnceIncludingTheCurrentTurn() throws {
        var state = AIConversationState(turns: [[.user("old"), claudeTurn([thinking, redacted, .text("a")], text: "a")]], lastModelID: "claude-opus-5-5")
        var current: [AITranscriptMessage] = [.user("new"), claudeTurn([thinking, toolUse])]
        let size: ([AITranscriptMessage]) -> Int = { _ in 1 }

        _ = try state.requestHistory(currentTurn: &current, prefixFingerprint: "tools-A", contextLength: 1_000_000, size: size)
        XCTAssertEqual(blocks(state.turns[0][1]), [thinking, redacted, .text("a")], "the first fingerprint strips nothing")

        let history = try state.requestHistory(currentTurn: &current, prefixFingerprint: "tools-B", contextLength: 1_000_000, size: size)
        XCTAssertEqual(blocks(state.turns[0][1]), [.text("a")])
        XCTAssertEqual(blocks(current[1]), [toolUse])
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(blocks(history[3]), [toolUse], "the returned history is the stripped one")
        XCTAssertEqual(state.lastPrefixFingerprint, "tools-B")

        current.append(claudeTurn([thinking, .text("fresh")], text: "fresh"))
        _ = try state.requestHistory(currentTurn: &current, prefixFingerprint: "tools-B", contextLength: 1_000_000, size: size)
        XCTAssertEqual(blocks(current[2]), [thinking, .text("fresh")], "same prefix keeps new blocks")
    }

    func testTrimmingStripsThinkingFromKeptTurns() throws {
        let openRouterTurn = AITranscriptMessage.assistant(.init(text: "or", reasoning: .openRouter(details: nil, text: "plain")))
        var state = AIConversationState(turns: [
            [.user(String(repeating: "x", count: 500)), claudeTurn([thinking, .text("old")], text: "old")],
            [.user("kept"), claudeTurn([thinking, .text("kept answer")], text: "kept answer"), openRouterTurn],
        ])
        var current: [AITranscriptMessage] = [.user("now")]
        let history = try state.requestHistory(currentTurn: &current, prefixFingerprint: nil, contextLength: 200) { messages in
            messages.reduce(0) { total, message in
                if case let .user(text) = message { return total + text.count }
                return total + 10
            }
        }
        XCTAssertEqual(state.turns.count, 1)
        XCTAssertEqual(blocks(state.turns[0][1]), [.text("kept answer")])
        XCTAssertEqual(state.turns[0][2], openRouterTurn, "OpenRouter reasoning is not Anthropic's to strip")
        XCTAssertEqual(history.last, .user("now"))
    }

    func testModelSwitchKeepsClaudeBlocksButDropsOpenRouterReasoning() {
        let openRouterTurn = AITranscriptMessage.assistant(.init(text: "or", reasoning: .openRouter(details: nil, text: "plain")))
        var state = AIConversationState(turns: [[.user("q"), claudeTurn([thinking, .text("a")], text: "a"), openRouterTurn]], lastModelID: "claude-opus-5-5")
        state.prepare(for: "claude-sonnet-5-5")
        XCTAssertEqual(blocks(state.turns[0][1]), [thinking, .text("a")])
        XCTAssertEqual(state.turns[0][2], .assistant(.init(text: "or")))
    }

    // MARK: - Provider

    func testProviderBuildsRequestFromModelMetadata() async throws {
        let service = RecordingAnthropicService()
        service.models = [
            catalogModel("claude-opus-5-5", maxTokens: 128_000, adaptive: true, effort: [.low, .medium, .high], fallbacks: ["claude-opus-5"]),
            catalogModel("claude-haiku-4-5", maxTokens: 8_192, adaptive: false, effort: [], fallbacks: []),
        ]
        service.response = AnthropicResponse(id: "msg", model: "claude-opus-5-5", content: [thinking, .text("hi")], text: "hi", reasoning: "why", toolCalls: [], stopReason: "end_turn", usage: nil, inputTransformations: [])
        let store = AnthropicModelStore(client: service, defaults: defaults())
        await store.refresh()
        store.setEffort(.max)
        let provider = AnthropicChatProvider(client: service, modelStore: store)
        XCTAssertTrue(provider.requiresStableToolSet)

        let turn = try await provider.complete(model: "claude-opus-5-5", systemPrompt: "s", messages: [.user("q")], tools: []) { _ in }
        XCTAssertEqual(turn, AIAssistantTurn(text: "hi", toolCalls: [], reasoning: .anthropic(blocks: [thinking, .text("hi")])))
        let opus = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(opus.model, "claude-opus-5-5")
        XCTAssertEqual(opus.maxTokens, 64_000)
        XCTAssertEqual(opus.effort, .high, "clamped to the model's highest level")
        XCTAssertTrue(opus.adaptiveThinking)
        XCTAssertTrue(opus.serverFallback)
        XCTAssertEqual(opus.messages, [AnthropicMessage(role: "user", content: [.text("q")])])

        service.response.text = ""
        let empty = try await provider.complete(model: "claude-haiku-4-5", systemPrompt: "s", messages: [.user("q")], tools: []) { _ in }
        XCTAssertNil(empty.text)
        let haiku = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(haiku.maxTokens, 8_192)
        XCTAssertNil(haiku.effort)
        XCTAssertFalse(haiku.adaptiveThinking)
        XCTAssertFalse(haiku.serverFallback)

        _ = try await provider.complete(model: "claude-unlisted", systemPrompt: "s", messages: [.user("q")], tools: []) { _ in }
        let unknown = try XCTUnwrap(service.requests.last)
        XCTAssertTrue(unknown.adaptiveThinking)
        XCTAssertFalse(unknown.serverFallback)
        XCTAssertEqual(unknown.effort, .max)
    }

    func testFingerprintFollowsSystemPromptAndTools() {
        let provider = AnthropicChatProvider(client: RecordingAnthropicService(), modelStore: AnthropicModelStore(client: RecordingAnthropicService(), defaults: defaults()))
        let tool = LLMToolDefinition(name: "a", description: "d", parameters: .object([:]), strict: nil)
        let base = provider.prefixFingerprint(systemPrompt: "s", tools: [tool])
        XCTAssertEqual(base, provider.prefixFingerprint(systemPrompt: "s", tools: [tool]))
        XCTAssertNotEqual(base, provider.prefixFingerprint(systemPrompt: "s2", tools: [tool]))
        XCTAssertNotEqual(base, provider.prefixFingerprint(systemPrompt: "s", tools: []))
        XCTAssertNil(OpenRouterChatProvider(client: UnusedChatOpenRouterService()).prefixFingerprint(systemPrompt: "s", tools: [tool]))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "AnthropicTranscriptTests.\(UUID().uuidString)")!
    }

    private func catalogModel(_ id: String, maxTokens: Int, adaptive: Bool, effort: [AnthropicEffort], fallbacks: [String]) -> AnthropicModel {
        let support = { (level: AnthropicEffort) in AnthropicModel.Support(supported: effort.contains(level)) }
        return AnthropicModel(
            id: id,
            displayName: id,
            maxInputTokens: 1_000_000,
            maxTokens: maxTokens,
            allowedFallbackModels: fallbacks,
            capabilities: .init(
                thinking: .init(supported: true, types: .init(adaptive: .init(supported: adaptive))),
                effort: .init(
                    supported: !effort.isEmpty,
                    low: support(.low), medium: support(.medium), high: support(.high),
                    xhigh: support(.xhigh), max: support(.max)
                )
            )
        )
    }
}

@MainActor
private final class RecordingAnthropicService: AnthropicServicing {
    var models: [AnthropicModel] = []
    var requests: [AnthropicRequest] = []
    var response = AnthropicResponse(id: "", model: "", content: [], text: "", reasoning: "", toolCalls: [], stopReason: "end_turn", usage: nil, inputTransformations: [])
    func fetchModels() async throws -> [AnthropicModel] { models }
    func complete(_ request: AnthropicRequest, onEvent: @escaping @Sendable (LLMStreamEvent) -> Void) async throws -> AnthropicResponse {
        requests.append(request)
        return response
    }
}

@MainActor
private final class UnusedChatOpenRouterService: OpenRouterServicing {
    func fetchModels() async throws -> [OpenRouterModel] { [] }
    func complete(model: String, messages: [OpenRouterMessage], tools: [LLMToolDefinition], onEvent: @escaping @Sendable (LLMStreamEvent) -> Void) async throws -> OpenRouterCompletion {
        throw OpenRouterError.invalidResponse
    }
}
#endif
