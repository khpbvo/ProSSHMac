#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class OpenAISettingsViewModelTests: XCTestCase {

    @MainActor
    func testRefreshWithNoStoredKeyShowsEmptyState() async {
        let store = InMemoryOpenAIAPIKeyStore()
        let viewModel = OpenAISettingsViewModel(apiKeyStore: store)

        await viewModel.refresh()

        XCTAssertFalse(viewModel.hasStoredAPIKey)
        XCTAssertNil(viewModel.storedKeyHint)
    }

    @MainActor
    func testSaveAndRemoveAPIKeyUpdatesState() async {
        let store = InMemoryOpenAIAPIKeyStore()
        let viewModel = OpenAISettingsViewModel(apiKeyStore: store)
        viewModel.apiKeyInput = "  sk-proj-test-5678  "

        await viewModel.saveAPIKey()

        XCTAssertTrue(viewModel.hasStoredAPIKey)
        XCTAssertEqual(viewModel.storedKeyHint, "••••5678")
        XCTAssertEqual(viewModel.apiKeyInput, "")
        let savedKey = await store.currentKey()
        XCTAssertEqual(savedKey, "sk-proj-test-5678")

        await viewModel.removeAPIKey()

        XCTAssertFalse(viewModel.hasStoredAPIKey)
        XCTAssertNil(viewModel.storedKeyHint)
        let removedKey = await store.currentKey()
        XCTAssertNil(removedKey)
    }

    @MainActor
    func testProviderFailsSafeWhenStoreThrows() async {
        let provider = DefaultOpenAIAPIKeyProvider(store: FailingOpenAIAPIKeyStore())
        let key = await provider.currentAPIKey()
        XCTAssertNil(key)
    }
}

private actor InMemoryOpenAIAPIKeyStore: OpenAIAPIKeyStoring {
    private var key: String?

    func loadAPIKey() async throws -> String? {
        key
    }

    func saveAPIKey(_ apiKey: String) async throws {
        key = apiKey
    }

    func deleteAPIKey() async throws {
        key = nil
    }

    func currentKey() -> String? {
        key
    }
}

private actor FailingOpenAIAPIKeyStore: OpenAIAPIKeyStoring {
    func loadAPIKey() async throws -> String? {
        throw OpenAIAPIKeyStoreError.invalidEncoding
    }

    func saveAPIKey(_ apiKey: String) async throws {}

    func deleteAPIKey() async throws {}
}
#endif
