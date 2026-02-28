// ApplyPatchTests.swift
// Test suite for the unified diff patcher and apply_patch tool
//
// Covers: diff parsing, hunk application, fuzzy matching, create mode,
// path sandboxing, approval tracking, remote command building, and
// edge cases (empty files, trailing newlines, AI-generated quirks).

import XCTest
@testable import ProSSHMac

// MARK: - Diff Parsing Tests

final class UnifiedDiffParserTests: XCTestCase {

    private let patcher = UnifiedDiffPatcher()

    func testParseSingleHunk() throws {
        let diff = """
        @@ -1,3 +1,3 @@
         line one
        -line two
        +line TWO
         line three
        """

        let hunks = try patcher.parse(diff: diff)

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].originalStart, 1)
        XCTAssertEqual(hunks[0].originalCount, 3)
        XCTAssertEqual(hunks[0].modifiedStart, 1)
        XCTAssertEqual(hunks[0].modifiedCount, 3)
        XCTAssertEqual(hunks[0].lines.count, 4)
    }

    func testParseMultipleHunks() throws {
        let diff = """
        @@ -1,3 +1,3 @@
         first
        -second
        +SECOND
         third
        @@ -10,3 +10,3 @@
         tenth
        -eleventh
        +ELEVENTH
         twelfth
        """

        let hunks = try patcher.parse(diff: diff)

        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].originalStart, 1)
        XCTAssertEqual(hunks[1].originalStart, 10)
    }

    func testParseWithFileHeaders() throws {
        let diff = """
        --- a/config.txt
        +++ b/config.txt
        @@ -1,2 +1,2 @@
        -old line
        +new line
         unchanged
        """

        let hunks = try patcher.parse(diff: diff)

        XCTAssertEqual(hunks.count, 1)
    }

    func testParseWithGitDiffHeaders() throws {
        let diff = """
        diff --git a/file.txt b/file.txt
        index abc1234..def5678 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -5,3 +5,4 @@
         context
        -removed
        +added line 1
        +added line 2
         context
        """

        let hunks = try patcher.parse(diff: diff)

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].originalCount, 3)
        XCTAssertEqual(hunks[0].modifiedCount, 4)
    }

    func testParseHunkHeaderWithoutCount() throws {
        // When count is 1, it can be omitted: @@ -1 +1 @@
        let diff = """
        @@ -1 +1 @@
        -old
        +new
        """

        let hunks = try patcher.parse(diff: diff)

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].originalCount, 1)
        XCTAssertEqual(hunks[0].modifiedCount, 1)
    }

    func testParsePureAddition() throws {
        let diff = """
        @@ -0,0 +1,3 @@
        +line one
        +line two
        +line three
        """

        let hunks = try patcher.parse(diff: diff)

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].originalCount, 0)
        XCTAssertEqual(hunks[0].lines.count, 3)
        XCTAssertTrue(hunks[0].lines.allSatisfy {
            if case .addition = $0 { return true }
            return false
        })
    }

    func testParsePureRemoval() throws {
        let diff = """
        @@ -1,2 +1,0 @@
        -delete me
        -delete me too
        """

        let hunks = try patcher.parse(diff: diff)

        XCTAssertEqual(hunks[0].lines.count, 2)
        XCTAssertTrue(hunks[0].lines.allSatisfy {
            if case .removal = $0 { return true }
            return false
        })
    }

    func testParseNoHunksThrows() {
        let notADiff = "This is just some text\nNot a diff at all"

        XCTAssertThrowsError(try patcher.parse(diff: notADiff)) { error in
            XCTAssertEqual(error as? DiffError, .noHunksFound)
        }
    }

    func testParseMalformedHeaderThrows() {
        let bad = "@@ this is not valid @@\n+foo"

        XCTAssertThrowsError(try patcher.parse(diff: bad)) { error in
            if case .malformedHunkHeader = error as? DiffError { } else {
                XCTFail("Expected malformedHunkHeader, got \(error)")
            }
        }
    }

    func testParseNoNewlineAtEndOfFile() throws {
        let diff = """
        @@ -1,2 +1,2 @@
         unchanged
        -old
        +new
        \\ No newline at end of file
        """

        let hunks = try patcher.parse(diff: diff)

        XCTAssertEqual(hunks.count, 1)
        // The "\ No newline" marker should be skipped.
        XCTAssertEqual(hunks[0].lines.count, 3)
    }
}

// MARK: - Diff Application Tests

final class UnifiedDiffApplyTests: XCTestCase {

