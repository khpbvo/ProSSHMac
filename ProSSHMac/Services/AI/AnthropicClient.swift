import Foundation

@MainActor
protocol AnthropicServicing: Sendable {
    func fetchModels() async throws -> [AnthropicModel]
}

/// Anthropic API over raw HTTPS (there is no Swift SDK). See `Docs/Anthropic.md`.
@MainActor
final class AnthropicClient: AnthropicServicing {
    nonisolated static let apiVersion = "2023-06-01"
    /// Makes `/v1/models` publish `allowed_fallback_models`.
    nonisolated static let modelsBetas = ["server-side-fallback-2026-06-01"]
    private static let maxCatalogPages = 20

    private struct APIErrorBody: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail?
    }

    private let keyStore: any AIAPIKeyStoring
    private let session: any AIHTTPSessioning
    private let baseURL: URL

    init(
        keyStore: any AIAPIKeyStoring,
        session: any AIHTTPSessioning = URLSession.shared,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1/")!
    ) {
        self.keyStore = keyStore
        self.session = session
        self.baseURL = baseURL
    }

    func fetchModels() async throws -> [AnthropicModel] {
        let key = try await requireKey()
        var models: [AnthropicModel] = []
        var afterID: String?
        do {
            for _ in 0..<Self.maxCatalogPages {
                var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                if let afterID { components.queryItems?.append(URLQueryItem(name: "after_id", value: afterID)) }
                var request = URLRequest(url: components.url!)
                request.timeoutInterval = 30
                applyHeaders(to: &request, key: key, betas: Self.modelsBetas)
                let (data, response) = try await session.data(for: request)
                try validate(response: response, data: data)
                let page = try JSONDecoder().decode(AnthropicModelsPage.self, from: data)
                models += page.data.filter { $0.type == nil || $0.type == "model" }
                guard page.hasMore, let lastID = page.lastID else { break }
                afterID = lastID
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AnthropicError {
            throw error
        } catch is DecodingError {
            throw AnthropicError.invalidResponse
        } catch {
            throw AnthropicError.transport(error.localizedDescription)
        }
        // Newest first; RFC 3339 timestamps in UTC sort correctly as strings.
        return models.sorted {
            if ($0.createdAt ?? "") != ($1.createdAt ?? "") { return ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            return $0.id < $1.id
        }
    }

    private func applyHeaders(to request: inout URLRequest, key: String, betas: [String]) {
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty {
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
    }

    private func requireKey() async throws -> String {
        let key = try await keyStore.loadAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { throw AnthropicError.missingAPIKey }
        return key
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw AnthropicError.httpError(http.statusCode, errorMessage(from: data))
        }
    }

    private func errorMessage(from data: Data) -> String {
        let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data).error?.message) ?? "Request failed"
        return String(message.prefix(500))
    }
}
