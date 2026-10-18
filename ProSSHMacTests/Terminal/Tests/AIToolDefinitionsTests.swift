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
        XCTAssertTrue(prompt.contains("Never cut the path you are connected over"))
        XCTAssertTrue(prompt.contains("end with a handover, one line per host: what changed, how you verified it, how to undo it"))
    }

    /// The prompt holds what applies every turn (Docs/NetworkCopilot.md "Design rules"): no
    /// domain playbooks, and no rule pulling against another.
    func testPromptKeepsNoPlaybooksOrConflictingRules() {
        let prompt = AIToolDefinitions.developerPrompt()
        XCTAssertFalse(prompt.contains("compressed pages"))
        XCTAssertFalse(prompt.contains("minimum tool calls"))
        XCTAssertLessThan(prompt.split(separator: "\n").count, 30)
    }

    /// Passwords are typed by the user since Docs/CredentialPrompt.md; no tool may invite the
    /// model to send one.
    func testNoToolOffersToAnswerPasswords() {
        let tools = AIToolDefinitions.buildToolDefinitions()
        let sendInput = tools.first { $0.name == "send_input" }?.description ?? ""
        XCTAssertTrue(sendInput.contains("never passwords"))
        let cli = tools.first { $0.name == "run_cli_command" }?.description ?? ""
        XCTAssertTrue(cli.contains("the call waits while the user types it"))
        XCTAssertFalse(cli.contains("(confirm, password, filename)"))
    }

    /// Password prompts are handled in code (Docs/CredentialPrompt.md): no sudo choreography
    /// in the prompt or the tool descriptions.
    func testNoSudoWorkaroundIsLeftForTheModel() {
        let prompt = AIToolDefinitions.developerPrompt()
        XCTAssertFalse(prompt.contains("SUDO"))
        XCTAssertFalse(prompt.contains("sudo_password_required"))
        let descriptions = AIToolDefinitions.buildToolDefinitions(patchToolEnabled: true).map(\.description)
        XCTAssertFalse(descriptions.contains { $0.contains("sudo_password_required") })
        let executeAndWait = AIToolDefinitions.buildToolDefinitions().first { $0.name == "execute_and_wait" }
        XCTAssertTrue(executeAndWait?.description.contains("waits while the user types it") == true)
    }

    /// The skill index is the only thing skills add to the prompt: a header and one line each.
    func testSkillIndexAddsOneLinePerSkill() {
        let base = AIToolDefinitions.developerPrompt()
        let prompt = AIToolDefinitions.developerPrompt(skills: ["a — first", "b — second"])
        XCTAssertTrue(prompt.hasPrefix(base))
        XCTAssertEqual(prompt.split(separator: "\n", omittingEmptySubsequences: false).count,
                       base.split(separator: "\n", omittingEmptySubsequences: false).count + 4)
        XCTAssertTrue(prompt.hasSuffix("load_skill with the name before a task one covers):\n- a — first\n- b — second"))
        XCTAssertFalse(base.contains("SKILLS"))
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
