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
        XCTAssertEqual(json["model"] as? String, "gpt-5.1-codex")
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
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/v1/responses")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
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

    func setResponse(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return (data, response)
    }

    func lastRequest() -> URLRequest? {
        request
    }
}
#endif
