#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

@MainActor
final class OpenRouterSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "OpenRouterSettingsTests.\(UUID().uuidString)")!
    }

    func testCleanupTargetsOnlyKnownLegacyServices() {
        XCTAssertEqual(Set(KeychainOpenRouterAPIKeyStore.legacyServices), [
            "nl.budgetsoft.ProSSHMac.llm.openai",
            "nl.budgetsoft.ProSSHMac.llm.mistral",
            "nl.budgetsoft.ProSSHMac.llm.anthropic",
            "nl.budgetsoft.ProSSHMac.llm.deepseek",
            "nl.budgetsoft.ProSSHV2.openai",
        ])
        XCTAssertFalse(KeychainOpenRouterAPIKeyStore.legacyServices.contains(KeychainOpenRouterAPIKeyStore.service))
    }

    func testExplicitSelectionAndCatalogOutageAndRemoval() async throws {
        let client = CatalogFixture()
        let isolatedDefaults = defaults()
        isolatedDefaults.set("old/model", forKey: "ai.model.active")
        let store = OpenRouterModelStore(client: client, defaults: isolatedDefaults)
        XCTAssertThrowsError(try store.requireSelection()) { XCTAssertEqual($0 as? OpenRouterError, .modelNotSelected) }
        client.models = [model("a"), model("b")]
        await store.refresh()
        try store.select("a")
        XCTAssertEqual(try store.requireSelection(), "a")
        client.failure = OpenRouterError.transport("offline")
        await store.refresh()
        XCTAssertEqual(try store.requireSelection(), "a")
        let relaunched = OpenRouterModelStore(client: client, defaults: isolatedDefaults)
        await relaunched.refresh()
        XCTAssertEqual(try relaunched.requireSelection(), "a")
        XCTAssertEqual(relaunched.selectedModel?.name, "a")
        XCTAssertEqual(relaunched.contextLength(for: "a"), 32_000)
        client.failure = nil
        client.models = [model("b")]
        await store.refresh()
        XCTAssertThrowsError(try store.requireSelection()) { XCTAssertEqual($0 as? OpenRouterError, .modelUnavailable("a")) }
        let afterRemoval = OpenRouterModelStore(client: client, defaults: isolatedDefaults)
        XCTAssertThrowsError(try afterRemoval.requireSelection()) { XCTAssertEqual($0 as? OpenRouterError, .modelUnavailable("a")) }
        try store.select("b")
        XCTAssertEqual(try store.requireSelection(), "b")
    }

    func testLegacyCleanupRetriesAndDoesNotDeleteOpenRouterSelection() async throws {
        let userDefaults = defaults()
        userDefaults.set("old", forKey: "ai.provider.active")
        userDefaults.set("a", forKey: "ai.openrouter.model")
        let deleter = CleanupFixture()
        let cleanup = LegacyProviderKeyCleanup(deleter: deleter, defaults: userDefaults)
        await deleter.setShouldFail(true)
        do { try await cleanup.runIfNeeded(); XCTFail("Expected Keychain failure") } catch {}
        XCTAssertEqual(userDefaults.string(forKey: "ai.provider.active"), "old")
        XCTAssertFalse(userDefaults.bool(forKey: "ai.openrouter.legacyKeysDeleted.v1"))
        await deleter.setShouldFail(false)
        try await cleanup.runIfNeeded()
        XCTAssertNil(userDefaults.string(forKey: "ai.provider.active"))
        XCTAssertEqual(userDefaults.string(forKey: "ai.openrouter.model"), "a")
        XCTAssertTrue(userDefaults.bool(forKey: "ai.openrouter.legacyKeysDeleted.v1"))
        try await cleanup.runIfNeeded()
        let calls = await deleter.calls
        XCTAssertEqual(calls, 2)
    }

    private func model(_ id: String) -> OpenRouterModel {
        .init(id: id, name: id, contextLength: 32000, supportedParameters: ["tools"], architecture: .init(inputModalities: ["text"], outputModalities: ["text"]), pricing: nil)
    }
}

@MainActor
private final class CatalogFixture: OpenRouterServicing {
    var models: [OpenRouterModel] = []
    var failure: Error?
    func fetchModels() async throws -> [OpenRouterModel] {
        if let failure { throw failure }
        return models
    }
    func complete(model: String, messages: [OpenRouterMessage], tools: [LLMToolDefinition], onEvent: @escaping @Sendable (LLMStreamEvent) -> Void) async throws -> OpenRouterCompletion {
        throw OpenRouterError.invalidResponse
    }
}

@MainActor
private final class CleanupFixture: LegacyProviderKeyDeleting {
    var shouldFail = false
    var calls = 0
    func setShouldFail(_ value: Bool) { shouldFail = value }
    func deleteLegacyProviderKeys() throws {
        calls += 1
        if shouldFail { throw OpenRouterKeyStoreError.keychain(-1) }
    }
}
#endif
