# Remote Patching Fix

**GitHub Issue:** #10 — AI agent remote patching produces broken patches when editing existing files

**Branch:** `fix/remote-patching`

---

## Root Cause Analysis

Three distinct bugs cause remote `apply_patch update` operations to fail. Create and delete
operations are unaffected.

### Bug 1 (Primary) — `originalContent` contaminated with shell prompt and command echo

The remote update path in `AIToolHandler.swift` reads the file content via:

```swift
let readCmd = Self.buildRemoteReadFileChunkCommand(path: path, startLine: 1, endLine: 50_000)
let readResult = await provider.executeCommandAndWait(sessionID: sessionID, command: readCmd, timeoutSeconds: 10)
let originalContent = readResult.output
```

`executeCommandAndWait` wraps the command in a shell block and polls `shellBuffers`
(the terminal screen buffer) for the completion marker. `parseWrappedCommandOutput` extracts
everything **before** the marker — which is the entire terminal screen up to that point:

```
user@host:~$ { sed -n '1,50000p' '/etc/nginx.conf'; __ps=$?; printf '\n\033[8m__PSW_TOKEN__%s\033[0m\n' "$__ps"; }
server {
    listen 80;
    ...
}
```

`originalContent` contains the shell prompt line + echoed command + file content instead of
just the file content. The V4A parser then tries to match context lines from the diff against
this contaminated string. Since the first line of `originalContent` is the prompt rather than
the file's first line, context matching fails with `invalidContext` errors — or silently
produces garbage output if an anchor search happens to find a false match.

### Bug 2 (Secondary) — Trailing newline stripped by `trimmingCharacters`

`parseWrappedCommandOutput` applies `.trimmingCharacters(in: .whitespacesAndNewlines)` to the
extracted output. This strips the trailing `\n` from file content. Almost all Unix text files
end with `\n`. When `applyDiff` processes content without a trailing newline, the patched
output also lacks one, silently corrupting every remote file that gets patched.

### Bug 3 (Tertiary) — Dead code `buildUpdateCommand` still uses `patch(1)`

`RemotePatchCommandBuilder.buildUpdateCommand` pipes V4A diffs to `patch(1)`, which was
the original broken approach documented in the 2026-02-26 featurelist fix. This method is
never called in the live code path (the actual path is read-apply-write in `AIToolHandler`),
but it still exists and its test `testUpdateCommandUsesPatch` asserts that `patch` appears in
the command — actively misleading anyone reading the tests about how remote update works.

---

## Fix Strategy: Base64 Read

Replace `buildRemoteReadFileChunkCommand` (sed-based) with a base64 read for the patch
update path. `base64 <path>` outputs pure base64 characters (`[A-Za-z0-9+/=]`). Filtering
the contaminated terminal output to keep only valid base64 lines and decoding them produces
exact file bytes — immune to prompt/echo contamination and free of trailing-newline trimming.

This is symmetric with `buildWriteCommand`, which already uses base64 encoding for writes.

---

## Files That Will Change

| File | Change |
|------|--------|
| `ProSSHMac/Services/AI/ApplyPatchTool.swift` | Add `buildReadCommand(path:)` and `decodeBase64FileOutput(_:)` static methods; remove dead `buildUpdateCommand`; simplify `parseResult` |
| `ProSSHMac/Services/AI/AIToolHandler.swift` | Replace `buildRemoteReadFileChunkCommand` + raw output with `buildReadCommand` + `decodeBase64FileOutput` in the remote update branch |
| `ProSSHMac/Services/AI/ApplyPatchTool.swift.bak` | Delete — stale backup file |
| `ProSSHMacTests/Terminal/Tests/ApplyPatchTests.swift` | Fix `testUpdateCommandUsesPatch` (dead code test); fix `testUpdateWithoutHunkHeadersThrows` (wrong error type); add `buildReadCommand`/`decodeBase64FileOutput` tests |
| `ProSSHMacTests/Terminal/Tests/ApplyDiffTests.swift` | **New file** — direct unit tests for `applyDiff()` (V4A parser) |
| `CLAUDE.md` | Update remote update flow description under AI agent tools |
| `docs/featurelist.md` | Dated loop-log entries per phase |

---

## Phase 1 — Add Failing Tests to Document the Bugs

Goal: write tests that fail with current code, proving the bugs are real before touching
anything. Every test added here should be runnable and show a specific failure.

- [ ] 1. Create `ProSSHMacTests/Terminal/Tests/ApplyDiffTests.swift`

