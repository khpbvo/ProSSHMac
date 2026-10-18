# AI agent audit: tool dispatch, filesystem and patching

Audit date: 2026-10-18. This is the tool workstream of `AIAgentOptimization.md`.
All 110 named functions, explicit initializers/deinitializers and computed getters in the ten files
below were read and traced. This is static coverage, not a claim that every branch was executed.
The device/interactive extensions and coordinator are covered by the execution workstream.
All source locations below are under `ProSSHMac/Services/AI/` and describe this audit's revision.

## Runtime paths

`AIAgentRunner` → `AIToolHandler.executeToolCalls` → `decodeArguments` →
`executeSingleToolCall` → explicit target validation → dispatch. Malformed explicit targets are
rejected rather than silently falling back to the focused session or broadcast set.
Thrown errors return through `hint(for:)` to the common `{ok:false,error,hint}` result.

| Dispatched function | Path after target resolution |
|---|---|
| `load_skill` | Per-chat `AISkillSet.skill(named:)` snapshot → skill metadata/body or names hint |
| `list_sessions` | `AISessionDirectory.entries` + `defaultTargets` → `json` |
| `get_current_screen` | Session provider's shell buffer → bounded suffix → single/broadcast result |
| `get_command_output` | Provider `commandOutput` → capped content and truncation metadata |
| `get_recent_commands`, legacy `search_terminal_history` | Provider recent/search history → `commandBlockSummary` |
| `search_filesystem` | Local detached enumeration, or remote find builder → awaited wrapper → result parser |
| `search_file_contents` | Local detached file scan, or remote rg/grep builder → awaited wrapper → grouped matches |
| `read_files`, legacy `read_file_chunk` | Per-file numeric validation → local reader or remote base64 reader/sed fallback |
| `execute_command` | Read-bound guard → provider `sendShellInput` for each target |
| `execute_and_wait` | Read-bound/device guard → provider awaited command → output, timeout, credential result |
| legacy `get_session_info` | Provider session/working-directory metadata |
| `apply_patch` | Delete/diff checks → target/cwd-scoped approval → local patcher or remote patch workflow → callback |
| `send_input`, `run_cli_command` | Delegated extension paths; reviewed in execution audit |

Remote filesystem/patch tools reject a recognized device CLI prompt before issuing POSIX shell
syntax. Device detection remains heuristic. Each remote patch step awaits the coordinator;
permission-denied failure gets one sudo attempt, and a declined credential stops the operation.
An update requires a successful complete source read before applying its diff or issuing a write.

`LocalWorkspacePatcher.apply` → operation-specific method → canonical workspace containment →
regular-file validation where applicable → V4A `applyDiff` → atomic write/remove.
`applyDiff` → newline normalization/detection → create parser OR update parser → anchor lookup →
section/context matching → ordered chunk application. `UnifiedDiffPatcher` is a separate legacy
utility used by tests; repository search found no production constructor call.

## Fixed defects and verification targets

