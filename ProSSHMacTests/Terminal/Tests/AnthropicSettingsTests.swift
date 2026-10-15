#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class AnthropicSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AnthropicURLProtocol.reset()
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "AnthropicSettingsTests.\(UUID().uuidString)")!
    }

    private func client(key: String? = "sk-ant-test") -> AnthropicClient {
        AnthropicClient(
            keyStore: AnthropicFixtureKeyStore(key: key),
            session: AnthropicURLProtocol.session(),
            baseURL: AnthropicURLProtocol.baseURL
        )
    }

    private func modelJSON(
        _ id: String,
        created: String,
        context: Int = 1_000_000,
        adaptive: Bool = true,
        effortLevels: [String] = ["low", "medium", "high", "xhigh", "max"],
        fallbacks: [String] = []
    ) -> String {
        let all = ["low", "medium", "high", "xhigh", "max"]
        let effort = all.map { #""\#($0)":{"supported":\#(effortLevels.contains($0))}"# }.joined(separator: ",")
        let fallbackList = fallbacks.map { #""\#($0)""# }.joined(separator: ",")
        return #"{"type":"model","id":"\#(id)","display_name":"\#(id) name","created_at":"\#(created)","max_input_tokens":\#(context),"max_tokens":128000,"allowed_fallback_models":[\#(fallbackList)],"capabilities":{"thinking":{"supported":true,"types":{"adaptive":{"supported":\#(adaptive)},"enabled":{"supported":false}}},"effort":{"supported":\#(!effortLevels.isEmpty),\#(effort)},"image_input":{"supported":true}}}"#
    }

    // MARK: - Catalog

    func testCatalogPaginatesSendsHeadersAndParsesCapabilities() async throws {
        AnthropicURLProtocol.set(
            "/v1/models?limit=1000",
            body: #"{"data":[\#(modelJSON("claude-old", created: "2025-01-01T00:00:00Z", context: 200_000, adaptive: false, effortLevels: []))],"has_more":true,"first_id":"claude-old","last_id":"claude-old"}"#
        )
        AnthropicURLProtocol.set(
            "/v1/models?limit=1000&after_id=claude-old",
            body: #"{"data":[\#(modelJSON("claude-opus-5-5", created: "2026-09-01T00:00:00Z", effortLevels: ["low", "medium", "high"], fallbacks: ["claude-opus-5"]))],"has_more":false,"first_id":"claude-opus-5-5","last_id":"claude-opus-5-5"}"#
        )
        let models = try await client().fetchModels()

        XCTAssertEqual(models.map(\.id), ["claude-opus-5-5", "claude-old"], "newest first")
        let opus = models[0]
        XCTAssertEqual(opus.displayName, "claude-opus-5-5 name")
        XCTAssertEqual(opus.maxInputTokens, 1_000_000)
        XCTAssertEqual(opus.maxTokens, 128_000)
        XCTAssertTrue(opus.supportsAdaptiveThinking)
        XCTAssertEqual(opus.supportedEffortLevels, [.low, .medium, .high])
        XCTAssertTrue(opus.supportsServerFallback)
        XCTAssertFalse(models[1].supportsAdaptiveThinking)
        XCTAssertEqual(models[1].supportedEffortLevels, [])
        XCTAssertFalse(models[1].supportsServerFallback)

        let requests = AnthropicURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        for recorded in requests {
            let request = recorded.request
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-06-01")
        }
    }

    func testMissingKeyFailsBeforeHTTPAndErrorBodyIsReported() async {
        do {
            _ = try await client(key: "  ").fetchModels()
            XCTFail("Expected missing key")
        } catch {
            XCTAssertEqual(error as? AnthropicError, .missingAPIKey)
        }
        XCTAssertTrue(AnthropicURLProtocol.requests.isEmpty)

        AnthropicURLProtocol.set(
            "/v1/models?limit=1000",
            body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#,
            status: 401
        )
        do {
            _ = try await client().fetchModels()
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error as? AnthropicError, .httpError(401, "invalid x-api-key"))
        }
    }

    // MARK: - Model store

    func testSelectionDefaultsPersistenceOutageAndRemoval() async throws {
        let catalog = AnthropicCatalogFixture()
        let isolated = defaults()
        let store = AnthropicModelStore(client: catalog, defaults: isolated)
        XCTAssertEqual(try store.requireSelection(), "claude-opus-5-5", "default before any catalog")
        XCTAssertEqual(store.contextLength(for: "claude-opus-5-5"), 200_000)
        XCTAssertEqual(store.maxOutputTokens(for: "claude-opus-5-5"), 64_000)
        XCTAssertNil(isolated.string(forKey: "ai.anthropic.model"), "the default is not persisted")

        catalog.models = [model("claude-opus-5-5", context: 1_000_000), model("claude-sonnet-5-5", context: 500_000)]
        await store.refresh()
        XCTAssertFalse(store.selectedModelUnavailable)
        XCTAssertEqual(store.contextLength(for: "claude-opus-5-5"), 1_000_000)
        try store.select("claude-sonnet-5-5")
        XCTAssertThrowsError(try store.select("claude-missing")) {
            XCTAssertEqual($0 as? AnthropicError, .modelUnavailable("claude-missing"))
        }

        catalog.failure = AnthropicError.transport("offline")
        let relaunched = AnthropicModelStore(client: catalog, defaults: isolated)
        await relaunched.refresh()
        XCTAssertEqual(try relaunched.requireSelection(), "claude-sonnet-5-5")
        XCTAssertEqual(relaunched.selectedModel?.displayName, "claude-sonnet-5-5")
        XCTAssertEqual(relaunched.contextLength(for: "claude-sonnet-5-5"), 500_000, "cached metadata survives an outage")
        XCTAssertNotNil(relaunched.catalogError)

        catalog.failure = nil
        catalog.models = [model("claude-opus-5-5")]
        await store.refresh()
        XCTAssertThrowsError(try store.requireSelection()) {
            XCTAssertEqual($0 as? AnthropicError, .modelUnavailable("claude-sonnet-5-5"))
        }
        let afterRemoval = AnthropicModelStore(client: catalog, defaults: isolated)
        XCTAssertThrowsError(try afterRemoval.requireSelection())
        try store.select("claude-opus-5-5")
        XCTAssertEqual(try store.requireSelection(), "claude-opus-5-5")
    }

    func testEffortDefaultPersistenceAndClamping() async throws {
        let catalog = AnthropicCatalogFixture()
        catalog.models = [
            model("claude-opus-5-5", effort: [.low, .medium, .high, .xhigh, .max]),
            model("claude-capped", effort: [.low, .medium, .high]),
            model("claude-haiku-4-5", effort: []),
        ]
        let isolated = defaults()
        let store = AnthropicModelStore(client: catalog, defaults: isolated)
        XCTAssertEqual(store.effort, .medium)
        XCTAssertEqual(store.effort(for: "claude-unknown"), .medium, "unknown model gets the setting")

        await store.refresh()
        store.setEffort(.xhigh)
        XCTAssertEqual(AnthropicModelStore(client: catalog, defaults: isolated).effort, .xhigh)
        XCTAssertEqual(store.effort(for: "claude-opus-5-5"), .xhigh)
        XCTAssertEqual(store.effort(for: "claude-capped"), .high)
        XCTAssertNil(store.effort(for: "claude-haiku-4-5"))
        store.setEffort(.low)
        XCTAssertEqual(store.effort(for: "claude-capped"), .low)
    }

    func testModelMetadataRoundTripsThroughTheSelectionCache() throws {
        let original = model("claude-opus-5-5", effort: [.medium, .high], fallbacks: ["claude-opus-5"])
        let decoded = try JSONDecoder().decode(AnthropicModel.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Keychain

    func testKeyUsesItsOwnServiceNotALegacyOne() {
        XCTAssertEqual(KeychainAnthropicAPIKeyStore.service, "nl.budgetsoft.ProSSHMac.anthropic")
        XCTAssertFalse(KeychainOpenRouterAPIKeyStore.legacyServices.contains(KeychainAnthropicAPIKeyStore.service))
        XCTAssertNotEqual(KeychainAnthropicAPIKeyStore.service, KeychainOpenRouterAPIKeyStore.service)
    }

    private func model(
        _ id: String,
        context: Int = 1_000_000,
        effort: [AnthropicEffort] = [.low, .medium, .high, .xhigh, .max],
        fallbacks: [String] = []
    ) -> AnthropicModel {
        let support = { (level: AnthropicEffort) in AnthropicModel.Support(supported: effort.contains(level)) }
        return AnthropicModel(
            id: id,
            displayName: id,
            createdAt: "2026-09-01T00:00:00Z",
            maxInputTokens: context,
            maxTokens: 128_000,
            allowedFallbackModels: fallbacks,
            capabilities: .init(
                thinking: .init(supported: true, types: .init(adaptive: .init(supported: true))),
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
private final class AnthropicCatalogFixture: AnthropicServicing {
    var models: [AnthropicModel] = []
    var failure: Error?
    func fetchModels() async throws -> [AnthropicModel] {
        if let failure { throw failure }
        return models
    }
    func complete(_ request: AnthropicRequest, onEvent: @escaping @Sendable (LLMStreamEvent) -> Void) async throws -> AnthropicResponse {
        throw AnthropicError.invalidResponse
    }
}

#endif