- [ ] 1a. Add `final class ApplyDiffCreateTests: XCTestCase` with:
  - `testCreateBasicPlusLines` — `applyDiff(input: "", diff: "+line1\n+line2", mode: .create)` → `"line1\nline2"`
  - `testCreateMissingPlusThrows` — a non-`+` line in create diff throws `V4ADiffError.invalidAddFileLine`
  - `testCreateEmptyDiffThrows` — empty diff string throws (no sections)

- [ ] 1b. Add `final class ApplyDiffUpdateTests: XCTestCase` with V4A `@@ <anchor>` format:
  - `testUpdateWithAnchor` — `@@ def foo():` anchor locates the hunk in a Python-like file
  - `testUpdateBareAnchor` — bare `@@\n-old\n+new` applies at cursor=0 (start of file)
  - `testUpdateAnchorNotFound` — anchor string absent from file throws `V4ADiffError.invalidContext`
  - `testUpdateMultipleAnchors` — two `@@ anchor` blocks in one diff both apply correctly
  - `testUpdatePreservesTrailingNewline` — file ending `\n` still ends `\n` after patch
  - `testUpdateNoTrailingNewlinePreserved` — file without trailing `\n` stays without after patch
  - `testUpdateAnchorFuzzyStrippedMatch` — anchor with trailing whitespace difference matches with fuzz

- [ ] 1c. Add `final class ApplyDiffContaminationTests: XCTestCase`:
  - `testUpdateFailsWithPromptPrefix` — prepend `"user@host:~$ sed -n '1,50000p' /etc/file\n"` to
    `originalContent` before calling `applyDiff`; verify the diff that matches the true content
    fails (this test documents Bug 1 and is removed in Phase 3 when the fix lands)

- [ ] 2. In `ApplyPatchTests.swift`, fix `testUpdateWithoutHunkHeadersThrows`:
  - Currently expects `PatchToolError.invalidDiff` but `applyDiff` throws `V4ADiffError`
  - Change the assertion to `XCTAssertThrowsError` without checking the specific type, or
    change to check for `V4ADiffError` — add a comment explaining `LocalWorkspacePatcher`
    does not wrap V4A errors in `PatchToolError`

- [ ] 3. Run new tests to confirm Phase 1 state:
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test \
    -only-testing:ProSSHMacTests/ApplyDiffTests
  ```
  - Contamination test (`testUpdateFailsWithPromptPrefix`) must FAIL
  - All other new tests must PASS

- [ ] 4. Update CLAUDE.md (no architectural changes in this phase; update only if conventions changed)
- [ ] 5. Update `docs/featurelist.md` with dated Phase 1 loop-log entry

---

## Phase 2 — Add `buildReadCommand` and `decodeBase64FileOutput` to `RemotePatchCommandBuilder`

Goal: add the two methods that replace sed-based reads with base64-safe reads. No production
code changes yet — only `ApplyPatchTool.swift` and tests.

- [ ] 1. In `ProSSHMac/Services/AI/ApplyPatchTool.swift`, add after `buildWriteCommand`:

  ```swift
  /// Build a shell command to read a remote file using base64 encoding.
  ///
  /// Base64 output consists only of [A-Za-z0-9+/=] characters, making it immune
  /// to shell prompt / command-echo contamination when the output is captured via
  /// the terminal screen buffer. Use decodeBase64FileOutput(_:) to extract and
  /// decode the content from the (possibly contaminated) command output.
  static func buildReadCommand(path: String) -> String {
      let escapedPath = shellEscaped(path)
      return "base64 \(escapedPath)"
  }
  ```

- [ ] 1a. The method must use the existing `shellEscaped(_:)` helper for path quoting
- [ ] 1b. Add a comment that this is the read-side pair of `buildWriteCommand`

- [ ] 2. Add `decodeBase64FileOutput(_:) -> String?` to `RemotePatchCommandBuilder`:

  ```swift
  /// Extract and decode base64-encoded file content from contaminated command output.
  ///
  /// Filters rawOutput to keep only lines that consist entirely of valid base64
  /// characters, joins them, base64-decodes the result, and returns the UTF-8 string.
  /// Returns nil if decoding fails (e.g., no valid base64 lines found, or binary file).
  static func decodeBase64FileOutput(_ rawOutput: String) -> String? {
      let b64Lines = rawOutput.components(separatedBy: "\n").filter { line in
          !line.isEmpty && line.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
      }
      let joined = b64Lines.joined()
      guard !joined.isEmpty,
            let data = Data(base64Encoded: joined, options: .ignoreUnknownCharacters),
            let content = String(data: data, encoding: .utf8) else {
          return nil
      }
      return content
  }
  ```

- [ ] 2a. The filter must keep only lines where every character is in `[A-Za-z0-9+/=]`
- [ ] 2b. Use `Data.base64Encoded.ignoreUnknownCharacters` to tolerate line-length padding
- [ ] 2c. Return `nil` for binary files (non-UTF-8 decode) so callers can surface a clear error

- [ ] 3. Add unit tests in `ApplyPatchTests.swift` inside `RemotePatchCommandBuilderTests`:
  - `testReadCommandUsesBase64` — verify `buildReadCommand(path: "/etc/nginx.conf")` contains `"base64"`
  - `testReadCommandEscapesSpaces` — path with spaces is single-quoted
  - `testDecodeBase64OutputClean` — encode known content, pass the pure base64 string, verify decoded output matches
  - `testDecodeBase64OutputWithPromptPrefix` — prepend `"user@host:~$ base64 /etc/file\n"` before
    the base64 content; verify decoded output still matches the original content
  - `testDecodeBase64OutputWithPromptSuffix` — append `"\nuser@host:~$ "` after base64 content; same
  - `testDecodeBase64OutputPreservesTrailingNewline` — content ending `\n` round-trips intact
  - `testDecodeBase64OutputReturnsNilForEmptyOutput` — empty string returns nil
  - `testDecodeBase64OutputReturnsNilForNonBase64` — plain text with no base64 content returns nil

- [ ] 4. Run new `RemotePatchCommandBuilderTests`:
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test \
    -only-testing:ProSSHMacTests/RemotePatchCommandBuilderTests
  ```
  All must pass.

