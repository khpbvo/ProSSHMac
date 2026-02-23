// QuickCommandsTests.swift
// ProSSHV2
//
// E.5 — quick command model, substitution, host scoping, and JSON library IO.

#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

    final class QuickCommandsTests: XCTestCase {

    @MainActor
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

        let variableNames = snippet.variables.map { $0.name }
        XCTAssertEqual(variableNames, ["count", "path"])

        let resolved = quickCommands.resolvedCommand(for: snippet, values: ["count": "50"])
        XCTAssertEqual(resolved, "tail -n 50 /var/log/system.log")
    }

    @MainActor
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
        let firstForHostBName = forHostB.first?.name
        XCTAssertEqual(forHostB.count, 1)
        XCTAssertEqual(firstForHostBName, "Global")
    }

    @MainActor
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
        let isTargetEmpty = target.snippets.isEmpty
        XCTAssertTrue(isTargetEmpty)

        try target.importLibrary(from: exportedURL, strategy: .replace)

        let importedSnippets = target.snippets
        let importedFirstName = importedSnippets.first?.name
        XCTAssertEqual(importedSnippets.count, 1)
        XCTAssertEqual(importedFirstName, "Disk")
    }

    @MainActor
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

        let mergedSnippets = manager.snippets
        let mergedFirstName = mergedSnippets.first?.name
        let mergedFirstCommand = mergedSnippets.first?.command
        XCTAssertEqual(mergedSnippets.count, 1)
        XCTAssertEqual(mergedFirstName, "New")
        XCTAssertEqual(mergedFirstCommand, "echo new")
    }

    @MainActor
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