| Finding | Fix | Regression coverage |
|---|---|---|
| Workspace containment accepted textual-prefix siblings and symlinked parents; delete could recursively remove a directory or workspace root | Resolve symlinks, compare path components, require descendants and regular files | `LocalWorkspacePatcherTests.testSiblingWithWorkspacePrefixIsRejectedBeforeCreatingParents`, `testSymlinkedParentCannotEscapeWorkspace`, `testDeleteRejectsDirectoriesAndWorkspaceRoot`, `testWorkspaceRootMayItselfBeASymlink` |
| Approval fingerprint retained only the first 32 base64 characters; different content and hosts could share approval | SHA-256 of encoded full operation, session id and working directory | `PatchApprovalTrackerTests.testFingerprintIncludesEntireDiffAndTargetContext` |
| `Int(Double)` trapped for model-generated extreme values and rounded fractions against integer schemas | Exact failable conversion in shared parsers and batch reads | `AIToolContractTests.testOutOfRangeAndFractionalIntegersReturnErrorsWithoutTrapping` |
| Wrong-type/empty target silently selected default targets | Reject non-null targets unless nonempty connected-session UUID | `testMalformedTargetsDoNotFallBackToTheDefaultSession` |
| Dispatcher trimmed trailing spaces/newlines from diff contents | Preserve raw diff string | `testPatchDispatcherPreservesTrailingSpacesAndFinalBlankLine` |
| Local reader/command guards imposed 200 lines while schema/hints permitted 500; sed range arithmetic could overflow | Align limit to 500; compare difference without adding one | `testLocalReadHonorsTheFiveHundredLineSchemaLimit`, `testCommandReadLimitMatchesSchemaAndAvoidsIntegerOverflow` |
| Local search read/mapped a file before checking its byte cap | Check file-size resource metadata before read, retain post-read race check | Local search contract and source inspection |
| Remote updates could decode partial base64 after failed/timed-out read and write it back; empty text files could not be updated | Require successful completed read, accept successful empty output, reject timed-out writes | `testRemotePatchNeverWritesAfterAFailedOrTimedOutRead`, `testRemotePatchCanInsertIntoAnEmptyFile` |
| Remote file read retried sed after credential decline and could report a failed sed read as success | Propagate decline through helper result, stop immediately, validate fallback exit code | `testRemoteFileReadDoesNotRetryAfterDeclinedCredential` |
| File helpers could send shell syntax to router/switch prompts | Guard remote file tools before any command | `testFileToolsAtADevicePromptAreRefusedBeforeSendingShellSyntax` |
| Local literal search differed from regex rg and case-sensitive grep fallback | Remote fixed-string, case-insensitive flags in both branches | `testRemoteTextSearchUsesLiteralCaseInsensitivePatterns` |
| Absent V4A anchor allowed a pure insertion to land at the current cursor | Fail missing literal anchors; retain compatibility for legacy numeric hunk metadata | `ApplyDiffUpdateTests.testPureInsertionRejectsAnAbsentAnchor` |
| Legacy unified utility force-unwrapped oversized numbers, trapped with zero fuzz, accepted mismatched hunk counts, misread header-looking changed lines and inserted one line early | Failable parsing/count verification, safe ranges/arithmetic, preserve hunk body data and count-zero insertion position | `UnifiedDiffParserTests.testOversizedHunkNumbersThrowInsteadOfTrapping`, `testHunkCountsMustMatchTheBody`, `testHeaderLookingContentRemainsPartOfAHunk`; `UnifiedDiffApplyTests.testZeroFuzzRejectsMismatchedContextWithoutTrapping`, `testPureInsertionUsesTheDeclaredPosition` |
| Cancellation while awaiting a tool, target, approval or remote read could still run the next side effect | Check cancellation at each tool/target entry, after approval and before remembering/writing, and between remote read/retry/write stages; preserve one correlated result per tool call | `AIToolContractTests.testCancellationDuringFirstToolPreventsTheNextToolAndPreservesCallIDs`, `testCancellationDuringFirstBroadcastTargetPreventsOtherSideEffects`, `testCancellationDuringPatchApprovalCannotWriteOrRememberApproval`, `testCancellationAfterRemoteReadPreventsWriteAndSudoRetry` |

The execution workstream's malformed `send_input` and multiline CLI-command fixes are also
covered in `AIToolContractTests.testMalformedInteractiveInputIsRejectedAsAWhole` and
`testDeviceCommandRejectsMultipleLinesBeforeExecution`.
Build and executed suite results are recorded by the parent workstream in `AIAgentOptimization.md`.
No model API, saved key, live host or developer defaults write is used by these regressions.
The first integrated run exposed Foundation's failure to resolve a symlinked ancestor when
the leaf does not exist; the containment code now explicitly resolves the closest existing
ancestor, with missing suffixes and dangling links handled before any parent creation. It also
exposed three pre-existing malformed unified test headers: their declared line counts were
corrected to match their actual bodies, retaining the original assertions.

## Function inventory

Each row is reviewed. A group shares the runtime path described above; overloaded names are
listed separately by location. Stored properties and synthesized memberwise initializers are
data, not omitted executable entry points.

