// ApplyDiffTests.swift
// Direct unit tests for applyDiff() — the V4A diff parser in apply_diff.swift
import XCTest
@testable import ProSSHMac

// MARK: - Create Mode Tests

final class ApplyDiffCreateTests: XCTestCase {

    func testCreateBasicPlusLines() throws {
        let result = try applyDiff(input: "", diff: "+line1\n+line2", mode: .create)
        XCTAssertEqual(result, "line1\nline2")
    }

    func testCreateEmptyDiffReturnsEmpty() throws {
        let result = try applyDiff(input: "", diff: "", mode: .create)
        XCTAssertEqual(result, "")
    }

    func testCreateMissingPlusThrows() {
        XCTAssertThrowsError(try applyDiff(input: "", diff: "just text", mode: .create)) { error in
            if case .invalidAddFileLine = error as? V4ADiffError { } else {
                XCTFail("Expected V4ADiffError.invalidAddFileLine, got \(type(of: error)): \(error)")
            }
        }
    }
}

// MARK: - Update Mode Tests

final class ApplyDiffUpdateTests: XCTestCase {

    func testUpdateWithAnchor() throws {
        let input = "def foo():\n    return old_val\n"
        let diff = "@@ def foo():\n-    return old_val\n+    return new_val"
        let result = try applyDiff(input: input, diff: diff)
        XCTAssertEqual(result, "def foo():\n    return new_val\n")
    }

    func testUpdateBareAnchor() throws {
        // Bare "@@" applies change at cursor=0 (start of file)
        let input = "alpha\nbeta\ngamma\n"
        let diff = "@@\n-alpha\n+ALPHA"
        let result = try applyDiff(input: input, diff: diff)
        XCTAssertEqual(result, "ALPHA\nbeta\ngamma\n")
    }

    func testUpdateAnchorNotFound() {
        let input = "line1\nline2\nline3\n"
        // Both the anchor AND the context line are absent from the file,
        // ensuring findContext returns -1 and throws invalidContext.
        let diff = "@@ nonexistent_anchor_xyz\n-also_nonexistent_line\n+REPLACEMENT"
        XCTAssertThrowsError(try applyDiff(input: input, diff: diff)) { error in
            if case .invalidContext = error as? V4ADiffError { } else {
                XCTFail("Expected V4ADiffError.invalidContext, got \(type(of: error)): \(error)")
            }
        }
    }

    func testUpdateMultipleAnchors() throws {
        let input = "alpha\nbeta\ngamma\ndelta\n"
        let diff = "@@ alpha\n-beta\n+BETA\n@@ gamma\n-delta\n+DELTA"
        let result = try applyDiff(input: input, diff: diff)
        XCTAssertEqual(result, "alpha\nBETA\ngamma\nDELTA\n")
    }

    func testUpdatePreservesTrailingNewline() throws {
        let input = "alpha\nbeta\n"
        let diff = "@@ alpha\n-beta\n+BETA"
        let result = try applyDiff(input: input, diff: diff)
        XCTAssertTrue(result.hasSuffix("\n"), "Patched output should preserve trailing newline")
        XCTAssertEqual(result, "alpha\nBETA\n")
    }

    func testUpdateNoTrailingNewlinePreserved() throws {
        let input = "alpha\nbeta"
        let diff = "@@ alpha\n-beta\n+BETA"
        let result = try applyDiff(input: input, diff: diff)
        XCTAssertFalse(result.hasSuffix("\n"), "Should not add trailing newline if original didn't have one")
        XCTAssertEqual(result, "alpha\nBETA")
    }

    func testUpdateAnchorFuzzyStrippedMatch() throws {
        // Anchor line has trailing whitespace in the file; stripped match finds it
        let input = "def foo():   \n    return old_val\n"
        let diff = "@@ def foo():\n-    return old_val\n+    return new_val"
        let result = try applyDiff(input: input, diff: diff)
        XCTAssertEqual(result, "def foo():   \n    return new_val\n")
    }
}

// MARK: - Contamination Regression Tests (Phase 3 fix)
//
// Phase 3 replaced the sed-based read with base64 read + decodeBase64FileOutput.
// These tests verify that the fix works end-to-end: contaminated terminal output
// (prompt prefix + echoed command + base64 content + prompt suffix) is correctly
// decoded to the original file content before applyDiff is called.

final class ApplyDiffContaminationTests: XCTestCase {

    func testUpdateSucceedsWithBase64ReadSimulation() throws {
        // Regression: base64 read + decodeBase64FileOutput eliminates shell-prompt
        // contamination before applyDiff sees the content.
        let trueContent = "alpha\nbeta\ngamma\n"
        let b64 = Data(trueContent.utf8).base64EncodedString()
        // Simulate contaminated terminal output: prompt + echoed command + base64 + trailing prompt
        let contaminated = "user@host:~$ base64 /tmp/file\n" + b64 + "\nuser@host:~$ "
        let diff = "@@ alpha\n-beta\n+BETA"

        let decoded = RemotePatchCommandBuilder.decodeBase64FileOutput(contaminated)
        XCTAssertEqual(decoded, trueContent,
            "decodeBase64FileOutput should strip prompt lines and recover original file content")

        let result = try applyDiff(input: decoded!, diff: diff)
        XCTAssertEqual(result, "alpha\nBETA\ngamma\n",
            "Patch should apply correctly after contamination-safe read")
        XCTAssertFalse(result.hasPrefix("user@host"),
            "Result must not contain shell prompt prefix")
    }
}