    private let patcher = UnifiedDiffPatcher()

    func testSimpleReplacement() throws {
        let original = "line one\nline two\nline three\n"
        let diff = """
        @@ -1,3 +1,3 @@
         line one
        -line two
        +line TWO
         line three
        """

        let result = try patcher.apply(diff: diff, to: original)

        XCTAssertEqual(result, "line one\nline TWO\nline three\n")
    }

    func testAddLines() throws {
        let original = "first\nsecond\nthird\n"
        let diff = """
        @@ -1,3 +1,5 @@
         first
        +inserted A
        +inserted B
         second
         third
        """

        let result = try patcher.apply(diff: diff, to: original)

        XCTAssertEqual(result, "first\ninserted A\ninserted B\nsecond\nthird\n")
    }

    func testRemoveLines() throws {
        let original = "keep\nremove me\nalso remove\nkeep too\n"
        let diff = """
        @@ -1,4 +1,2 @@
         keep
        -remove me
        -also remove
         keep too
        """

        let result = try patcher.apply(diff: diff, to: original)

        XCTAssertEqual(result, "keep\nkeep too\n")
    }

    func testMultipleHunks() throws {
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let diff = """
        @@ -2,3 +2,3 @@
         line 2
        -line 3
        +LINE THREE
         line 4
        @@ -18,3 +18,3 @@
         line 18
        -line 19
        +LINE NINETEEN
         line 20
        """

        let result = try patcher.apply(diff: diff, to: original)

        XCTAssertTrue(result.contains("LINE THREE"))
        XCTAssertTrue(result.contains("LINE NINETEEN"))
        XCTAssertFalse(result.contains("line 3\n"))
        XCTAssertFalse(result.contains("line 19\n"))
    }

    func testContextMismatchThrows() {
        let original = "actual line one\nactual line two\n"
        let diff = """
        @@ -1,2 +1,2 @@
         wrong context
        -actual line two
        +new line two
        """

        XCTAssertThrowsError(try patcher.apply(diff: diff, to: original)) { error in
            if case .contextMismatch = error as? DiffError { } else {
                XCTFail("Expected contextMismatch, got \(error)")
            }
        }
    }

    func testTrailingWhitespaceTolerance() throws {
        // AI models often strip trailing whitespace from context lines.
        let original = "line one   \nline two\nline three  \n"
        let diff = """
        @@ -1,3 +1,3 @@
         line one
        -line two
        +line TWO
         line three
        """

        // Should succeed despite trailing whitespace differences.
        let result = try patcher.apply(diff: diff, to: original)

        XCTAssertTrue(result.contains("line TWO"))
    }

    func testFuzzyPositionMatching() throws {
        // Original has a blank line that shifts everything down by 1.
        let original = "header\n\nline one\nline two\nline three\n"
        let diff = """
        @@ -2,3 +2,3 @@
         line one
        -line two
        +line TWO
         line three
        """

        // Hunk says line 2, but actual content starts at line 3.
        // Fuzzy matching (fuzzLines=3) should find it.
        var fuzzyPatcher = UnifiedDiffPatcher()
        fuzzyPatcher.fuzzLines = 3
        let result = try fuzzyPatcher.apply(diff: diff, to: original)

        XCTAssertTrue(result.contains("line TWO"))
    }

    func testEmptyFileAddition() throws {
        let original = ""
        let diff = """
        @@ -0,0 +1,2 @@
        +new line one
        +new line two
        """

        let result = try patcher.apply(diff: diff, to: original)

        XCTAssertEqual(result, "new line one\nnew line two")
    }

    func testPreservesTrailingNewline() throws {
        let original = "line\n"
        let diff = """
        @@ -1 +1 @@
        -line
        +modified
        """

        let result = try patcher.apply(diff: diff, to: original)

        XCTAssertTrue(result.hasSuffix("\n"), "Should preserve original trailing newline")
    }

    func testNoTrailingNewlinePreserved() throws {
        let original = "line"  // No trailing newline
        let diff = """
        @@ -1 +1 @@
        -line
        +modified
        """

        let result = try patcher.apply(diff: diff, to: original)

        XCTAssertFalse(result.hasSuffix("\n"), "Should not add trailing newline if original didn't have one")
    }
}

// MARK: - Create Mode Tests

final class UnifiedDiffCreateTests: XCTestCase {

    private let patcher = UnifiedDiffPatcher()