| File | Location: function/getter | Trace and review result |
|---|---|---|
| `AIToolHandler.swift` | 10: `BroadcastContext.isBroadcasting` | Default set is broadcast only for more than one id; retained |
| | 18: `init`, 19: `deinit` | Service owns handler; weak service backlink and nonisolated destruction retained |
| | 23: `executeToolCalls` | Runner entry; sequential tool execution, result per call id, caught errors and metadata-only success logs |
| | 62: `executeSingleToolCall` | Full switch traced above; target, integer, diff and approval defects fixed |
| | 792: `hint` | Typed argument/session recovery, generic screen-check fallback |
| | 806: `resolveTargetSessions` | Explicit UUID or `AISessionDirectory.defaultTargets`; caller validates explicit targets |
| | 820: `formatBroadcastResult` | Labelled result sections in original order; retained |
| `AIToolHandler+ArgumentParsing.swift` | 8: `decodeArguments` | Dispatch → JSON object decoder; empty input remains empty object |
| | 32: `requiredString` | Dispatch → nonempty trimmed identifier/command fields; diff now bypasses this trim |
| | 56: `requiredInt` | Dispatch → exact finite in-range integer or argument error; numeric-string compatibility retained |
| | 84: `optionalString` | Optional query/target/name fields → trimmed string or nil |
| | 97: `optionalInt` | Optional bounds/timeouts and batch entries → safe exact integer/nil |
| | 114: `clamp` | Callers enforce schema/resource caps |
| `AIToolHandler+LocalFilesystem.swift` | 8: `searchFilesystemEntries` | Dispatch → detached URL resolution + bounded enumeration + filename match |
| | 77: `searchFileContents` | Dispatch → detached bounded file scan → content matcher → grouped result |
| | 153: `readLocalFileChunk` | Dispatch → detached text decode/newline normalization → 500-line slice |
| | 221: `resolvedLocalSearchURL` | Search/read paths → tilde expansion + cwd-relative standardized URL |
| | 241: `filenameMatches` | Filename search → glob or case/diacritic-insensitive substring |
| | 250: `groupMatchesByFile` | Local/remote content search → ordered per-file hit arrays |
| | 276: `contentMatchesForFile` | Scan → pre-read size cap, binary/decode checks, bounded literal matching |
| `AIToolHandler+OutputHelpers.swift` | 13: `credentialDeclinedMessage` | Credential errors → host-specific text |
| | 17: `credentialDeclinedResult` | Main dispatch → standard JSON decline error |
| | 21: `credentialDeclinedObject` | Remote helpers → same decline contract as structured JSON |
| | 25: `cancelledToolObject` | Remote helpers → standard cancellation error with no retry instruction |
| | 29: `sessionLabel` | Credential/tool outcomes → provider label or short id |
| | 33: `commandBlockSummary` | Recent/history results → id, command, 150-character preview, time, exit |
| | 43: `parseReadFileChunkOutput` | Remote sed fallback → token errors or content/pagination fields |
| | 78: `readBoundViolationMessage` | Command dispatch → heuristic read-size guard, aligned limits and overflow fix |
| | 111: `firstCapturedInt` | Read guard → regex bounded Int parse |
| | 124: `firstCapturedRange` | Read guard → failable sed-bound parsing |
| `AIToolHandler+RemoteExecution.swift` | 16: `searchFilesystemEntriesRemote` | Dispatch → find builder → execution → token/result parser |
| | 53: `searchFileContentsRemote` | Dispatch → literal rg/grep builder → execution → grouped parser |
| | 90: `readRemoteFileChunk` | Dispatch → base64 full-file read → slice or validated sed fallback |
| | 168: `executeRemoteToolCommand` | Helpers → provider execution → timeout/decline-preserving result |
| | 196: `parseRemoteFilesystemSearchOutput` | find result → normalized f/d rows + truncation/raw preview |
| | 237: `parseRemoteFileContentSearchOutput` | rg/grep result → line tuples → grouping |
| | 279: `parseRemoteFilesystemResultLine` | Parser → type/path extraction; whitespace-path limitation below |
| | 307: `remoteOutputPreview` | Parse/failure diagnostics → bounded preview |
| | 313: `parseRemoteGrepMatchLine` | Parser → first colon-number-colon tuple; colon-path limitation below |
| | 338: `buildRemoteFilesystemSearchCommand` | Shell-quoted find pattern/root, tilde expansion, GNU/BSD branch, head cap |
| | 364: `buildRemoteFileContentSearchCommand` | Shell-quoted literal pattern/root, rg or grep case-insensitive branch, head cap |
| | 386: `buildRemoteReadFileChunkCommand` | Fallback → quoted root, file tokens, bounded sed range |
| | 401: `shellSingleQuoted` | Builder inputs → single-quote escape |
| `AIToolHandler+RemotePatch.swift` | 26: `applyRemotePatch` | Dispatch → operation workflow, source/write validation and credential propagation |
| | 34: nested `run` | Workflow → command runner and accumulated credential flags |
| | 150: `runRemotePatchCommand` | Plain command → at most one sudo retry for permission errors; no retry after timeout/decline |
| | 180: `failedPatch` | Workflow → zero-change failed result |
| | 184: `trimmedPatchOutput` | Permission detection/failure diagnostic normalization |
| | 188: `isPermissionDeniedPatchOutput` | Failed command → permission-word heuristic |
| | 197: `buildPatchFailureMessage` | Failure → nonempty diagnostic |
| `AISessionDirectory.swift` | 18: `entries` | Runner/list tool → connected-session map, focus first, device marking |
| | 43: `defaultTargets` | Dispatch/list tool → focused id or broadcast ids |
| | 48: `preamble` | Runner → per-turn open-session text |
| | 64: `json` | List tool → session/default-target JSON |
| | 81: `deviceCLIPrompt` | Entries → cursor-line extraction/classification |
| | 87: `describe` | Runner → local or SSH focused-session label |
| `ApplyPatchTool.swift` | 29: `PatchApprovalTracker.fingerprint` | Dispatch → full SHA-256 including target/cwd context |
| | 37: `isApproved`, 42: `remember`, 47: `reset` | Approval gate/lifecycle → in-memory set membership/mutation |
| | 93: `LocalWorkspacePatcher.init` | Dispatch → canonical workspace root |
| | 98: `apply` | Dispatch → create/update/delete |
| | 111: `createFile` | Resolved descendant → V4A-plus or legacy raw content → atomic write; existing file delegates update |
| | 144: `updateFile` | Valid regular file → UTF-8 read → V4A → atomic write + stats |
| | 179: `deleteFile` | Valid regular descendant → removeItem; directory/root rejected |
| | 201: `resolvedPath` | All mutations → canonical component boundary → optional parent creation |
| | 235: `canonicalTarget` | Containment → nearest existing ancestor/symlink resolution and missing-suffix reconstruction; bounded link recursion |
| | 257: `requireRegularFile` | Update/delete → URL resource kind validation |
| | 263: `relativePath` | Result text → workspace-relative display path |
| | 283: `RemotePatchCommandBuilder.buildCommand` | Legacy/test entry → create/delete; update deliberately traps on programmer misuse; no production caller found |
| | 296: `buildCreateCommand` | Legacy builder → quoted heredoc; production create uses base64 write instead |
| | 325: operation `buildDeleteCommand` | Legacy builder → path overload |
| | 329: path `buildDeleteCommand` | Remote workflow → regular-file check, rm/sudo rm + explicit missing token |
| | 346: `buildWriteCommand` | Remote create/update → quoted base64 heredoc, mkdir and redirect/tee |
| | 390: `buildReadCommand` | Remote reads → quoted base64/sudo base64 |
| | 402: `decodeBase64FileOutput` | Remote reads → base64-like line filter, UTF-8 decode; successful empty output handled by caller |
| | 419: `shellEscaped` | Remote builder → single-quote escape |
| | 426: `parseResult` | Remote delete → explicit patch-error token or success |
| | 462: `PatchToolError.errorDescription` | Throw → readable path/type/approval/remote diagnostics |
| | 491: `ApplyPatchToolDefinition.definition` | Service tool assembly → V4A schema; local/remote guarantees corrected |
| `UnifiedDiffPatcher.swift` | 23: `DiffError.errorDescription`, 63: `HunkLine.text` | Legacy diagnostics/data projections |
| | 109: `parse` | Legacy apply/tests → headers skipped, hunk sequence parsed |
| | 167: `apply` | Legacy entry → parse → create/patch branch |
| | 185: `parseHunk` | Header/body parsing with safe integer/count checks |
| | 280: `applyCreate` | Parsed hunks → additions/context content |
| | 300: `applyPatch` | Reverse hunk application, overlap check, newline preservation |
| | 392: `findHunkPosition` | Patch → exact/fuzzy context search and insertion positioning |
| | 469: `verifyHunkContext` | Position search → context/removal comparison |
| | 496: `linesMatch` | Legacy comparison → exact/trailing-whitespace tolerance |
| `apply_diff.swift` | 32: `V4ADiffError.errorDescription` | Parser/applicator throw → readable context/overlap errors |
| | 64: `applyDiff` | Runtime local/remote patch → normalize/parse/apply entry |
| | 111: `V4AParserState.init`, 120: `deinit` | Parser cursor/fuzz state and nonisolated destruction |
| | 137: `v4aNormalizeDiffLines` | Entry → split/CR stripping/one terminator newline removal |
| | 148: `v4aDetectNewlineFromText`, 152: `v4aDetectNewline` | Entry → input/diff newline style |
| | 160: `v4aNormalizeTextNewlines` | Update entry → CRLF normalization |
| | 167: `v4aIsDone`, 177: `v4aReadStr` | Create/update parser → terminators and prefix/cursor advance |
| | 187: `v4aParseCreateDiff` | Create → plus-line extraction |
| | 206: `v4aParseUpdateDiff` | Update → anchor/section/context matching → ordered chunks |
| | 281: `v4aAdvanceCursorToAnchor` | Update parser → exact/stripped anchor search; absent anchors now throw |
| | 325: `v4aReadSection` | Update parser → context + deletion/insertion chunks and EOF marker |
| | 431: `v4aFindContext`, 449: `v4aFindContextCore` | Section → exact/trailing/full whitespace search, EOF preference/fallback |
| | 485: `v4aEqualsSlice`, 499: `v4aRStrip` | Context matcher → bounded mapped comparison and trailing whitespace strip |
| | 509: `v4aApplyChunks` | Parsed update → bounds/overlap checks → copy/insert/delete/join |

