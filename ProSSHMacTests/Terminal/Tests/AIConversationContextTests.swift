#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class AIConversationContextTests: XCTestCase {
    func testSessionIsolationAndClear() {
        let context = AIConversationContext()
        let first = UUID(), second = UUID()
        context.update(state: AIConversationState(turns: [[.user("one")]], lastModelID: "a"), for: first)
        context.update(state: AIConversationState(turns: [[.user("two")]], lastModelID: "a"), for: second)
        XCTAssertEqual(context.state(for: first)?.turns[0][0].content, "one")
        XCTAssertEqual(context.state(for: second)?.turns[0][0].content, "two")
        context.clear(sessionID: first)
        XCTAssertNil(context.state(for: first))
        XCTAssertNotNil(context.state(for: second))
    }

    func testModelSwitchRemovesOnlyReasoning() {
        let call = OpenRouterToolCall(id: "c", function: .init(name: "get_session_info", arguments: "{}"))
        var state = AIConversationState(turns: [[
            .user("question"),
            .init(role: "assistant", content: "", toolCalls: [call], reasoningDetails: [.object(["type": .string("reasoning.text")])]),
            .tool("result", callID: "c"),
            .init(role: "assistant", content: "answer")
        ]], lastModelID: "a")
        state.prepare(for: "a")
        XCTAssertNotNil(state.turns[0][1].reasoningDetails)
        state.prepare(for: "b")
        XCTAssertNil(state.turns[0][1].reasoningDetails)
        XCTAssertEqual(state.turns[0][1].toolCalls?.first?.id, "c")
        XCTAssertEqual(state.turns[0][2].toolCallID, "c")
    }

    func testReplayTrimsCompleteOldestExchange() throws {
        let call = OpenRouterToolCall(id: "c", function: .init(name: "lookup", arguments: "{}"))
        var state = AIConversationState(turns: [
            [.user(String(repeating: "old", count: 100)), .init(role: "assistant", content: nil, toolCalls: [call]), .tool("result", callID: "c")],
            [.user("recent"), .init(role: "assistant", content: "answer")]
        ], lastModelID: "a")
        let replay = try state.replay(systemPrompt: "system", currentTurn: [.user("current")], tools: [], contextLength: 256)
        XCTAssertEqual(state.turns.count, 1)
        XCTAssertFalse(replay.contains { $0.toolCallID == "c" })
        XCTAssertTrue(replay.contains { $0.content == "recent" })
    }
}
#endif
