// AISkillLibraryTests.swift
// ProSSHMac
//
// Skills: front matter parsing, user override, invalid files skipped, folders absent.
// See Docs/NetworkCopilot.md Phase 5.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class AISkillLibraryTests: XCTestCase {
    private var bundled: URL!
    private var user: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-library-\(UUID().uuidString)", isDirectory: true)
        bundled = root.appendingPathComponent("bundled", isDirectory: true)
        user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundled.deletingLastPathComponent())
    }

    private func write(_ text: String, _ file: String, in directory: URL) throws {
        try text.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    private func skill(_ name: String, description: String = "Does a thing", body: String = "Step one.") -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\(body)\n"
    }

    func testParsesFrontMatterAndBody() throws {
        let parsed = try AISkillLibrary.parse(
            "---\nname: change-procedure\ndescription: Pre-checks, steps: rollback\nplatforms: [linux, junos]\n---\n\n# Steps\n1. Check.\n",
            source: .bundled
        )
        XCTAssertEqual(parsed, AISkill(
            name: "change-procedure",
            description: "Pre-checks, steps: rollback",
            platforms: ["linux", "junos"],
            body: "# Steps\n1. Check.",
            source: .bundled
        ))
        XCTAssertEqual(
            try AISkillLibrary.parse("---\r\nname: x\r\ndescription: y\r\nplatforms: ios, eos\r\n---\r\nbody", source: .user).platforms,
            ["ios", "eos"]
        )
    }

    func testInvalidFilesAreSkippedAndTheRestLoad() throws {
        try write(skill("good"), "good.md", in: bundled)
        try write("name: nofrontmatter\ndescription: x\nbody", "a.md", in: bundled)
        try write("---\ndescription: no name\n---\nbody", "b.md", in: bundled)
        try write("---\nname: no-description\n---\nbody", "c.md", in: bundled)
        try write(skill("Bad_Name"), "d.md", in: bundled)
        try write(skill("long", description: String(repeating: "x", count: 201)), "e.md", in: bundled)
        try write("---\nname: wrapped\ndescription: first line\n  continues here\n---\nbody", "f.md", in: bundled)
        try write(skill("empty", body: "  \n"), "g.md", in: bundled)
        try write("---\nname: unterminated\ndescription: x\nbody", "h.md", in: bundled)
        try write(skill("ignored"), "notes.txt", in: bundled)

        let loaded = AISkillLibrary(bundledDirectory: bundled, userDirectory: nil).load()
        XCTAssertEqual(loaded.skills.map(\.name), ["good"])
    }

    func testUserSkillReplacesBundledSkillOfTheSameName() throws {
        try write(skill("routing", description: "Built in"), "routing.md", in: bundled)
        try write(skill("services"), "services.md", in: bundled)
        try write(skill("routing", description: "My routing"), "my-routing.md", in: user)
        try write(skill("my-lab", description: "Hosts and roles"), "my-lab.md", in: user)

        let loaded = AISkillLibrary(bundledDirectory: bundled, userDirectory: user).load()
        XCTAssertEqual(loaded.skills.map(\.name), ["my-lab", "routing", "services"])
        XCTAssertEqual(loaded.skill(named: "routing")?.description, "My routing")
        XCTAssertEqual(loaded.skill(named: "routing")?.source, .user)
        XCTAssertEqual(loaded.skill(named: "services")?.source, .bundled)
        XCTAssertEqual(loaded.indexLines, [
            "my-lab — Hosts and roles",
            "routing — My routing",
            "services — Does a thing",
        ])
    }

    func testDuplicateNameInOneFolderKeepsTheFirstFile() throws {
        try write(skill("dup", description: "first"), "a.md", in: user)
        try write(skill("dup", description: "second"), "b.md", in: user)
        let loaded = AISkillLibrary(bundledDirectory: nil, userDirectory: user).load()
        XCTAssertEqual(loaded.skills.map(\.description), ["first"])
    }

    func testAbsentFoldersHaveNoSkills() throws {
        let missing = bundled.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(AISkillLibrary(bundledDirectory: missing, userDirectory: missing).load(), AISkillSet())
        XCTAssertEqual(AISkillLibrary.empty.load(), AISkillSet())
    }

    func testEnsureUserDirectoryCreatesIt() throws {
        let folder = user.appendingPathComponent("Skills", isDirectory: true)
        XCTAssertEqual(try AISkillLibrary(bundledDirectory: nil, userDirectory: folder).ensureUserDirectory(), folder)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}

#endif
