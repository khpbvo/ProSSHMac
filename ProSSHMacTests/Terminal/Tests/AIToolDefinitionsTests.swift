#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

// AIToolDefinitions is a caseless enum — static methods are nonisolated by default
// in Swift 6 even with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
final class AIToolDefinitionsTests: XCTestCase {

    // MARK: - developerPrompt

    func testDeveloperPromptIsNonEmpty() {
        XCTAssertFalse(AIToolDefinitions.developerPrompt().isEmpty)
    }

    func testDeveloperPromptContainsKeyPhrases() {
        let prompt = AIToolDefinitions.developerPrompt()
        XCTAssertTrue(prompt.contains("execute_and_wait"),
                      "Developer prompt should mention execute_and_wait tool")
        XCTAssertTrue(prompt.lowercased().contains("terminal"),
                      "Developer prompt should mention terminal")
    }

    // MARK: - isDirectActionPrompt

    func testIsDirectActionPromptTrueForRunPrefix() {
        XCTAssertTrue(AIToolDefinitions.isDirectActionPrompt("run ls -la"))
    }

    func testIsDirectActionPromptTrueForExecutePrefix() {
        XCTAssertTrue(AIToolDefinitions.isDirectActionPrompt("execute ls"))
    }

    func testIsDirectActionPromptTrueForCdPrefix() {
        XCTAssertTrue(AIToolDefinitions.isDirectActionPrompt("cd /tmp"))
    }

    func testIsDirectActionPromptFalseForFreeformText() {
        XCTAssertFalse(AIToolDefinitions.isDirectActionPrompt("What files are here?"))
    }

    // MARK: - shortTraceID / shortSessionID

    func testShortTraceIDIsNonEmpty() {
        XCTAssertFalse(AIToolDefinitions.shortTraceID().isEmpty)
    }

    func testShortSessionIDFormatsUUID() {
        let id = UUID()
        let short = AIToolDefinitions.shortSessionID(id)
        XCTAssertFalse(short.isEmpty)
        // Should be the first 8 characters of the UUID string, lowercased
        XCTAssertEqual(short.count, 8)
        XCTAssertEqual(short, String(id.uuidString.prefix(8)).lowercased())
    }

    // MARK: - directActionToolDefinitions

    func testDirectActionToolDefinitionsIsSubset() {
        let fullSet = AIToolDefinitions.buildToolDefinitions()
        let filtered = AIToolDefinitions.directActionToolDefinitions(from: fullSet)
        XCTAssertLessThan(filtered.count, fullSet.count,
                          "Direct action tools should be a strict subset of all tools")
        XCTAssertFalse(filtered.isEmpty)
    }
}

#endif