    func testCreateFromPureAdditions() throws {
        let diff = """
        @@ -0,0 +1,3 @@
        +#!/bin/bash
        +echo "Hello"
        +exit 0
        """

        let result = try patcher.apply(diff: diff, to: "", mode: .create)

        XCTAssertEqual(result, "#!/bin/bash\necho \"Hello\"\nexit 0")
    }

    func testCreateIgnoresRemovals() throws {
        // In create mode, removal lines are skipped.
        let diff = """
        @@ -1,2 +1,1 @@
        -this shouldn't matter
        +only this line
        """

        let result = try patcher.apply(diff: diff, to: "", mode: .create)

        XCTAssertEqual(result, "only this line")
        XCTAssertFalse(result.contains("shouldn't"))
    }

    func testCreatePreservesContextLines() throws {
        let diff = """
        @@ -0,0 +1,3 @@
         context line (treated as content in create mode)
        +added line
         another context line
        """

        let result = try patcher.apply(diff: diff, to: "", mode: .create)

        XCTAssertTrue(result.contains("context line"))
        XCTAssertTrue(result.contains("added line"))
    }
}

// MARK: - Approval Tracker Tests

final class PatchApprovalTrackerTests: XCTestCase {

    @MainActor
    func testFingerprintDeterministic() {
        let tracker = PatchApprovalTracker()
        let op = PatchOperation(type: .update, path: "file.txt", diff: "+new line")

        let fp1 = tracker.fingerprint(operation: op)
        let fp2 = tracker.fingerprint(operation: op)

        XCTAssertEqual(fp1, fp2)
    }

    @MainActor
    func testDifferentOperationsProduceDifferentFingerprints() {
        let tracker = PatchApprovalTracker()
        let create = PatchOperation(type: .create, path: "file.txt", diff: "+content")
        let update = PatchOperation(type: .update, path: "file.txt", diff: "+content")

        XCTAssertNotEqual(
            tracker.fingerprint(operation: create),
            tracker.fingerprint(operation: update)
        )
    }

    @MainActor
    func testApprovalRemembered() {
        let tracker = PatchApprovalTracker()
        let op = PatchOperation(type: .update, path: "test.txt", diff: "-old\n+new")
        let fp = tracker.fingerprint(operation: op)

        XCTAssertFalse(tracker.isApproved(fp))

        tracker.remember(fp)

        XCTAssertTrue(tracker.isApproved(fp))
    }

    @MainActor
    func testResetClearsApprovals() {
        let tracker = PatchApprovalTracker()
        let op = PatchOperation(type: .delete, path: "file.txt", diff: nil)
        let fp = tracker.fingerprint(operation: op)

        tracker.remember(fp)
        XCTAssertTrue(tracker.isApproved(fp))

        tracker.reset()
        XCTAssertFalse(tracker.isApproved(fp))
    }
}

// MARK: - Local Workspace Patcher Tests

final class LocalWorkspacePatcherTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProSSHMac-patch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    func testCreateFile() throws {
        let patcher = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let op = PatchOperation(
            type: .create,
            path: "newfile.txt",
            diff: "Hello, World!\nSecond line."
        )

        let result = try patcher.apply(op)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Created"))

