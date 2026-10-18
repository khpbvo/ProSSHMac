// BundledSkillsTests.swift
// ProSSHMac
//
// The skills shipped in the app (ProSSHMac/Resources/Skills/) all load, stay short, and hold
// procedures, not rules. See Docs/NetworkCopilot.md "Design rules" and Phase 6.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class BundledSkillsTests: XCTestCase {
    private static let expectedNames = [
        "access-safety", "baseline-and-diff", "change-procedure", "clone-deduplication",
        "linux-host-operations", "routing", "services", "troubleshooting",
    ]

    /// The test host is the app, so its resource root holds the flattened skill files.
    private var bundled: AISkillSet {
        AISkillLibrary(bundledDirectory: Bundle.main.resourceURL, userDirectory: nil).load()
    }

    func testEveryBundledSkillLoads() throws {
        XCTAssertEqual(bundled.skills.map(\.name), Self.expectedNames)
        // The parser only logs a bad file, so count the files too: none may be skipped.
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let files = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(files.count, Self.expectedNames.count)
        XCTAssertTrue(bundled.skills.allSatisfy { $0.source == .bundled })
    }

    /// The index line is paid on every turn and the body on every load.
    func testSkillsStayShort() {
        for skill in bundled.skills {
            XCTAssertLessThanOrEqual(skill.description.count, 120, skill.name)
            XCTAssertLessThanOrEqual(skill.body.split(separator: "\n", omittingEmptySubsequences: false).count, 80, skill.name)
        }
    }

    /// Rules live in the system prompt only, so a skill can never contradict it.
    func testSkillsHoldNoRules() {
        for skill in bundled.skills {
            let words = Set(skill.body.lowercased().split { !$0.isLetter }.map(String.init))
            XCTAssertTrue(words.isDisjoint(with: ["never", "always"]), skill.name)
        }
    }

    /// Skills point to each other by name; every name they mention must exist.
    func testCrossReferencesNameRealSkills() {
        let names = Set(Self.expectedNames)
        for skill in bundled.skills {
            for match in skill.body.matches(of: /load ([a-z]+(?:-[a-z]+)+)/) {
                XCTAssertTrue(names.contains(String(match.1)), "\(skill.name) refers to \(match.1)")
            }
        }
    }
}

#endif