## Remaining limits and risks

- Workspace validation and filesystem mutation are separate operations. Canonical checks block
  stable symlink escapes, but do not make the operation race-proof against another local process
  changing a parent symlink between validation and write. Descriptor-relative operations would
  be needed for a stronger boundary.
- Remote patch writes truncate directly and are not atomic, are not protected against concurrent
  remote edits, and do not implement the local workspace boundary. The tool description now
  states these actual guarantees. Adding remote temporary-file/rename writes must preserve
  ownership/mode/sudo behavior and requires dedicated host validation.
- Remote `~` paths in patch/base64 builders are quoted literally; file-search/sed builders expand
  them. Prefer absolute paths until a single remote-path abstraction replaces this difference.
  Leading-dash file names also need command-specific operand normalization.
- Remote base64 reads still transfer whole files before line slicing. Local chunk reads also
  load/decode whole text files. The 500-line result bound is not a file-memory/transport bound.
- Base64 line filtering is a compatibility heuristic. Corrupted output may occasionally contain
  base64-looking text; complete exit-status validation reduces, but does not eliminate, this risk.
- `get_command_output` has a 16,000-character prefix cap and no offset. Long diagnostic output
  cannot currently be paged through that tool. Both command and CLI result caps need a common
  paged/captured-output contract if complete very long output must be recoverable.