        let content = try String(contentsOf: tempDir.appendingPathComponent("newfile.txt"), encoding: .utf8)
        XCTAssertEqual(content, "Hello, World!\nSecond line.")
    }

    func testCreateFileWithDiff() throws {
        let patcher = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let op = PatchOperation(
            type: .create,
            path: "script.sh",
            diff: """
            @@ -0,0 +1,3 @@
            +#!/bin/bash
            +echo "test"
            +exit 0
            """
        )

        let result = try patcher.apply(op)

        XCTAssertTrue(result.success)

        let content = try String(contentsOf: tempDir.appendingPathComponent("script.sh"), encoding: .utf8)
        XCTAssertTrue(content.contains("#!/bin/bash"))
    }

    func testCreateFileWithNestedPath() throws {
        let patcher = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let op = PatchOperation(
            type: .create,
            path: "subdir/deep/file.txt",
            diff: "nested content"
        )

        let result = try patcher.apply(op)

        XCTAssertTrue(result.success)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("subdir/deep/file.txt").path
        ))
    }

    func testUpdateFile() throws {
        // Setup: create a file to update.
        let filePath = tempDir.appendingPathComponent("config.txt")
        try "line one\nline two\nline three\n".write(to: filePath, atomically: true, encoding: .utf8)

        let patcher = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let op = PatchOperation(
            type: .update,
            path: "config.txt",
            diff: """
            @@ -1,3 +1,3 @@
             line one
            -line two
            +line TWO
             line three
            """
        )

        let result = try patcher.apply(op)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Updated"))

        let content = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertTrue(content.contains("line TWO"))
        XCTAssertFalse(content.contains("line two"))
    }

    func testDeleteFile() throws {
        let filePath = tempDir.appendingPathComponent("deleteme.txt")
        try "goodbye".write(to: filePath, atomically: true, encoding: .utf8)

        let patcher = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let op = PatchOperation(type: .delete, path: "deleteme.txt", diff: nil)

        let result = try patcher.apply(op)

        XCTAssertTrue(result.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath.path))
    }

    func testDeleteNonexistentFileThrows() {
        let patcher = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let op = PatchOperation(type: .delete, path: "ghost.txt", diff: nil)

        XCTAssertThrowsError(try patcher.apply(op)) { error in
            if case .fileNotFound = error as? PatchToolError { } else {
                XCTFail("Expected fileNotFound, got \(error)")
            }
        }
    }

    func testPathEscapeRejected() {
        let patcher = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let op = PatchOperation(
            type: .create,
            path: "../../etc/passwd",
            diff: "hacked"
        )

        XCTAssertThrowsError(try patcher.apply(op)) { error in
            if case .outsideWorkspace = error as? PatchToolError { } else {
                XCTFail("Expected outsideWorkspace, got \(error)")
            }
        }
    }

    func testAbsolutePathOutsideWorkspaceRejected() {
        let patcher = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let op = PatchOperation(
            type: .create,
            path: "/tmp/outside.txt",
            diff: "escape attempt"
        )

        XCTAssertThrowsError(try patcher.apply(op)) { error in
            if case .outsideWorkspace = error as? PatchToolError { } else {
                XCTFail("Expected outsideWorkspace, got \(error)")
            }
        }
    }

    func testUpdateNonexistentFileThrows() {
        let patcher = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let op = PatchOperation(
            type: .update,
            path: "missing.txt",
            diff: "@@ -1 +1 @@\n-old\n+new"
        )

        XCTAssertThrowsError(try patcher.apply(op)) { error in
            if case .fileNotFound = error as? PatchToolError { } else {
                XCTFail("Expected fileNotFound, got \(error)")
            }
        }
    }

    func testUpdateWithoutHunkHeadersThrows() {
        let filePath = tempDir.appendingPathComponent("existing.txt")
        try? "content".write(to: filePath, atomically: true, encoding: .utf8)

        let patcher = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let op = PatchOperation(
            type: .update,
            path: "existing.txt",
            diff: "just raw text, no diff format"
        )

        // LocalWorkspacePatcher.updateFile calls applyDiff() directly and does not wrap
        // V4ADiffError in PatchToolError. The error for a non-diff string is V4ADiffError.invalidLine.
        XCTAssertThrowsError(try patcher.apply(op)) { error in
            if case .invalidLine = error as? V4ADiffError { } else {
                XCTFail("Expected V4ADiffError.invalidLine, got \(type(of: error)): \(error)")
            }
        }
    }
}

// MARK: - Remote Command Builder Tests

final class RemotePatchCommandBuilderTests: XCTestCase {

    func testCreateCommandContainsHeredoc() {
        let op = PatchOperation(type: .create, path: "/tmp/test.txt", diff: "hello\nworld")
        let command = RemotePatchCommandBuilder.buildCommand(for: op)

        XCTAssertTrue(command.contains("cat >"))
        XCTAssertTrue(command.contains("mkdir -p"))
        XCTAssertTrue(command.contains("hello"))
    }

    func testDeleteCommandUsesRm() {
        let op = PatchOperation(type: .delete, path: "/tmp/removeme.txt", diff: nil)
        let command = RemotePatchCommandBuilder.buildCommand(for: op)

        XCTAssertTrue(command.contains("rm"))
        XCTAssertTrue(command.contains("removeme.txt"))
    }

