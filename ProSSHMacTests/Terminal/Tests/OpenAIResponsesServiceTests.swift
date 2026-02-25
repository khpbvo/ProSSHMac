#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class OpenAIResponsesServiceTests: XCTestCase {

    @MainActor
    func testCreateResponsePinsModelAndParsesOutputText() async throws {
        let provider = StaticAPIKeyProvider(key: "sk-test-123")
        let mockSession = MockOpenAIHTTPSession()
        let responseBody = """
        {
          "id": "resp_123",
          "status": "completed",
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                { "type": "output_text", "text": "Hello from AI" }
              ]
            }
          ]
        }
        """
        await mockSession.setResponse(
            data: Data(responseBody.utf8),
            response: Self.makeHTTPResponse(statusCode: 200)
        )

        let service = OpenAIResponsesService(
            apiKeyProvider: provider,
            session: mockSession,
            endpointURL: URL(string: "https://example.com/v1/responses")!
        )

        let result = try await service.createResponse(
            OpenAIResponsesRequest(
                messages: [.init(role: .user, text: "Say hello")]
            )
        )

        let resultID = result.id
        let resultText = result.text
        XCTAssertEqual(resultID, "resp_123")
        XCTAssertEqual(resultText, "Hello from AI")

        let capturedRequest = await mockSession.lastRequest()
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")

        let body = try XCTUnwrap(capturedRequest?.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5.1-codex-max")
    }

    @MainActor
    func testCreateResponseThrowsWhenAPIKeyMissing() async {
        let service = OpenAIResponsesService(
            apiKeyProvider: StaticAPIKeyProvider(key: nil),
            session: MockOpenAIHTTPSession(),
            endpointURL: URL(string: "https://example.com/v1/responses")!
        )

        do {
            _ = try await service.createResponse(
                OpenAIResponsesRequest(
                    messages: [.init(role: .user, text: "test")]
                )
            )
            XCTFail("Expected missing API key error")
        } catch let error as OpenAIResponsesServiceError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCreateResponseThrowsHTTPError() async {
        let provider = StaticAPIKeyProvider(key: "sk-test-123")
        let mockSession = MockOpenAIHTTPSession()
        let responseBody = """
        {
          "error": {
            "message": "Invalid request payload."
          }
        }
        """
        await mockSession.setResponse(
            data: Data(responseBody.utf8),
            response: Self.makeHTTPResponse(statusCode: 400)
        )

        let service = OpenAIResponsesService(
            apiKeyProvider: provider,
            session: mockSession,
            endpointURL: URL(string: "https://example.com/v1/responses")!
        )

        do {
            _ = try await service.createResponse(
                OpenAIResponsesRequest(
                    messages: [.init(role: .user, text: "test")]
                )
            )
            XCTFail("Expected HTTP error")
        } catch let error as OpenAIResponsesServiceError {
            XCTAssertEqual(
                error,
                .httpError(statusCode: 400, message: "Invalid request payload.")
            )
            let requestCount = await mockSession.requestCount()
            XCTAssertEqual(requestCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCreateResponseRetriesTransientServerFailureThenSucceeds() async throws {
        let provider = StaticAPIKeyProvider(key: "sk-test-123")
        let mockSession = MockOpenAIHTTPSession()

        let serverErrorBody = """
        {
          "error": {
            "message": "An error occurred while processing your request."
          }
        }
        """
        let successBody = """
        {
          "id": "resp_retry_ok",
          "status": "completed",
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                { "type": "output_text", "text": "Recovered after retry." }
              ]
            }
          ]
        }
        """
        await mockSession.enqueueResponse(
            data: Data(serverErrorBody.utf8),
            response: Self.makeHTTPResponse(statusCode: 500)
        )
        await mockSession.enqueueResponse(
            data: Data(successBody.utf8),
            response: Self.makeHTTPResponse(statusCode: 200)
        )

        let service = OpenAIResponsesService(
            apiKeyProvider: provider,
            session: mockSession,
            endpointURL: URL(string: "https://example.com/v1/responses")!,
            maxRetryAttempts: 2,
            baseRetryDelayMilliseconds: 1
        )

        let result = try await service.createResponse(
            OpenAIResponsesRequest(messages: [.init(role: .user, text: "Retry please")])
        )

        XCTAssertEqual(result.id, "resp_retry_ok")
        XCTAssertEqual(result.text, "Recovered after retry.")
        let requestCount = await mockSession.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testCreateResponseRetriesInvalidResponseThenSucceeds() async throws {
        let provider = StaticAPIKeyProvider(key: "sk-test-123")
        let mockSession = MockOpenAIHTTPSession()
        let nonHTTPResponse = URLResponse(
            url: URL(string: "https://example.com/v1/responses")!,
            mimeType: "application/json",
            expectedContentLength: -1,
            textEncodingName: nil
        )
        let successBody = """
        {
          "id": "resp_invalid_retry_ok",
          "status": "completed",
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                { "type": "output_text", "text": "Recovered from invalid response." }
              ]
            }
          ]
        }
        """
        await mockSession.enqueueResponse(data: Data(), response: nonHTTPResponse)
        await mockSession.enqueueResponse(
            data: Data(successBody.utf8),
            response: Self.makeHTTPResponse(statusCode: 200)
        )

        let service = OpenAIResponsesService(
            apiKeyProvider: provider,
            session: mockSession,
            endpointURL: URL(string: "https://example.com/v1/responses")!,
            maxRetryAttempts: 2,
            baseRetryDelayMilliseconds: 1
        )

        let result = try await service.createResponse(
            OpenAIResponsesRequest(messages: [.init(role: .user, text: "retry on invalid")])
        )

        XCTAssertEqual(result.id, "resp_invalid_retry_ok")
        XCTAssertEqual(result.text, "Recovered from invalid response.")
        let requestCount = await mockSession.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testCreateResponseDoesNotRetryCancelledTransportFailure() async {
        let provider = StaticAPIKeyProvider(key: "sk-test-123")
        let mockSession = MockOpenAIHTTPSession()
        await mockSession.enqueueThrownError(URLError(.cancelled))

        let service = OpenAIResponsesService(
            apiKeyProvider: provider,
            session: mockSession,
            endpointURL: URL(string: "https://example.com/v1/responses")!,
            maxRetryAttempts: 2,
            baseRetryDelayMilliseconds: 1
        )

        do {
            _ = try await service.createResponse(
                OpenAIResponsesRequest(
                    messages: [.init(role: .user, text: "test")]
                )
            )
            XCTFail("Expected transport failure")
        } catch let error as OpenAIResponsesServiceError {
            if case .transportFailure = error {
                let requestCount = await mockSession.requestCount()
                XCTAssertEqual(requestCount, 1)
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCreateResponseEncodesFunctionToolsWithTopLevelName() async throws {
        let provider = StaticAPIKeyProvider(key: "sk-test-123")
        let mockSession = MockOpenAIHTTPSession()
        let responseBody = """
        {
          "id": "resp_123",
          "status": "completed",
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                { "type": "output_text", "text": "ok" }
              ]
            }
          ]
        }
        """
        await mockSession.setResponse(
            data: Data(responseBody.utf8),
            response: Self.makeHTTPResponse(statusCode: 200)
        )

        let service = OpenAIResponsesService(
            apiKeyProvider: provider,
            session: mockSession,
            endpointURL: URL(string: "https://example.com/v1/responses")!
        )

        let tool = OpenAIResponsesToolDefinition(
            name: "get_session_info",
            description: "Get current session details.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([]),
                "additionalProperties": .bool(false),
            ]),
            strict: true
        )

        _ = try await service.createResponse(
            OpenAIResponsesRequest(
                messages: [.init(role: .user, text: "status")],
                tools: [tool]
            )
        )

        let request = await mockSession.lastRequest()
        let capturedRequest = try XCTUnwrap(request)
        let body = try XCTUnwrap(capturedRequest.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let firstTool = try XCTUnwrap(tools.first)

        XCTAssertEqual(firstTool["type"] as? String, "function")
        XCTAssertEqual(firstTool["name"] as? String, "get_session_info")
        XCTAssertNil(firstTool["function"])
    }

    @MainActor
    func testCreateResponseStreamingFallbackEmitsOutputDoneEvent() async throws {
        let provider = StaticAPIKeyProvider(key: "sk-test-123")
        let mockSession = MockOpenAIHTTPSession()
        let responseBody = """
        {
          "id": "resp_stream_fallback",
          "status": "completed",
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                { "type": "output_text", "text": "Streaming fallback text" }
              ]
            }
          ]
        }
        """
        await mockSession.setResponse(
            data: Data(responseBody.utf8),
            response: Self.makeHTTPResponse(statusCode: 200)
        )

        let service = OpenAIResponsesService(
            apiKeyProvider: provider,
            session: mockSession,
            endpointURL: URL(string: "https://example.com/v1/responses")!
        )

        var streamEvents: [OpenAIResponsesStreamEvent] = []
        let result = try await service.createResponseStreaming(
            OpenAIResponsesRequest(messages: [.init(role: .user, text: "hello")]),
            onEvent: { streamEvents.append($0) }
        )

        XCTAssertEqual(result.id, "resp_stream_fallback")
        XCTAssertEqual(streamEvents, [.outputTextDone("Streaming fallback text")])
    }

    @MainActor
    func testCreateResponseStreamingParsesCRLFSSEEventsFromURLSession() async throws {
        let provider = StaticAPIKeyProvider(key: "sk-test-123")
        let responseID = "resp_stream_crlf"
        let eventLines = [
            "event: response.output_text.delta",
            #"data: {"type":"response.output_text.delta","response_id":"resp_stream_crlf","delta":"Hello"}"#,
            "",
            "event: response.output_text.delta",
            #"data: {"type":"response.output_text.delta","response_id":"resp_stream_crlf","delta":" world"}"#,
            "",
            "event: response.completed",
            #"data: {"type":"response.completed","response":{"id":"resp_stream_crlf","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello world"}]}]}}"#,
            "",
            "data: [DONE]",
            "",
        ]
        let body = eventLines.joined(separator: "\r\n")
        let session = Self.makeStubbedURLSession(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream; charset=utf-8"],
            body: Data(body.utf8)
        )

        let service = OpenAIResponsesService(
            apiKeyProvider: provider,
            session: session,
            endpointURL: URL(string: "https://example.com/v1/responses")!
        )

        var streamEvents: [OpenAIResponsesStreamEvent] = []
        let result = try await service.createResponseStreaming(
            OpenAIResponsesRequest(messages: [.init(role: .user, text: "hello")]),
            onEvent: { streamEvents.append($0) }
        )

        XCTAssertEqual(result.id, responseID)
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertTrue(streamEvents.contains(.outputTextDelta("Hello")))
        XCTAssertTrue(streamEvents.contains(.outputTextDelta(" world")))
    }

    @MainActor
    func testCreateResponseStreamingHandlesNonSSEJSONSuccessBody() async throws {
        let provider = StaticAPIKeyProvider(key: "sk-test-123")
        let responseBody = """
        {
          "id": "resp_json_fallback",
          "status": "completed",
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                { "type": "output_text", "text": "JSON fallback response" }
              ]
            }
          ]
        }
        """
        let session = Self.makeStubbedURLSession(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(responseBody.utf8)
        )

        let service = OpenAIResponsesService(
            apiKeyProvider: provider,
            session: session,
            endpointURL: URL(string: "https://example.com/v1/responses")!
        )

        var streamEvents: [OpenAIResponsesStreamEvent] = []
        let result = try await service.createResponseStreaming(
            OpenAIResponsesRequest(messages: [.init(role: .user, text: "hello")]),
            onEvent: { streamEvents.append($0) }
        )

        XCTAssertEqual(result.id, "resp_json_fallback")
        XCTAssertEqual(result.text, "JSON fallback response")
        XCTAssertEqual(streamEvents, [.outputTextDone("JSON fallback response")])
    }

    @MainActor
    func testCreateResponseStreamingEmitsReasoningSummaryFromSummaryPartEvents() async throws {
        let provider = StaticAPIKeyProvider(key: "sk-test-123")
        let eventLines = [
            "event: response.reasoning_summary_part.added",
            #"data: {"type":"response.reasoning_summary_part.added","response_id":"resp_reasoning","part":{"type":"summary_text","text":"Checking config... "}}"#,
            "",
            "event: response.reasoning_summary_part.done",
            #"data: {"type":"response.reasoning_summary_part.done","response_id":"resp_reasoning","part":{"type":"summary_text","text":"Checking config... done."}}"#,
            "",
            "event: response.completed",
            #"data: {"type":"response.completed","response":{"id":"resp_reasoning","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"All set."}]}]}}"#,
            "",
            "data: [DONE]",
            "",
        ]
        let body = eventLines.joined(separator: "\r\n")
        let session = Self.makeStubbedURLSession(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: Data(body.utf8)
        )

        let service = OpenAIResponsesService(
            apiKeyProvider: provider,
            session: session,
            endpointURL: URL(string: "https://example.com/v1/responses")!
        )

        var streamEvents: [OpenAIResponsesStreamEvent] = []
        let result = try await service.createResponseStreaming(
            OpenAIResponsesRequest(messages: [.init(role: .user, text: "hello")]),
            onEvent: { streamEvents.append($0) }
        )

        XCTAssertEqual(result.id, "resp_reasoning")
        XCTAssertTrue(streamEvents.contains(.reasoningSummaryTextDelta("Checking config... ")))
        XCTAssertTrue(streamEvents.contains(.reasoningSummaryTextDone("Checking config... done.")))
    }

    private static func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/v1/responses")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func makeStubbedURLSession(
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) -> URLSession {
        StubbedURLProtocol.configure(statusCode: statusCode, headers: headers, body: body)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubbedURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private struct StaticAPIKeyProvider: OpenAIAPIKeyProviding {
    var key: String?

    func currentAPIKey() async -> String? {
        key
    }
}

private actor MockOpenAIHTTPSession: OpenAIHTTPSessioning {
    private var request: URLRequest?
    private var data = Data()
    private var response: URLResponse = HTTPURLResponse(
        url: URL(string: "https://example.com")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    private var queuedResponses: [(Data, URLResponse)] = []
    private var queuedErrors: [Error] = []
    private var callCount = 0

    func setResponse(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
        self.queuedResponses.removeAll()
    }

    func enqueueResponse(data: Data, response: URLResponse) {
        queuedResponses.append((data, response))
    }

    func enqueueThrownError(_ error: Error) {
        queuedErrors.append(error)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        callCount += 1
        if !queuedErrors.isEmpty {
            throw queuedErrors.removeFirst()
        }
        if !queuedResponses.isEmpty {
            let next = queuedResponses.removeFirst()
            return next
        }
        return (data, response)
    }

    func lastRequest() -> URLRequest? {
        request
    }

    func requestCount() -> Int {
        callCount
    }
}

private final class StubbedURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statusCode: Int = 200
    private static var headers: [String: String] = [:]
    private static var body = Data()

    static func configure(statusCode: Int, headers: [String: String], body: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let statusCode = Self.statusCode
        let headers = Self.headers
        let body = Self.body
        Self.lock.unlock()

        guard let client else { return }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com/v1/responses")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client.urlProtocol(self, didLoad: body)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