- [ ] 5. Update CLAUDE.md if any architectural notes change (no changes expected in this phase)
- [ ] 6. Update `docs/featurelist.md` with dated Phase 2 loop-log entry

---

## Phase 3 — Fix the Remote Update Path in `AIToolHandler.swift`

Goal: wire the new read helpers into the live code path. This is the single-line fix that
resolves Bugs 1 and 2 in production.

- [ ] 1. In `ProSSHMac/Services/AI/AIToolHandler.swift`, locate the remote update branch
  (currently around line 475):
  ```swift
  if operation.type == .update, let diff = operation.diff {
      // Remote update: read the file → apply V4A diff in Swift → write back.
  ```

- [ ] 2. Replace the read command and content extraction:

  **Before:**
  ```swift
  let readCmd = Self.buildRemoteReadFileChunkCommand(
      path: path, startLine: 1, endLine: 50_000
  )
  let readResult = await provider.executeCommandAndWait(
      sessionID: sessionID, command: readCmd, timeoutSeconds: 10
  )
  let originalContent = readResult.output
  ```

  **After:**
  ```swift
  let readCmd = RemotePatchCommandBuilder.buildReadCommand(path: path)
  let readResult = await provider.executeCommandAndWait(
      sessionID: sessionID, command: readCmd, timeoutSeconds: 10
  )
  guard let originalContent = RemotePatchCommandBuilder.decodeBase64FileOutput(readResult.output) else {
      result = PatchResult(
          success: false,
          output: "Failed to read remote file '\(path)': could not decode base64 output. " +
              "Verify the file exists and is a text file.",
          linesChanged: 0,
          warnings: []
      )
      // Fall through to the log + callback below, then return the error result.
      break
  }
  ```

- [ ] 2a. Verify the `break` (or equivalent `continue` / early-return idiom) correctly
  skips to the log + callback and returns the error result, not a crash

- [ ] 2b. The rest of the update branch (`applyDiff` → `buildWriteCommand` → write) is
  unchanged

- [ ] 3. Remove `testUpdateFailsWithPromptPrefix` from `ApplyDiffContaminationTests` in
  `ApplyDiffTests.swift` — the bug it documents is now fixed. Replace it with a passing
  regression test:
  - `testUpdateSucceedsWithBase64ReadSimulation` — construct contaminated terminal output
    (prompt + echo + base64 encoded file content), call `decodeBase64FileOutput`, apply a
    V4A diff, verify the patch applies correctly end-to-end