- `defaultTargets` uses the per-turn broadcast ids without live connected-state filtering.
  Explicit ids are validated, but a disconnect during a turn can leave stale defaults; providers
  must reject them. Duplicate broadcast ids can also repeat work if a caller constructs them.
- Search results report `truncated` conservatively when exactly at the limit. Local search
  skips oversized/unreadable/binary files without per-file omissions. Local substring matching
  additionally ignores diacritics; host rg/grep locale handling differs.
- Remote text parsing cannot represent newline-containing paths; the first `:number:` in a path
  can be mistaken for a grep line number, and surrounding path whitespace is trimmed.
- Sed fallback pagination counts a terminal split fragment as a line and infers more data from
  result count. Exact empty/EOF metadata and line-ending normalization need a shared local/remote
  reader contract; it should fetch one extra line and distinguish no output from one blank line.
- Local create retains legacy raw-text acceptance, while remote create requires plus-prefixed
  V4A lines. Legacy numeric headers are accepted by V4A on update for existing callers, even
  though the current model-facing schema asks for textual/bare anchors.
- The legacy unified parser accepts a first file from multi-file input and ignores later file
  sections. It has no current production constructor; removing it or making multi-file rejection
  explicit is a separate compatibility cleanup.
- Patch settings now use the service's injected defaults (the standard suite in production,
  an isolated suite in contract tests), so approval/deletion policy tests do not depend on or
  write the developer's saved policy.
- Device recognition, permission-message detection, command read guards and remote output
  parsing are heuristics. No live shell, remote host, router, password entry or UI approval was
  exercised by this workstream; those remain integration checks.
