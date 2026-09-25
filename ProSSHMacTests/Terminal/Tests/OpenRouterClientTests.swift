#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class OpenRouterClientTests: XCTestCase {
    private func client(key: String? = "test-key") -> OpenRouterClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenRouterURLProtocol.self]
        return OpenRouterClient(
            keyStore: FixtureKeyStore(key: key),
            session: URLSession(configuration: config),
            completionURL: URL(string: "https://fixture.example/chat/completions")!,
            modelsURL: URL(string: "https://fixture.example/models")!
        )
    }

    private func complete(_ client: OpenRouterClient) async throws -> OpenRouterCompletion {
        try await client.complete(model: "test/one", messages: [.user("hello")], tools: [], onEvent: { _ in })
    }

    func testCatalogFiltersToToolCapableTextModels() async throws {
        OpenRouterURLProtocol.set(path: "/models", body: #"{"data":[{"id":"test/one","name":"One","context_length":32000,"supported_parameters":["tools"],"architecture":{"input_modalities":["text"],"output_modalities":["text"]},"pricing":{"prompt":"0.000001","completion":"0.000002"}},{"id":"image/one","name":"Image","context_length":32000,"supported_parameters":["tools"],"architecture":{"input_modalities":["image"],"output_modalities":["image"]}},{"id":"text/no-tools","name":"No tools","supported_parameters":[],"architecture":{"input_modalities":["text"],"output_modalities":["text"]}}]}"#)
        let models = try await client().fetchModels()
        XCTAssertEqual(models.map(\.id), ["test/one"])
        XCTAssertEqual(models[0].promptPricePerMillion, 1)
        XCTAssertEqual(models[0].completionPricePerMillion, 2)
    }

    func testMissingKeyFailsBeforeHTTP() async {
        do {
            _ = try await client(key: nil).fetchModels()
            XCTFail("Expected missing key")
        } catch let error as OpenRouterError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testFragmentedParallelToolCallsReasoningAndUsage() async throws {
        let stream = """
        : OPENROUTER PROCESSING

        data: {"id":"r1","model":"test/one","choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"think"}],"tool_calls":[{"index":0,"id":"call_","function":{"name":"get_session_","arguments":"{"}},{"index":1,"id":"call_2","function":{"name":"get_session_info","arguments":"{"}}]},"finish_reason":null}]}

        data: {"id":"r1","choices":[{"delta":{"content":"Checking ","tool_calls":[{"index":0,"id":"1","function":{"name":"info","arguments":"}"}},{"index":1,"function":{"arguments":"}"}}]},"finish_reason":null}]}

        data: {"id":"r1","choices":[{"delta":{"content":"sessions"},"finish_reason":"tool_calls"}]}

        data: {"id":"r1","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"cost":0.0001}}

        data: [DONE]

        """
        OpenRouterURLProtocol.set(
            path: "/chat/completions",
            body: stream.replacingOccurrences(of: "\n", with: "\r\n"),
            contentType: "text/event-stream",
            fragmentSize: 7
        )
        let result = try await complete(client())
        let message = try XCTUnwrap(result.choices.first?.message)
        XCTAssertEqual(message.content, "Checking sessions")
        XCTAssertEqual(message.toolCalls?.map(\.id), ["call_1", "call_2"])
        XCTAssertEqual(message.toolCalls?.map(\.function.name), ["get_session_info", "get_session_info"])
        XCTAssertEqual(message.toolCalls?.map(\.function.arguments), ["{}", "{}"])
        XCTAssertEqual(message.reasoningDetails, [.object(["type": .string("reasoning.text"), "text": .string("think")])])
        XCTAssertEqual(result.usage?.totalTokens, 15)
        XCTAssertEqual(result.usage?.cost, 0.0001)
    }

    func testRateLimitAndMidstreamError() async {
        OpenRouterURLProtocol.set(path: "/chat/completions", body: #"{"error":{"message":"rate limited"}}"#, status: 429)
        do { _ = try await complete(client()); XCTFail("Expected 429") }
        catch let error as OpenRouterError {
            if case let .httpError(code, message) = error {
                XCTAssertEqual(code, 429); XCTAssertEqual(message, "rate limited")
            } else { XCTFail("Unexpected: \(error)") }
        } catch { XCTFail("Unexpected: \(error)") }

        OpenRouterURLProtocol.set(path: "/chat/completions", body: "data: {\"error\":{\"message\":\"route failed\"}}\n\ndata: [DONE]\n\n", contentType: "text/event-stream")
        do { _ = try await complete(client()); XCTFail("Expected stream error") }
        catch let error as OpenRouterError { XCTAssertEqual(error, .streamError("route failed")) }
        catch { XCTFail("Unexpected: \(error)") }
    }

    func testMalformedAndIncompleteStreamDoNotReturnToolCalls() async {
        OpenRouterURLProtocol.set(path: "/chat/completions", body: "data: {broken}\n\ndata: [DONE]\n\n", contentType: "text/event-stream")
        do { _ = try await complete(client()); XCTFail("Expected invalid response") }
        catch let error as OpenRouterError { XCTAssertEqual(error, .invalidResponse) }
        catch { XCTFail("Unexpected: \(error)") }

        OpenRouterURLProtocol.set(path: "/chat/completions", body: "data: {\"id\":\"r\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"function\":{\"name\":\"execute_command\",\"arguments\":\"{\\\"command\\\":\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n", contentType: "text/event-stream")
        do { _ = try await complete(client()); XCTFail("Expected invalid tool call") }
        catch let error as OpenRouterError { XCTAssertEqual(error, .invalidToolCall) }
        catch { XCTFail("Unexpected: \(error)") }
    }

    func testCancellationPropagatesWithoutRetry() async {
        let service = OpenRouterClient(
            keyStore: FixtureKeyStore(key: "test-key"),
            session: CancellingSession(),
            completionURL: URL(string: "https://fixture.example/chat/completions")!,
            modelsURL: URL(string: "https://fixture.example/models")!
        )
        do {
            _ = try await complete(service)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation must not be turned into a transport error or retried.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class FixtureKeyStore: OpenRouterAPIKeyStoring {
    let key: String?
    init(key: String?) { self.key = key }
    func loadAPIKey() throws -> String? { key }
    func saveAPIKey(_ key: String) throws {}
    func deleteAPIKey() throws {}
}

private final class OpenRouterURLProtocol: URLProtocol {
    struct Fixture {
        var body: Data
        var status: Int
        var contentType: String
        var fragmentSize: Int
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: Fixture] = [:]

    static func set(path: String, body: String, status: Int = 200, contentType: String = "application/json", fragmentSize: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        fixtures[path] = Fixture(body: Data(body.utf8), status: status, contentType: contentType, fragmentSize: fragmentSize)
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let fixture = Self.fixtures[request.url?.path ?? ""]
        Self.lock.unlock()
        guard let fixture, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": fixture.contentType]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let size = fixture.fragmentSize > 0 ? fixture.fragmentSize : max(1, fixture.body.count)
        var offset = 0
        while offset < fixture.body.count {
            let end = min(offset + size, fixture.body.count)
            client?.urlProtocol(self, didLoad: fixture.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct CancellingSession: OpenRouterHTTPSessioning {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw CancellationError()
    }
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw CancellationError()
    }
}
#endif
