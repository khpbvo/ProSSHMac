#if canImport(XCTest)
import XCTest

final class TerminalFileBrowserTreeTests: XCTestCase {

    func testNormalizeRemotePathCollapsesDotAndDuplicateSeparators() {
        let normalized = TerminalFileBrowserTree.normalizePath("//var///log/./nginx/", isLocal: false)
        XCTAssertEqual(normalized, "/var/log/nginx")
    }

    func testNormalizeLocalPathUsesProvidedHomeForEmptyInput() {
        let normalized = TerminalFileBrowserTree.normalizePath(
            "   ",
            isLocal: true,
            homeDirectoryPath: "/Users/tester"
        )
        XCTAssertEqual(normalized, "/Users/tester")
    }

    func testParentPathForRemoteRootAndNestedPath() {
        XCTAssertNil(TerminalFileBrowserTree.parentPath(of: "/", isLocal: false))
        XCTAssertEqual(TerminalFileBrowserTree.parentPath(of: "/var/log", isLocal: false), "/var")
        XCTAssertEqual(TerminalFileBrowserTree.parentPath(of: "/var", isLocal: false), "/")
    }

    func testCollapseExpandedPathsRemovesCollapsedNodeAndDescendants() {
        let expanded: Set<String> = ["/", "/home", "/home/user", "/home/user/docs", "/var"]
        let collapsed = TerminalFileBrowserTree.collapseExpandedPaths(expanded, collapsing: "/home")
        XCTAssertEqual(collapsed, ["/", "/var"])
    }

    func testRebuildRowsIncludesOnlyExpandedChildren() {
        let folder = TerminalFileBrowserEntry(path: "/root/folder", name: "folder", isDirectory: true, size: 0)
        let file = TerminalFileBrowserEntry(path: "/root/file.txt", name: "file.txt", isDirectory: false, size: 12)
        let nested = TerminalFileBrowserEntry(path: "/root/folder/nested.txt", name: "nested.txt", isDirectory: false, size: 4)
        let childrenByPath: [String: [TerminalFileBrowserEntry]] = [
            "/root": [folder, file],
            "/root/folder": [nested]
        ]

        let collapsedRows = TerminalFileBrowserTree.rebuildRows(
            rootPath: "/root",
            childrenByPath: childrenByPath,
            expandedPaths: []
        )
        XCTAssertEqual(collapsedRows.map(\.entry.path), ["/root/folder", "/root/file.txt"])
        XCTAssertEqual(collapsedRows.map(\.depth), [0, 0])

        let expandedRows = TerminalFileBrowserTree.rebuildRows(
            rootPath: "/root",
            childrenByPath: childrenByPath,
            expandedPaths: ["/root/folder"]
        )
        XCTAssertEqual(
            expandedRows.map(\.entry.path),
            ["/root/folder", "/root/folder/nested.txt", "/root/file.txt"]
        )
        XCTAssertEqual(expandedRows.map(\.depth), [0, 1, 0])
    }

    func testContainsPathChecksRowsAndCachedChildren() {
        let folder = TerminalFileBrowserEntry(path: "/root/folder", name: "folder", isDirectory: true, size: 0)
        let nested = TerminalFileBrowserEntry(path: "/root/folder/nested.txt", name: "nested.txt", isDirectory: false, size: 4)
        let childrenByPath: [String: [TerminalFileBrowserEntry]] = [
            "/root": [folder],
            "/root/folder": [nested]
        ]
        let rows = TerminalFileBrowserTree.rebuildRows(
            rootPath: "/root",
            childrenByPath: childrenByPath,
            expandedPaths: []
        )

        XCTAssertTrue(TerminalFileBrowserTree.containsPath("/root/folder", rows: rows, childrenByPath: childrenByPath))
        XCTAssertTrue(TerminalFileBrowserTree.containsPath("/root/folder/nested.txt", rows: rows, childrenByPath: childrenByPath))
        XCTAssertFalse(TerminalFileBrowserTree.containsPath("/root/missing.txt", rows: rows, childrenByPath: childrenByPath))
    }

    func testListLocalEntriesSortsDirectoriesBeforeFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root.appendingPathComponent("Zoo"), withIntermediateDirectories: false)
        try fileManager.createDirectory(at: root.appendingPathComponent("beta"), withIntermediateDirectories: false)
        _ = fileManager.createFile(atPath: root.appendingPathComponent("alpha.txt").path, contents: Data("a".utf8))
        _ = fileManager.createFile(atPath: root.appendingPathComponent("Gamma.txt").path, contents: Data("g".utf8))

        let entries = try TerminalFileBrowserTree.listLocalEntries(path: root.path, fileManager: fileManager)
        XCTAssertEqual(entries.map(\.name), ["beta", "Zoo", "alpha.txt", "Gamma.txt"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, true, false, false])
    }

    func testListLocalEntriesThrowsForMissingDirectory() {
        XCTAssertThrowsError(try TerminalFileBrowserTree.listLocalEntries(path: "/tmp/does-not-exist-\(UUID().uuidString)"))
    }
}
#endif
