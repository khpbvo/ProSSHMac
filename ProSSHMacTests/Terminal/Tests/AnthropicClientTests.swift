#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class AnthropicClientTests: XCTestCase {
    private let messagesPath = "/v1/messages"

    override func setUp() {
        super.setUp()
        AnthropicURLProtocol.reset()
    }

    private func client(key: String? = "sk-ant-test", sleeps: SleepLog = SleepLog()) -> AnthropicClient {
        AnthropicClient(
            keyStore: AnthropicFixtureKeyStore(key: key),
            session: AnthropicURLProtocol.session(),
            baseURL: AnthropicURLProtocol.baseURL,
            sleep: { duration in sleeps.record(duration) }
        )
    }

    private func request(
        adaptiveThinking: Bool = true,
        effort: AnthropicEffort? = .medium,
        serverFallback: Bool = true,
        messages: [AnthropicMessage] = [.init(role: "user", content: [.text("hello")])]
    ) -> AnthropicRequest {
        AnthropicRequest(
            model: "claude-opus-5-5",
            maxTokens: 64_000,
            system: "You are a terminal copilot.",
            messages: messages,
            tools: [LLMToolDefinition(
                name: "read_files",
                description: "Read files",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["paths": .object(["type": .string("array")])]),
                    "required": .array([.string("paths")]),
                    "additionalProperties": .bool(false),
                ]),
                strict: true
            )],
            adaptiveThinking: adaptiveThinking,
            effort: effort,
            serverFallback: serverFallback
        )
    }

    // MARK: - SSE builders

    private func start(_ id: String = "msg_1", usage: String = #"{"input_tokens":120,"cache_read_input_tokens":100,"output_tokens":1}"#, transformations: String? = nil) -> String {
        let extra = transformations.map { #","input_transformations":\#($0)"# } ?? ""
        return #"{"type":"message_start","message":{"id":"\#(id)","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":\#(usage)\#(extra)}}"#
    }
    private func blockStart(_ index: Int, _ block: String) -> String {
        #"{"type":"content_block_start","index":\#(index),"content_block":\#(block)}"#
    }
    private func delta(_ index: Int, _ delta: String) -> String {
        #"{"type":"content_block_delta","index":\#(index),"delta":\#(delta)}"#
    }
    private func blockStop(_ index: Int) -> String { #"{"type":"content_block_stop","index":\#(index)}"# }
    private func stop(_ reason: String, details: String = "null", outputTokens: Int = 42) -> String {
        #"{"type":"message_delta","delta":{"stop_reason":"\#(reason)","stop_sequence":null,"stop_details":\#(details)},"usage":{"output_tokens":\#(outputTokens)}}"#
    }
    private let messageStop = #"{"type":"message_stop"}"#
    private let ping = #"{"type":"ping"}"#

    private func serve(_ events: [String], fragmentSize: Int = 0) {
        AnthropicURLProtocol.set(messagesPath, body: anthropicSSE(events), headers: ["Content-Type": "text/event-stream"], fragmentSize: fragmentSize)
    }

    // MARK: - Request

    func testRequestBodyAndHeadersWithThinkingEffortAndFallbacks() async throws {
        serve([start(), blockStart(0, #"{"type":"text","text":""}"#), delta(0, #"{"type":"text_delta","text":"hi"}"#), blockStop(0), stop("end_turn"), messageStop])
        let assistant = AnthropicBlock(json: #"{"signature":"sig","thinking":"t","type":"thinking"}"#)
        let req = request(messages: [
            .init(role: "user", content: [.text("hello")]),
            .init(role: "assistant", content: [assistant, .text("prior")]),
            .init(role: "user", content: [.toolResult(toolUseID: "toolu_1", content: "{\"ok\":true}")]),
        ])
        _ = try await client().complete(req) { _ in }

        let recorded = try XCTUnwrap(AnthropicURLProtocol.requests.last)
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "anthropic-beta"), "thinking-binding-controls-2026-08-01,server-side-fallback-2026-07-01")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "content-type"), "application/json")

        let body = try XCTUnwrap(recorded.json)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 64_000)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["temperature"])
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertEqual(thinking["display"] as? String, "summarized")
        XCTAssertEqual((thinking["block_binding"] as? [String: Any])?["prefix_mismatch_behavior"] as? String, "drop_block")
        XCTAssertNil(thinking["budget_tokens"])
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual((body["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["name"] as? String, "read_files")
        XCTAssertEqual(tool["eager_input_streaming"] as? Bool, true)
        XCTAssertEqual(tool["strict"] as? Bool, true)
        XCTAssertNotNil(tool["input_schema"] as? [String: Any])
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, "You are a terminal copilot.")

        let text = try XCTUnwrap(String(data: recorded.body, encoding: .utf8))
        XCTAssertTrue(text.contains(assistant.json), "replayed blocks are spliced verbatim")
        XCTAssertEqual(AnthropicClient.requestBody(for: req), AnthropicClient.requestBody(for: req), "byte-stable")
    }

    func testPlainModelSendsNoThinkingEffortFallbacksOrBetas() async throws {
        serve([start(), blockStart(0, #"{"type":"text","text":""}"#), delta(0, #"{"type":"text_delta","text":"hi"}"#), stop("end_turn"), messageStop])
        _ = try await client().complete(request(adaptiveThinking: false, effort: nil, serverFallback: false)) { _ in }
        let recorded = try XCTUnwrap(AnthropicURLProtocol.requests.last)
        XCTAssertNil(recorded.request.value(forHTTPHeaderField: "anthropic-beta"))
        let body = try XCTUnwrap(recorded.json)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        XCTAssertNil(body["fallbacks"])
        XCTAssertNotNil(body["cache_control"])
    }

    // MARK: - Stream

    func testThinkingAndTextStreamEventsReplayAndUsage() async throws {
        serve([
            start(transformations: #"[{"type":"thinking_dropped","path":"messages.1.content.0","reason":"model_binding_mismatch"}]"#),
            ping,
            blockStart(0, #"{"type":"thinking","thinking":"","signature":""}"#),
            delta(0, #"{"type":"thinking_delta","thinking":"Check the "}"#),
            delta(0, #"{"type":"thinking_delta","thinking":"uptime."}"#),
            delta(0, #"{"type":"signature_delta","signature":"EqQB"}"#),
            blockStop(0),
            blockStart(1, #"{"type":"text","text":""}"#),
            delta(1, #"{"type":"text_delta","text":"Load is "}"#),
            delta(1, #"{"type":"text_delta","text":"low \"/\" fine."}"#),
            blockStop(1),
            stop("end_turn"),
            messageStop,
        ], fragmentSize: 5)
        let events = EventLog()
        let response = try await client().complete(request()) { events.append($0) }

        XCTAssertEqual(events.all, [
            .reasoningSummaryDelta("Check the "), .reasoningSummaryDelta("uptime."),
            .textDelta("Load is "), .textDelta("low \"/\" fine."),
            .textDone("Load is low \"/\" fine."), .reasoningSummaryDone("Check the uptime."),
        ])
        XCTAssertEqual(response.id, "msg_1")
        XCTAssertEqual(response.model, "claude-opus-5-5")
        XCTAssertEqual(response.stopReason, "end_turn")
        XCTAssertEqual(response.text, "Load is low \"/\" fine.")
        XCTAssertEqual(response.content.map(\.json), [
            #"{"signature":"EqQB","thinking":"Check the uptime.","type":"thinking"}"#,
            #"{"text":"Load is low \"/\" fine.","type":"text"}"#,
        ])
        XCTAssertEqual(response.usage?.inputTokens, 120)
        XCTAssertEqual(response.usage?.cacheReadInputTokens, 100)
        XCTAssertEqual(response.usage?.outputTokens, 42)
        XCTAssertEqual(response.inputTransformations.count, 1)
        XCTAssertTrue(response.toolCalls.isEmpty)
    }

    func testParallelToolCallsFromFragmentedInput() async throws {
        serve([
            start(),
            blockStart(0, #"{"type":"text","text":""}"#),
            delta(0, #"{"type":"text_delta","text":"Reading."}"#),
            blockStart(1, #"{"type":"tool_use","id":"toolu_a","name":"read_files","input":{}}"#),
            delta(1, #"{"type":"input_json_delta","partial_json":""}"#),
            delta(1, #"{"type":"input_json_delta","partial_json":"{\"paths\": [\"/etc/"}"#),
            delta(1, #"{"type":"input_json_delta","partial_json":"hosts\"]}"}"#),
            blockStop(1),
            blockStart(2, #"{"type":"tool_use","id":"toolu_b","name":"get_current_screen","input":{}}"#),
            blockStop(2),
            stop("tool_use"),
            messageStop,
        ], fragmentSize: 7)
        let response = try await client().complete(request()) { _ in }
        XCTAssertEqual(response.toolCalls, [
            LLMToolCall(id: "toolu_a", name: "read_files", arguments: #"{"paths": ["/etc/hosts"]}"#),
            LLMToolCall(id: "toolu_b", name: "get_current_screen", arguments: "{}"),
        ])
        XCTAssertEqual(response.content.map(\.json), [
            #"{"text":"Reading.","type":"text"}"#,
            #"{"id":"toolu_a","input":{"paths": ["/etc/hosts"]},"name":"read_files","type":"tool_use"}"#,
            #"{"id":"toolu_b","input":{},"name":"get_current_screen","type":"tool_use"}"#,
        ])
    }

    func testInvalidToolInputIsPassedOnButReplayedAsEmptyObject() async throws {
        serve([
            start(),
            blockStart(0, #"{"type":"tool_use","id":"toolu_x","name":"read_files","input":{}}"#),
            delta(0, #"{"type":"input_json_delta","partial_json":"{\"paths\": [\"/a\"\"]"}"#),
            stop("tool_use"),
            messageStop,
        ])
        let response = try await client().complete(request()) { _ in }
        XCTAssertEqual(response.toolCalls.first?.arguments, #"{"paths": ["/a""]"#)
        XCTAssertEqual(response.content.map(\.json), [#"{"id":"toolu_x","input":{},"name":"read_files","type":"tool_use"}"#])
    }

    func testRefusalBeforeAndDuringOutput() async {
        let details = #"{"type":"refusal","category":"cyber","explanation":"Declined by policy."}"#
        serve([start(), stop("refusal", details: details), messageStop])
        await assertThrows(.refused(category: "cyber", explanation: "Declined by policy."))

        serve([
            start(),
            blockStart(0, #"{"type":"text","text":""}"#),
            delta(0, #"{"type":"text_delta","text":"Partial"}"#),
            blockStart(1, #"{"type":"tool_use","id":"toolu_r","name":"read_files","input":{}}"#),
            delta(1, #"{"type":"input_json_delta","partial_json":"{\"pa"}"#),
            stop("refusal", details: details),
            messageStop,
        ])
        await assertThrows(.refused(category: "cyber", explanation: "Declined by policy."))
    }

    func testMidStreamFallbackKeepsOnlyPostBoundaryReasoningAndTools() async throws {
        serve([
            start(),
            blockStart(0, #"{"type":"thinking","thinking":"","signature":""}"#),
            delta(0, #"{"type":"thinking_delta","thinking":"declined model thinking"}"#),
            delta(0, #"{"type":"signature_delta","signature":"S1"}"#),
            blockStart(1, #"{"type":"text","text":"Let me "}"#),
            blockStart(2, #"{"type":"tool_use","id":"toolu_old","name":"read_files","input":{}}"#),
            delta(2, #"{"type":"input_json_delta","partial_json":"{\"paths\":"}"#),
            blockStart(3, #"{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-5"}}"#),
            blockStart(4, #"{"type":"thinking","thinking":"","signature":""}"#),
            delta(4, #"{"type":"thinking_delta","thinking":"fallback thinking"}"#),
            delta(4, #"{"type":"signature_delta","signature":"S2"}"#),
            blockStart(5, #"{"type":"text","text":""}"#),
            delta(5, #"{"type":"text_delta","text":"check."}"#),
            blockStart(6, #"{"type":"tool_use","id":"toolu_new","name":"read_files","input":{}}"#),
            delta(6, #"{"type":"input_json_delta","partial_json":"{\"paths\":[\"/tmp\"]}"}"#),
            stop("tool_use"),
            messageStop,
        ])
        let response = try await client().complete(request()) { _ in }
        XCTAssertEqual(response.toolCalls.map(\.id), ["toolu_new"])
        XCTAssertEqual(response.text, "Let me check.")
        XCTAssertEqual(response.reasoning, "fallback thinking")
        XCTAssertEqual(response.content.map(\.json), [
            #"{"text":"Let me ","type":"text"}"#,
            #"{"signature":"S2","thinking":"fallback thinking","type":"thinking"}"#,
            #"{"text":"check.","type":"text"}"#,
            #"{"id":"toolu_new","input":{"paths":["/tmp"]},"name":"read_files","type":"tool_use"}"#,
        ])
    }

    func testIncompleteErrorAndMalformedStreams() async {
        serve([start(), blockStart(0, #"{"type":"text","text":"cut"}"#), stop("max_tokens"), messageStop])
        await assertThrows(.incompleteResponse)
        serve([start(), stop("model_context_window_exceeded"), messageStop])
        await assertThrows(.incompleteResponse)
        serve([start(), #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
        await assertThrows(.streamError("Overloaded"))
        serve([start(), blockStart(0, #"{"type":"text","text":"no stop"}"#), stop("end_turn")])
        await assertThrows(.invalidResponse)
        serve([start(), blockStart(0, #"{"type":"text","text":"hi"}"#), stop("tool_use"), messageStop])
        await assertThrows(.invalidToolCall)
        serve([start(), stop("pause_turn"), messageStop])
        await assertThrows(.invalidResponse)
    }

    // MARK: - HTTP

    func testRetriesOverloadHonoringRetryAfterButNotBadRequests() async throws {
        AnthropicURLProtocol.enqueue(messagesPath, body: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, status: 529, headers: ["retry-after": "3"])
        AnthropicURLProtocol.enqueue(messagesPath, body: anthropicSSE([start(), blockStart(0, #"{"type":"text","text":"ok"}"#), stop("end_turn"), messageStop]), headers: ["Content-Type": "text/event-stream"])
        let sleeps = SleepLog()
        let response = try await client(sleeps: sleeps).complete(request()) { _ in }
        XCTAssertEqual(response.text, "ok")
        XCTAssertEqual(sleeps.all, [.seconds(3)])
        XCTAssertEqual(AnthropicURLProtocol.requests.count, 2)

        AnthropicURLProtocol.reset()
        AnthropicURLProtocol.set(messagesPath, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"tool_choice is not supported"}}"#, status: 400)
        let noRetry = SleepLog()
        do {
            _ = try await client(sleeps: noRetry).complete(request()) { _ in }
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error as? AnthropicError, .httpError(400, "tool_choice is not supported"))
        }
        XCTAssertTrue(noRetry.all.isEmpty)
        XCTAssertEqual(AnthropicURLProtocol.requests.count, 1)
    }

    func testMissingKeyAndCancellation() async {
        do {
            _ = try await client(key: nil).complete(request()) { _ in }
            XCTFail("Expected missing key")
        } catch {
            XCTAssertEqual(error as? AnthropicError, .missingAPIKey)
        }
        XCTAssertTrue(AnthropicURLProtocol.requests.isEmpty)

        let cancelling = AnthropicClient(keyStore: AnthropicFixtureKeyStore(key: "k"), session: AnthropicCancellingSession(), baseURL: AnthropicURLProtocol.baseURL)
        do {
            _ = try await cancelling.complete(request()) { _ in }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    private func assertThrows(_ expected: AnthropicError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client().complete(request()) { _ in }
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AnthropicError, expected, file: file, line: line)
        }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LLMStreamEvent] = []
    func append(_ event: LLMStreamEvent) { lock.lock(); events.append(event); lock.unlock() }
    var all: [LLMStreamEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []
    func record(_ duration: Duration) { lock.lock(); durations.append(duration); lock.unlock() }
    var all: [Duration] { lock.lock(); defer { lock.unlock() }; return durations }
}

private struct AnthropicCancellingSession: AIHTTPSessioning {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw CancellationError() }
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) { throw CancellationError() }
}
#endif
