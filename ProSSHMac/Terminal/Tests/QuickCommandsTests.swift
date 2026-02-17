// QuickCommandsTests.swift
// ProSSHV2
//
// E.5 — quick command model, substitution, host scoping, and JSON library IO.

#if canImport(XCTest)
import XCTest

@MainActor
final class QuickCommandsTests: XCTestCase {

    func testSaveSnippetCapturesTemplateVariablesAndDefaultValues() throws {
        let quickCommands = makeManager(suffix: "save")

        let snippet = try quickCommands.saveSnippet(
            name: "Tail Logs",
            command: "tail -n {{count}} {{path}}",
            variableDefaults: [
                "count": "200",
                "path": "/var/log/system.log"
            ],
            hostID: nil,
            hostLabel: nil
        )

        XCTAssertEqual(snippet.variables.map(\.name), ["count", "path"])

        let resolved = quickCommands.resolvedCommand(for: snippet, values: ["count": "50"])
        XCTAssertEqual(resolved, "tail -n 50 /var/log/system.log")
    }

    func testSnippetsAreFilteredByHostScope() throws {
        let quickCommands = makeManager(suffix: "scope")
        let hostA = UUID()
        let hostB = UUID()

        _ = try quickCommands.saveSnippet(
            name: "Global",
            command: "uptime",
            variableDefaults: [:],
            hostID: nil,
            hostLabel: nil
        )
        _ = try quickCommands.saveSnippet(
            name: "Host A",
            command: "show interfaces",
            variableDefaults: [:],
            hostID: hostA,
            hostLabel: "Core Router"
        )

        let forHostA = quickCommands.snippets(for: hostA)
        XCTAssertEqual(forHostA.count, 2)

        let forHostB = quickCommands.snippets(for: hostB)
        XCTAssertEqual(forHostB.count, 1)
        XCTAssertEqual(forHostB.first?.name, "Global")
    }

    func testExportAndImportLibraryRoundTrip() throws {
        let source = makeManager(suffix: "export")
        _ = try source.saveSnippet(
            name: "Disk",
            command: "df -h",
            variableDefaults: [:],
            hostID: nil,
            hostLabel: nil
        )

        let directory = makeTempDirectory(suffix: "export")
        let exportedURL = try source.exportLibrary(destinationDirectory: directory)

        let target = makeManager(suffix: "import")
        XCTAssertTrue(target.snippets.isEmpty)

        try target.importLibrary(from: exportedURL, strategy: .replace)

        XCTAssertEqual(target.snippets.count, 1)
        XCTAssertEqual(target.snippets.first?.name, "Disk")
    }

    func testImportMergeOverwritesByID() throws {
        let manager = makeManager(suffix: "merge")
        let sharedID = UUID()

        _ = try manager.saveSnippet(
            id: sharedID,
            name: "Old",
            command: "echo old",
            variableDefaults: [:],
            hostID: nil,
            hostLabel: nil
        )

        let external = makeManager(suffix: "mergeExternal")
        _ = try external.saveSnippet(
            id: sharedID,
            name: "New",
            command: "echo new",
            variableDefaults: [:],
            hostID: nil,
            hostLabel: nil
        )

        let directory = makeTempDirectory(suffix: "merge")
        let exportURL = try external.exportLibrary(destinationDirectory: directory)

        try manager.importLibrary(from: exportURL, strategy: .merge)

        XCTAssertEqual(manager.snippets.count, 1)
        XCTAssertEqual(manager.snippets.first?.name, "New")
        XCTAssertEqual(manager.snippets.first?.command, "echo new")
    }

    private func makeManager(suffix: String) -> QuickCommands {
        QuickCommands(defaults: makeDefaults(suffix: suffix), keyPrefix: "QuickCommandsTests.\(suffix)")
    }

    private func makeDefaults(suffix: String) -> UserDefaults {
        let suite = "QuickCommandsTests.\(suffix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeTempDirectory(suffix: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickCommandsTests.\(suffix).\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
