#if canImport(XCTest)
import Foundation
@testable import ProSSHMac

/// Serves canned Anthropic API responses for `anthropic.fixture.example`, keyed by path and
/// query, and records every request with its body. Each request takes the next queued response
/// for its key; the last one keeps being served.
final class AnthropicURLProtocol: URLProtocol {
    struct Fixture {
        var body: Data
        var status: Int
        var headers: [String: String]
        var fragmentSize: Int
    }

    struct RecordedRequest {
        var request: URLRequest
        var body: Data
        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: [Fixture]] = [:]
    nonisolated(unsafe) private static var recorded: [RecordedRequest] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicURLProtocol.self]
        return URLSession(configuration: config)
    }

    static let baseURL = URL(string: "https://anthropic.fixture.example/v1/")!

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queues = [:]
        recorded = []
    }

    /// Replaces the responses for `pathAndQuery` with this one.
    static func set(_ pathAndQuery: String, body: String, status: Int = 200, headers: [String: String] = [:], fragmentSize: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        queues[pathAndQuery] = [Fixture(body: Data(body.utf8), status: status, headers: headers, fragmentSize: fragmentSize)]
    }

    /// Adds a response after the ones already queued for `pathAndQuery`.
    static func enqueue(_ pathAndQuery: String, body: String, status: Int = 200, headers: [String: String] = [:], fragmentSize: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        queues[pathAndQuery, default: []].append(Fixture(body: Data(body.utf8), status: status, headers: headers, fragmentSize: fragmentSize))
    }

    static var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private static func key(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
        return (components?.path ?? "") + query
    }

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "anthropic.fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        Self.lock.lock()
        Self.recorded.append(RecordedRequest(request: request, body: Self.bodyData(of: request)))
        let key = Self.key(for: url)
        var fixture: Fixture?
        if var queue = Self.queues[key], !queue.isEmpty {
            fixture = queue.count > 1 ? queue.removeFirst() : queue[0]
            Self.queues[key] = queue
        }
        Self.lock.unlock()

        var headers = ["Content-Type": "application/json"]
        if let fixture { headers.merge(fixture.headers) { $1 } }
        guard let fixture,
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
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

final class AnthropicFixtureKeyStore: AIAPIKeyStoring {
    let key: String?
    init(key: String?) { self.key = key }
    func loadAPIKey() throws -> String? { key }
    func saveAPIKey(_ key: String) throws {}
    func deleteAPIKey() throws {}
}

/// Builds an SSE body from event payloads (each `data:` line followed by a blank line).
func anthropicSSE(_ events: [String]) -> String {
    events.map { payload -> String in
        let type = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])?["type"] as? String ?? "message"
        return "event: \(type)\ndata: \(payload)\n\n"
    }.joined()
}
#endif