    func testParseSuccessResult() {
        let op = PatchOperation(type: .delete, path: "file.txt", diff: nil)
        // rm produces no output on success; parseResult should still return success
        let result = RemotePatchCommandBuilder.parseResult("", operation: op)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("file.txt"))
    }

    func testParseErrorResult() {
        let op = PatchOperation(type: .update, path: "file.txt", diff: nil)
        let output = "__PROSSH_PATCH_ERROR__: file not found: file.txt"

        let result = RemotePatchCommandBuilder.parseResult(output, operation: op)

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("file not found"))
    }

    func testRemoteUpdateUsesReadThenWrite() {
        // Architectural assertion: the remote update pattern is base64-read → applyDiff → base64-write.
        // buildUpdateCommand (patch(1)-based) is intentionally absent.
        let path = "/etc/app.conf"
        let readCmd = RemotePatchCommandBuilder.buildReadCommand(path: path)
        let writeCmd = RemotePatchCommandBuilder.buildWriteCommand(path: path, content: "value=1\n")
        XCTAssertTrue(readCmd.contains("base64"), "Read uses base64 encoding")
        XCTAssertTrue(writeCmd.contains("base64"), "Write uses base64 encoding")
        XCTAssertFalse(readCmd.contains("patch"), "Remote update does not use patch(1)")
        XCTAssertFalse(writeCmd.contains("patch"), "Remote update does not use patch(1)")
    }

    func testReadCommandUsesBase64() {
        let command = RemotePatchCommandBuilder.buildReadCommand(path: "/etc/nginx.conf")
        XCTAssertTrue(command.contains("base64"), "Read command should use base64")
        XCTAssertTrue(command.contains("nginx.conf"))
    }

    func testReadCommandWithSudoNUsesNonInteractiveSudo() {
        let command = RemotePatchCommandBuilder.buildReadCommand(
            path: "/etc/nginx.conf",
            useSudo: true,
            nonInteractiveSudo: true
        )
        XCTAssertTrue(command.contains("sudo -n base64"))
    }

    func testWriteCommandWithSudoUsesTeeAndSudoMkdir() {
        let command = RemotePatchCommandBuilder.buildWriteCommand(
            path: "/etc/nginx.conf",
            content: "worker_processes auto;\n",
            useSudo: true
        )
        XCTAssertTrue(command.contains("sudo mkdir -p"))
        XCTAssertTrue(command.contains("sudo tee '/etc/nginx.conf' > /dev/null"))
    }

    func testDeleteCommandWithSudoUsesSudoRm() {
        let command = RemotePatchCommandBuilder.buildDeleteCommand(
            path: "/etc/nginx.conf",
            useSudo: true
        )
        XCTAssertTrue(command.contains("sudo rm"))
    }

    func testSudoPrimingCommandIsSudoV() {
        XCTAssertEqual(RemotePatchCommandBuilder.buildSudoPrimingCommand(), "sudo -v")
    }

    func testReadCommandEscapesSpaces() {
        let command = RemotePatchCommandBuilder.buildReadCommand(path: "/etc/my config/file.conf")
        // shellEscaped wraps in single quotes so spaces inside the path are safe
        XCTAssertTrue(command.contains("'"), "Path with spaces should be single-quoted")
        XCTAssertTrue(command.contains("my config"))
    }

    func testDecodeBase64OutputClean() throws {
        let original = "line one\nline two\nline three\n"
        let b64 = Data(original.utf8).base64EncodedString()
        let decoded = RemotePatchCommandBuilder.decodeBase64FileOutput(b64)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeBase64OutputWithPromptPrefix() {
        let original = "server {\n    listen 80;\n}\n"
        let b64 = Data(original.utf8).base64EncodedString()
        // Simulate terminal output: prompt line + echoed command + base64 content
        let contaminated = "user@host:~$ base64 /etc/nginx.conf\n" + b64
        let decoded = RemotePatchCommandBuilder.decodeBase64FileOutput(contaminated)
        XCTAssertEqual(decoded, original,
            "Prompt prefix should be filtered out; content should decode correctly")
    }

    func testDecodeBase64OutputWithPromptSuffix() {
        let original = "alpha\nbeta\ngamma\n"
        let b64 = Data(original.utf8).base64EncodedString()
        // Simulate exit-code marker appended after base64 output
        let contaminated = b64 + "\nuser@host:~$ "
        let decoded = RemotePatchCommandBuilder.decodeBase64FileOutput(contaminated)
        XCTAssertEqual(decoded, original,
            "Prompt suffix should be filtered out; content should decode correctly")
    }

    func testDecodeBase64OutputPreservesTrailingNewline() {
        let original = "key=value\n"   // ends with newline, as most Unix text files do
        let b64 = Data(original.utf8).base64EncodedString()
        let decoded = RemotePatchCommandBuilder.decodeBase64FileOutput(b64)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded?.hasSuffix("\n") == true,
            "Trailing newline must survive the base64 round-trip")
    }

    func testDecodeBase64OutputReturnsNilForEmptyOutput() {
        XCTAssertNil(RemotePatchCommandBuilder.decodeBase64FileOutput(""))
    }

    func testDecodeBase64OutputReturnsNilForNonBase64() {
        // Plain text with spaces and punctuation — no valid base64 lines after filter
        let plainText = "not base64 at all! just a shell error message"
        XCTAssertNil(RemotePatchCommandBuilder.decodeBase64FileOutput(plainText))
    }

    func testBase64ReadLineExtraction() {
        // Simulates the base64 read → decode → line slicing that readRemoteFileChunk now uses.
        let original = "line one\nline two\nline three\nline four\nline five\n"
        let b64 = Data(original.utf8).base64EncodedString()
        let contaminated = "user@host:~$ base64 'file.txt'\n" + b64 + "\nuser@host:~$ "

        guard let decoded = RemotePatchCommandBuilder.decodeBase64FileOutput(contaminated) else {
            XCTFail("Base64 decode should succeed"); return
        }
        XCTAssertEqual(decoded, original)

        // Extract lines 2–3 (1-based startLine=2, lineCount=2)
        let allLines = decoded.components(separatedBy: "\n")
        let zeroStart = max(0, 2 - 1)
        let zeroEnd = min(allLines.count, zeroStart + 2)
        let sliced = Array(allLines[zeroStart..<zeroEnd])
        XCTAssertEqual(sliced, ["line two", "line three"])
    }
}