- [ ] 4. Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`
  — must succeed with zero errors

- [ ] 5. Run all patch-related tests:
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test \
    -only-testing:ProSSHMacTests/ApplyDiffTests \
    -only-testing:ProSSHMacTests/ApplyPatchTests \
    -only-testing:ProSSHMacTests/UnifiedDiffParserTests \
    -only-testing:ProSSHMacTests/UnifiedDiffApplyTests \
    -only-testing:ProSSHMacTests/LocalWorkspacePatcherTests \
    -only-testing:ProSSHMacTests/PatchRoundTripTests \
    -only-testing:ProSSHMacTests/RemotePatchCommandBuilderTests
  ```
  All must pass.

- [ ] 6. Update CLAUDE.md — under **AI agent tools**, update the `apply_patch` description:
  - Remote update now uses: `buildReadCommand` (base64 read) → `decodeBase64FileOutput`
    (contamination-safe decode) → `applyDiff` (V4A in-process) → `buildWriteCommand` (base64 write)

- [ ] 7. Update `docs/featurelist.md` with dated Phase 3 loop-log entry

---

## Phase 4 — Dead Code Cleanup

Goal: remove `buildUpdateCommand` and the stale `.bak` file; align tests with actual code.

- [ ] 1. In the project root, verify `ApplyPatchTool.swift.bak` is only a backup with no
  active imports:
  ```bash
  grep -r "ApplyPatchTool.swift.bak" ProSSHMac/
  ```
  Confirm zero results, then delete the file.

- [ ] 2. In `ProSSHMac/Services/AI/ApplyPatchTool.swift`, confirm `buildUpdateCommand` has
  zero call sites:
  - Run Grep for `buildUpdateCommand` across the entire project
  - Confirm the only occurrence is the definition itself
  - Delete `buildUpdateCommand(_:)` and its `// MARK: - Update` block

- [ ] 3. In `ApplyPatchTests.swift`, update `RemotePatchCommandBuilderTests`:
  - Remove `testUpdateCommandUsesPatch` — it tested a now-deleted method
  - Add `testRemoteUpdateUsesReadThenWrite` — a documentation test that asserts
    `buildReadCommand` + `buildWriteCommand` are the correct pair for remote update
    (this serves as an architectural assertion that the pattern is intentional)

- [ ] 4. In `ProSSHMac/Services/AI/ApplyPatchTool.swift`, simplify `parseResult(_:operation:)`:
  - The method is now only called for the remote delete path
  - Remove the `patch(1)` success/warning/failure patterns (`patching file`, `Hunk`, `fuzz`,
    `FAILED`, `reject`) — these only applied to `patch(1)` output which is no longer used
  - Keep only the `__PROSSH_PATCH_ERROR__` check and a simple success fallback
  - Add a comment: `// Only called for .delete operations; create/update go through buildWriteCommand`

- [ ] 5. In `ApplyPatchTests.swift`, update `RemotePatchCommandBuilderTests`:
  - `testParseFuzzyWarning` — remove (tests `patch(1)` fuzz warning which no longer applies)
  - `testParseRejectedHunk` — remove (tests `patch(1)` rejected hunk which no longer applies)
  - `testParseSuccessResult` — update: success output is now `"Deleted /path"` style, not
    `"patching file ..."`. Adjust the test input/assertion accordingly.
  - `testParseErrorResult` — keep as-is (`__PROSSH_PATCH_ERROR__` path is unchanged)

- [ ] 6. Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`
  — must succeed with zero errors

- [ ] 7. Run full test suite:
  ```bash
  xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test
  ```
  — no regressions

- [ ] 8. Update CLAUDE.md — remove `buildUpdateCommand` from any mentions; confirm the
  AI agent tools section reflects the final state

- [ ] 9. Update `docs/featurelist.md` with dated Phase 4 loop-log entry

---

## Definition of Done

Every checkbox above must be checked before this branch is promoted from draft PR to
ready-for-review:

- [ ] `buildReadCommand` + `decodeBase64FileOutput` exist in `RemotePatchCommandBuilder`
- [ ] `AIToolHandler` remote update branch uses base64 read, not `buildRemoteReadFileChunkCommand`
- [ ] `buildUpdateCommand` is deleted
- [ ] `ApplyPatchTool.swift.bak` is deleted
- [ ] `parseResult` no longer references `patch(1)` output patterns
- [ ] `ApplyDiffTests.swift` exists with direct V4A parser tests
- [ ] All existing patch tests pass
- [ ] Full build succeeds with zero errors
- [ ] CLAUDE.md updated
- [ ] `docs/featurelist.md` updated with entries for all four phases