// MARK: - Round-Trip Integration Tests

final class PatchRoundTripTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProSSHMac-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    /// Full workflow: create file → update file → verify content → delete file.
    func testFullLifecycle() throws {
        let workspace = LocalWorkspacePatcher(workspaceRoot: tempDir)

        // Step 1: Create — V4A create mode: each line prefixed with "+"
        let createOp = PatchOperation(
            type: .create,
            path: "lifecycle.txt",
            diff: """
            +# Configuration
            +setting_a = true
            +setting_b = false
            +setting_c = 42
            """
        )
        let createResult = try workspace.apply(createOp)
        XCTAssertTrue(createResult.success)

        // Step 2: Update — V4A update mode: @@ <anchor> then -/+ lines
        let updateOp = PatchOperation(
            type: .update,
            path: "lifecycle.txt",
            diff: """
            @@ setting_a = true
            -setting_b = false
            +setting_b = true
            """
        )
        let updateResult = try workspace.apply(updateOp)
        XCTAssertTrue(updateResult.success)

        // Verify content.
        let content = try String(
            contentsOf: tempDir.appendingPathComponent("lifecycle.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(content.contains("setting_b = true"))
        XCTAssertFalse(content.contains("setting_b = false"))

        // Step 3: Delete
        let deleteOp = PatchOperation(type: .delete, path: "lifecycle.txt", diff: nil)
        let deleteResult = try workspace.apply(deleteOp)
        XCTAssertTrue(deleteResult.success)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("lifecycle.txt").path
        ))
    }

    /// Simulates what an AI agent would actually produce: reading a file,
    /// generating a diff, and applying it.
    func testAIWorkflow() throws {
        let workspace = LocalWorkspacePatcher(workspaceRoot: tempDir)
        let patcher = UnifiedDiffPatcher()

        // Create initial file.
        let initialContent = """
        server {
            listen 80;
            server_name example.com;

            location / {
                proxy_pass http://localhost:3000;
            }
        }
        """
        let filePath = tempDir.appendingPathComponent("nginx.conf")
        try initialContent.write(to: filePath, atomically: true, encoding: .utf8)

        // AI generates a diff to add HTTPS redirect.
        let aiDiff = """
        @@ -1,4 +1,6 @@
         server {
        -    listen 80;
        +    listen 443 ssl;
        +    ssl_certificate /etc/ssl/cert.pem;
        +    ssl_certificate_key /etc/ssl/key.pem;
             server_name example.com;
        """

        // Verify the diff parses.
        let hunks = try patcher.parse(diff: aiDiff)
        XCTAssertEqual(hunks.count, 1)

        // Apply via workspace patcher.
        let updateOp = PatchOperation(type: .update, path: "nginx.conf", diff: aiDiff)
        let result = try workspace.apply(updateOp)

        XCTAssertTrue(result.success)

        let updated = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertTrue(updated.contains("listen 443 ssl"))
        XCTAssertTrue(updated.contains("ssl_certificate"))
        XCTAssertFalse(updated.contains("listen 80"))
        // Untouched parts should still be there.
        XCTAssertTrue(updated.contains("proxy_pass"))
    }
}
