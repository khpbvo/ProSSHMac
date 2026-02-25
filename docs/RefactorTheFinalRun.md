# RefactorTheFinalRun.md — Final Decomposition Run

This document tracks the decomposition of the four largest remaining god files
in the ProSSHMac codebase. All prior refactors (actor-isolation, TerminalView,
TerminalGrid, MetalTerminalRenderer) are complete. These four files are what
remain.

**Branch:** `refactor/final-run` — create from master before starting.

---

## File Rankings (as of 2026-02-25)

| File | Lines | Active Refactor? |
|------|-------|-----------------|
| `Services/OpenAIResponsesService.swift` | 1,305 | **None — start here** |
| `Services/SessionManager.swift` | 1,196 | Phase 5 done; Phases 6–9 below |
| `Services/SSHConfigParser.swift` | 1,018 | None |
| `Services/CertificateAuthorityService.swift` | 985 | None |

---

## Shared Rules (apply to all files below)

1. **Build must pass after every file extraction** — verify with
   `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`.
2. **Commit after every phase** — each phase is a self-contained commit.
3. **Header comment on every extracted file** — first non-blank, non-import line:
   `// Extracted from [SourceFileName].swift`
4. **Every new Swift file must pass `-strict-concurrency=complete`** before its
   creating commit. Add the flag temporarily, verify zero warnings, remove before commit.
5. **Add `// swiftlint:disable file_length` in Phase 0** of each file's run;
   remove it only after the main file drops below 400 lines.
6. **Update this file and `CLAUDE.md`** after completing each phase.

---

## File 1 — `Services/OpenAIResponsesService.swift` (1,305 lines)

### What's in the file (section map)

| Lines (approx) | Content |
|----------------|---------|
| 1–265 | Protocols (`OpenAIResponsesServicing`, `OpenAIHTTPSessioning`), error enum, public value types: `OpenAIResponsesMessage`, `OpenAIResponsesToolOutput`, `OpenAIJSONValue` (+Codable), `OpenAIResponsesToolDefinition`, `OpenAIResponsesRequest`, `OpenAIResponsesResponse`, `OpenAIResponsesStreamEvent` |
| 267–931 | `OpenAIResponsesService` class — HTTP client, retry loop, `createResponse`, `createResponseStreaming`, `performRequest`, `performStreamingRequest`, SSE byte-by-byte parsing, `consumeStreamPayload`, SSE event routing helpers |
| 933–1227 | `StreamingResponseAccumulator` private struct — assembles a complete `OpenAIResponsesResponse` from incremental SSE events |
| 1228–1305 | Codable payload structs: `CreateRequestPayload`, `CreateInputMessage`, `CreateFunctionCallOutput`, `OpenAIErrorEnvelope` |

### Phase 0 — Baseline — **COMPLETE** (2026-02-25, commit `99ef976`)

- [x] Create branch `refactor/final-run` from master.
- [x] Add `// swiftlint:disable file_length` as line 1 of `OpenAIResponsesService.swift`.
- [x] Run build. Record warning count as baseline. (BUILD SUCCEEDED, 0 warnings)
- [x] Commit: `docs: begin RefactorTheFinalRun — Phase 0 swiftlint disable on OpenAIResponsesService`

### Phase 1 — Extract `OpenAIResponsesTypes.swift`

**Goal:** Move all public protocols, error type, and value types out of the service
file so that the service class file only contains the class itself.

**Files to create:** `ProSSHMac/Services/OpenAIResponsesTypes.swift`

**Steps:**
- [x] Read `OpenAIResponsesService.swift` lines 1–265 in full before touching anything.
- [x] Create `Services/OpenAIResponsesTypes.swift`. Header: `// Extracted from OpenAIResponsesService.swift`.
- [x] Move into it (in order):
  - `OpenAIResponsesServicing` protocol + default extension
  - `OpenAIHTTPSessioning` protocol + `OpenAIStreamingUnsupportedError` + default extension
  - `extension URLSession: OpenAIHTTPSessioning`
  - `OpenAIResponsesServiceError` enum
  - `OpenAIResponsesMessage` struct
  - `OpenAIResponsesToolOutput` struct
  - `OpenAIJSONValue` enum + Codable extension
  - `OpenAIResponsesToolDefinition` struct
  - `OpenAIResponsesRequest` struct
  - `OpenAIResponsesResponse` struct (with nested types)
  - `OpenAIResponsesStreamEvent` enum
- [x] Delete the moved declarations from `OpenAIResponsesService.swift`.
- [x] Build. Fix any access-level errors (widen `private` → `internal` if needed).
- [x] Commit: `refactor(RefactorFR Phase 1): extract OpenAIResponsesTypes.swift`

**COMPLETE** (2026-02-25, commit `6559ce6`). Correction: `OpenAIStreamingUnsupportedError` was also
referenced in `OpenAIResponsesService` line 242 (`catch is OpenAIStreamingUnsupportedError`), so it was
widened from `private` → `internal`. Service file: 1,305 → 1,043 lines. Types file: 265 lines.

### Phase 2 — Extract `OpenAIResponsesPayloadTypes.swift`

**Goal:** Move the internal Codable request-encoding structs into their own file.

**Files to create:** `ProSSHMac/Services/OpenAIResponsesPayloadTypes.swift`

**Steps:**
- [x] Read the bottom of `OpenAIResponsesService.swift` (lines 1228–1305).
- [x] Create `Services/OpenAIResponsesPayloadTypes.swift`. Header: `// Extracted from OpenAIResponsesService.swift`.
- [x] Move into it:
  - `CreateRequestPayload` struct
  - `CreateInputItem` enum (also present — plan sketch missed it)
  - `CreateInputMessage` struct
  - `CreateFunctionCallOutput` struct
  - `OpenAIErrorEnvelope` struct + nested `APIError`
- [x] Change `private struct` → `struct` (internal) so they compile cross-file.
- [x] The `fileprivate static func decodeJSONValue` on `OpenAIResponsesService` is
  used by `StreamingResponseAccumulator` — change `fileprivate` → `internal` now
  (it will stay on the service class; the accumulator will call it after extraction).
- [x] Build. Fix any remaining access issues.
- [x] Commit: `refactor(RefactorFR Phase 2): extract OpenAIResponsesPayloadTypes.swift`

**COMPLETE** (2026-02-25, commit `5e90cd9`). Correction: plan sketch missed `CreateInputItem` enum —
also moved to payload types file. Service file: 1,043 → 964 lines. Payload types file: 81 lines.

### Phase 3 — Extract `OpenAIResponsesStreamAccumulator.swift`

**Goal:** Move `StreamingResponseAccumulator` into its own file.

**Files to create:** `ProSSHMac/Services/OpenAIResponsesStreamAccumulator.swift`

**Steps:**
- [x] Read `StreamingResponseAccumulator` fully (lines ~933–1227).
- [x] Create `Services/OpenAIResponsesStreamAccumulator.swift`. Header: `// Extracted from OpenAIResponsesService.swift`.
- [x] Move the entire `StreamingResponseAccumulator` struct. Change `private struct` →
  `struct` (internal).
- [x] Update any call in `OpenAIResponsesService` that referenced the type as `private`
  — no changes needed (struct was already `private` in same file; now just `internal`).
- [x] Build. Verify zero concurrency warnings with `-strict-concurrency=complete`.
- [x] Commit: `refactor(RefactorFR Phase 3): extract OpenAIResponsesStreamAccumulator.swift`

**COMPLETE** (2026-02-25, commit `6b0c8a2`). Service file: 964 → 669 lines. Accumulator file: 297 lines.
No access-level corrections needed beyond `private struct` → `struct`.

### Phase 4 — Extract `OpenAIResponsesService+Streaming.swift`

**Goal:** Move all SSE streaming logic out of the main class file into an extension.

**Files to create:** `ProSSHMac/Services/OpenAIResponsesService+Streaming.swift`

**Steps:**
- [x] Read `performStreamingRequest`, `consumeStreamPayload`, SSE event routing helpers,
  and the byte-loop in `createResponseStreaming` fully before moving anything.
- [x] Create `Services/OpenAIResponsesService+Streaming.swift`. Header: `// Extracted from OpenAIResponsesService.swift`.
- [x] Move into an `extension OpenAIResponsesService`:
  - `createResponseStreaming(_:onEvent:)` (the public method — remove from class body)
  - `performStreamingRequest(apiKey:request:onEvent:traceID:)`
  - `consumeStreamPayload(_:eventName:onEvent:accumulator:)`
  - `completedResponse(from:)` static helper
  - `streamErrorMessage(from:)` static helper
  - `stringField(in:key:)` static helper
  - `reasoningSummaryText(from:)` static helper
- [x] Leave `createResponse`, `performRequest`, `createPayload`, retry helpers, and
  logging utilities in the main class body.
- [x] Build. Verify `-strict-concurrency=complete` is clean.
- [x] Commit: `refactor(RefactorFR Phase 4): extract OpenAIResponsesService+Streaming.swift`

**COMPLETE** (2026-02-25, commit `b07c3cf`). Correction: extension file also needs `import os.log`
(uses `Logger` privacy interpolation). Widened `private` → internal on all class-body members called
from the extension: stored properties (`apiKeyProvider`, `session`, `endpointURL`), `logger`, 7 instance/
static methods, 7 static utility functions. Service file: 669 → 260 lines. Streaming file: 415 lines.

### Phase 5 — Slim & cleanup

**Goal:** The main `OpenAIResponsesService.swift` should be under 300 lines.
Remove `// swiftlint:disable file_length` once it's under 400 lines.

**Steps:**
- [x] Verify current line count of `OpenAIResponsesService.swift`.
- [x] Remove `// swiftlint:disable file_length` if file is below 400 lines.
- [x] Run full test suite. Record any new failures vs. baseline.
- [x] Commit: `refactor(RefactorFR Phase 5): slim OpenAIResponsesService — cleanup complete`

**COMPLETE** (2026-02-25, commit `fa6348c`). File is 259 lines. Removed `// swiftlint:disable file_length`.
Tests: 209 tests, 2 failures — both pre-existing (Base32Tests.testDecodeEmpty, ColorRenderValidationTest
color rendering). No new failures introduced. OpenAIResponsesService decomposition fully complete.

---

## File 2 — `Services/SessionManager.swift` (1,196 lines)

### Context

Phase 5 of the actor-isolation refactor extracted four coordinators:
`SessionReconnectCoordinator`, `SessionKeepaliveCoordinator`,
`TerminalRenderingCoordinator`, `SessionRecordingCoordinator`.

The file is still 1,196 lines because the following concerns were NOT extracted:
- SFTP/file-transfer methods
- `executeCommandAndWait` (AI tool execution)
- Shell I/O dispatch + `sendInput` + PTY resize
- Core session lifecycle (`connect`, `disconnect`, `openLocalSession`)
- Known-host verification (`verifyHost`, `refreshKnownHosts`)
- History tracking + command block publishing

### Phase 6 — Extract `SessionSFTPCoordinator.swift`

**Goal:** Move all SFTP and remote filesystem methods into a coordinator.

**Files to create:** `ProSSHMac/Services/SessionSFTPCoordinator.swift`

**Steps:**
- [x] Read the entire SessionManager to locate all SFTP methods before moving anything.
  Look for: `listDirectory`, `uploadFile`, `downloadFile`, `deleteRemoteFile`,
  `createRemoteDirectory`, `renameRemoteFile`, any `sftp`-prefixed helpers.
- [x] Create `Services/SessionSFTPCoordinator.swift` using the same weak-reference
  coordinator pattern (`weak var manager: SessionManager?`). Header:
  `// Extracted from SessionManager.swift`.
- [x] Move each SFTP method; replace in `SessionManager` with one-line forwarding
  wrappers that delegate to `sftpCoordinator`.
- [x] Add `let sftpCoordinator: SessionSFTPCoordinator` to `SessionManager` stored
  properties. Wire `sftpCoordinator.manager = self` in `init`.
- [x] Build. Fix any missing-symbol errors.
- [x] Commit: `refactor(RefactorFR Phase 6): extract SessionSFTPCoordinator`

**Result:** 3 SFTP methods extracted (lines 652–671). SessionManager: 1,196 → 1,191 lines.
Commit: `8b18935`. BUILD SUCCEEDED. (2026-02-25)

### Phase 7 — Extract `SessionAIToolCoordinator.swift`

**Goal:** Move AI terminal tool execution out of `SessionManager`.

**Files to create:** `ProSSHMac/Services/SessionAIToolCoordinator.swift`

**Steps:**
- [x] Read `executeCommandAndWait` and any supporting marker/polling helpers fully.
- [x] Create `Services/SessionAIToolCoordinator.swift`. Header:
  `// Extracted from SessionManager.swift`.
- [x] Move: `executeCommandAndWait`, any marker-injection helpers, and
  command-block publishing methods (`publishCommandBlock`, etc.).
- [x] Keep `@Published var latestCompletedCommandBlockBySessionID` and
  `commandCompletionNonceBySessionID` on `SessionManager` (SwiftUI observes them);
  coordinator writes via `manager?.`.
- [x] Add `let aiToolCoordinator: SessionAIToolCoordinator` to `SessionManager`.
  Wire in `init`.
- [x] Build. Fix access issues.
- [x] Commit: `refactor(RefactorFR Phase 7): extract SessionAIToolCoordinator`

**Result:** Extracted `executeCommandAndWait` (50 lines), `parseWrappedCommandOutput` (16 lines),
`publishCommandCompletion` (9 lines). Widened `private(set)` → `var` on `bytesSentBySessionID`,
`latestCompletedCommandBlockBySessionID`, `commandCompletionNonceBySessionID`; widened
`private var latestPublishedCommandBlockIDBySessionID` → `var`. `publishCommandCompletion`
kept as a one-line forwarding wrapper on SessionManager (called by TerminalRenderingCoordinator
via `manager.publishCommandCompletion`). SessionManager: 1,191 → 1,128 lines.
Commit: `b037ee1`. BUILD SUCCEEDED. (2026-02-25)

### Phase 8 — Extract `SessionShellIOCoordinator.swift`

**Goal:** Move shell I/O, PTY resize, and `sendInput` out of `SessionManager`.

**Files to create:** `ProSSHMac/Services/SessionShellIOCoordinator.swift`

**Steps:**
- [x] Locate all shell I/O methods: `sendInput`, `sendData`, `resizePTY`,
  `startReadingFromChannel`, and related Task-spawning helpers.
- [x] Create `Services/SessionShellIOCoordinator.swift`. Header:
  `// Extracted from SessionManager.swift`.
- [x] Move methods. Keep `@Published var shellBuffers` on `SessionManager`;
  coordinator writes via `manager?.shellBuffers[id] = ...`.
- [x] Add `let shellIOCoordinator: SessionShellIOCoordinator` to `SessionManager`.
  Wire in `init`.
- [x] Build.
- [x] Commit: `refactor(RefactorFR Phase 8): extract SessionShellIOCoordinator`

**Result:** Extracted `sendShellInput` (32L), `sendRawShellInput` (24L), `startParserReader`
(61L), `recordParsedChunk` (12L). Moved `parserReaderTasks` dict to coordinator; SessionManager
calls `shellIOCoordinator.cancelParserTask(for:)` from `removeSessionArtifacts`. Widened
`bytesReceivedBySessionID` from `@Published private(set)` → `@Published var`. `handleShellStreamEndedInternal`
kept on SessionManager (called by both coordinator and `SessionKeepaliveCoordinator`). SessionManager:
1,128 → 1,005 lines. Commit: `b6fdf69`. BUILD SUCCEEDED. (2026-02-25)

### Phase 9 — Slim `SessionManager.swift` & cleanup

**Goal:** Leave `SessionManager` with only: stored properties, `init`, session
lifecycle (`connect`, `disconnect`, `openLocalSession`, `closeSession`), and known-host
verification. Target: under 400 lines.

**Steps:**
- [x] Verify remaining line count. Extract any remaining stray logic if still over 400L.
- [x] Remove `// swiftlint:disable file_length` once under 400 lines.
- [x] Run full test suite.
- [x] Commit: `refactor(RefactorFR Phase 9): slim SessionManager — lifecycle only`

**Result (2026-02-25):** Extracted 6 read-only query/history methods into
`SessionManager+Queries.swift` (`activeSession`, `mostRelevantSession`, `totalTraffic`,
`recentCommandBlocks`, `searchCommandHistory`, `commandOutput`). File: 1,005 → 969 lines.
400-line target not achievable without a future `SessionConnectionCoordinator` extraction
(out of scope). `// swiftlint:disable` retained. Build: SUCCEEDED. Tests: 2 pre-existing
failures, zero new. Commit: `eeb2ba3`.

---

## File 3 — `Services/SSHConfigParser.swift` (1,018 lines)

### What's in the file (section map)

| Type | Lines (approx) | Responsibility |
|------|----------------|----------------|
| `SSHConfigParser` | 1–274 | Lexes raw `~/.ssh/config` text into `SSHConfigEntry` values |
| `SSHConfigTokenExpander` | 276–342 | Expands `%h`, `%u`, `%p` etc. in directive values |
| `SSHConfigMapper` | 344–783 | Maps `SSHConfigEntry` → ProSSHMac `Host` model |
| `SSHConfigExporter` | 785–911 | Exports `Host` models → SSH config text |
| `SSHConfigImportService` | 913–1018 | Orchestrates parse → map pipeline; `findDuplicates` extension |

All five are pure value types (`struct`) — no `@MainActor`, no shared state.
Each is already self-contained. This is a straightforward split.

### Phase 10 — Baseline

- [x] Add `// swiftlint:disable file_length` as line 1.
- [x] Run build. Confirm no new failures.
- [x] Commit: `docs: Phase 10 swiftlint disable on SSHConfigParser.swift`

**Result (2026-02-25):** Added `// swiftlint:disable file_length`. Build: SUCCEEDED. Commit: `0a7ac88`.

### Phase 11 — Extract `SSHConfigTokenExpander.swift`

- [x] Create `Services/SSHConfigTokenExpander.swift`. Header:
  `// Extracted from SSHConfigParser.swift`.
- [x] Move `SSHConfigTokenExpander` struct and its nested `Context` struct.
- [x] Build.
- [x] Commit: `refactor(RefactorFR Phase 11): extract SSHConfigTokenExpander`

**Result (2026-02-25):** Extracted `SSHConfigTokenExpander` + `Context`. Build: SUCCEEDED. Commit: `42e30d2`.

### Phase 12 — Extract `SSHConfigMapper.swift`

- [x] Create `Services/SSHConfigMapper.swift`. Header:
  `// Extracted from SSHConfigParser.swift`.
- [x] Move `SSHConfigMapper` struct (including all private helpers and nested types).
- [x] Build.
- [x] Commit: `refactor(RefactorFR Phase 12): extract SSHConfigMapper`

**Result (2026-02-25):** Extracted `SSHConfigMapper` (~440L, 8 private helpers, `ResolutionContext`, `MappingResult`). Build: SUCCEEDED. Commit: `2c450df`.

### Phase 13 — Extract `SSHConfigExporter.swift`

- [x] Create `Services/SSHConfigExporter.swift`. Header:
  `// Extracted from SSHConfigParser.swift`.
- [x] Move `SSHConfigExporter` struct and its nested `ExportOptions`.
- [x] Build.
- [x] Commit: `refactor(RefactorFR Phase 13): extract SSHConfigExporter`

**Result (2026-02-25):** Extracted `SSHConfigExporter` + `ExportOptions` (~128L). Build: SUCCEEDED. Commit: `5aece8a`.

### Phase 14 — Extract `SSHConfigImportService.swift` & slim

- [x] Create `Services/SSHConfigImportService.swift`. Header:
  `// Extracted from SSHConfigParser.swift`.
- [x] Move `SSHConfigImportService` struct + its `ImportPreview` nested type
  + the `extension SSHConfigImportService` (`findDuplicates`).
- [x] Remove `// swiftlint:disable file_length` from `SSHConfigParser.swift`
  (only `SSHConfigParser` + supporting value types will remain, well under 400L).
- [x] Build. Run full test suite.
- [x] Commit: `refactor(RefactorFR Phase 14): extract SSHConfigImportService — SSHConfigParser slim complete`

**Result (2026-02-25):** Extracted `SSHConfigImportService` + `ImportPreview` + `findDuplicates` extension (~109L).
Also cleaned orphaned token expander doc comment. `// swiftlint:disable` removed.
`SSHConfigParser.swift`: 1,018 → 275 lines. Build: SUCCEEDED. Tests: 2 pre-existing failures, zero new. Commit: `e341205`.

---

## File 4 — `Services/CertificateAuthorityService.swift` (985 lines)

### What's in the file (section map)

| Section | Lines (approx) | Content |
|---------|----------------|---------|
| Request structs | 1–52 | `CertificateAuthorityGenerationRequest`, `UserCertificateSigningRequest`, `HostCertificateSigningRequest`, `KRLGenerationRequest`, `GeneratedKRLBundle` |
| Error type | 54–69 | `CertificateAuthorityError` enum |
| Service class | 71–869 | `CertificateAuthorityService`: authority CRUD, cert signing, KRL generation, import; all private helpers |
| Supporting types | 871–985 | `ParsedPublicKey`, `ParsedExternalCertificate`, `SSHBinaryReader`, `CertificateRole` (all `private`) |

The class mixes four distinct concerns in its private methods:
1. **Business logic** — `createAuthority`, `signCertificate`, `generateKRL`, `importExternalCertificate`, `deleteAuthorities`
2. **Certificate binary parsing** — `parseAuthorizedCertificate`, `parseAuthorizedPublicKey`, `skipCertificateSubjectKeyData`, `parseStringListPayload`, `parseNameValueMapPayload`, `baseKeyType`, `certificateKeyType`
3. **SSH binary encoding** — `sshString`, `u32`, `u64`, `encodeStringList`, `encodeNameValueMap`, `fingerprintSHA256`, `randomBytes`, `readFirstSSHString`
4. **KRL helpers** — `authorizedRepresentation`, `sanitizeFileComponent`, `csvSafe`

### Phase 15 — Baseline

- [x] Add `// swiftlint:disable file_length` as line 1.
- [x] Run build. Confirm no new failures.
- [x] Commit: `docs: Phase 15 swiftlint disable on CertificateAuthorityService.swift`

**Result (2026-02-25):** BUILD SUCCEEDED. Commit `17503da`.

### Phase 16 — Extract `SSHBinaryReader.swift`

**Goal:** Pull `SSHBinaryReader` out of `private` scope so it can be reused.

**Files to create:** `ProSSHMac/Services/SSHBinaryReader.swift`

**Steps:**
- [x] Create `Services/SSHBinaryReader.swift`. Header:
  `// Extracted from CertificateAuthorityService.swift`.
- [x] Move `SSHBinaryReader` struct. Change `private struct` → `struct` (internal).
- [x] Move `CertificateRole` enum with it (they're coupled — `CertificateRole` is only
  used by parsing). Change `private enum` → `enum` (internal).
- [x] Move `ParsedPublicKey` and `ParsedExternalCertificate` structs (used only by
  parsing methods). Change `private struct` → `struct` (internal).
- [x] Build.
- [x] Commit: `refactor(RefactorFR Phase 16): extract SSHBinaryReader + supporting types`

**Result (2026-02-25):** BUILD SUCCEEDED. CertificateAuthorityService.swift: 987→870L. Commit `6f83002`.

### Phase 17 — Extract `CertificateAuthorityService+BinaryEncoding.swift`

**Goal:** Move all low-level SSH wire-format encoding helpers into an extension.

**Files to create:** `ProSSHMac/Services/CertificateAuthorityService+BinaryEncoding.swift`

**Steps:**
- [ ] Create the file. Header: `// Extracted from CertificateAuthorityService.swift`.
- [ ] Move into `extension CertificateAuthorityService`:
  - `sshString(from:)` — text overload
  - `sshString(from:)` — data overload
  - `u32(_:)`
  - `u64(_:)`
  - `encodeStringList(_:)`
  - `encodeNameValueMap(_:)`
  - `fingerprintSHA256(for:)`
  - `randomBytes(count:)`
  - `readFirstSSHString(from:)`
- [ ] Change `private func` → `func` (internal) on each.
- [ ] Build.
- [ ] Commit: `refactor(RefactorFR Phase 17): extract CertificateAuthorityService+BinaryEncoding`

### Phase 18 — Extract `CertificateAuthorityService+CertificateParsing.swift`

**Goal:** Move all certificate binary parsing helpers into an extension.

**Files to create:** `ProSSHMac/Services/CertificateAuthorityService+CertificateParsing.swift`

**Steps:**
- [ ] Create the file. Header: `// Extracted from CertificateAuthorityService.swift`.
- [ ] Move into `extension CertificateAuthorityService`:
  - `parseAuthorizedCertificate(_:)`
  - `parseAuthorizedPublicKey(_:)`
  - `skipCertificateSubjectKeyData(certificateKeyType:reader:)`
  - `parseStringListPayload(_:context:)`
  - `parseNameValueMapPayload(_:context:)`
  - `displayValue(forOptionData:)`
  - `parseSignatureAlgorithm(_:)`
  - `baseKeyType(fromCertificateKeyType:)`
  - `certificateKeyType(for:)`
- [ ] Change `private func` → `func` on each.
- [ ] Build. Verify `-strict-concurrency=complete` is clean.
- [ ] Commit: `refactor(RefactorFR Phase 18): extract CertificateAuthorityService+CertificateParsing`

### Phase 19 — Extract `CertificateAuthorityService+KRL.swift` & slim

**Goal:** Move KRL-generation helpers into an extension; slim the main file.

**Files to create:** `ProSSHMac/Services/CertificateAuthorityService+KRL.swift`

**Steps:**
- [ ] Create the file. Header: `// Extracted from CertificateAuthorityService.swift`.
- [ ] Move into `extension CertificateAuthorityService`:
  - `generateKRL(request:authorities:certificates:)`
  - `authorizedRepresentation(for:)`
  - `sanitizeFileComponent(_:)`
  - `csvSafe(_:)`
- [ ] Change `private func` → `func` on each.
- [ ] Verify `CertificateAuthorityService.swift` now contains only:
  request structs, error enum, stored properties, `init`, and the five
  core public business methods (`loadAuthorities`, `createAuthority`,
  `loadCertificates`, `signUserCertificate`, `signHostCertificate`,
  `signCertificate` private, `importExternalCertificate`, `deleteAuthorities`).
- [ ] Remove `// swiftlint:disable file_length` if main file is under 400 lines.
- [ ] Run full test suite.
- [ ] Commit: `refactor(RefactorFR Phase 19): extract CertificateAuthorityService+KRL — service slim complete`

---

## Refactor Log

- **2026-02-25 — Phases 10–14 COMPLETE** (commits `0a7ac88`–`e341205`): Decomposed
  `SSHConfigParser.swift` (1,018 → 275 lines) by extracting all four non-parser types into
  separate files: `SSHConfigTokenExpander.swift` (~59L, token expander + Context),
  `SSHConfigMapper.swift` (~440L, full mapping struct with 8 private helpers),
  `SSHConfigExporter.swift` (~128L, exporter + ExportOptions),
  `SSHConfigImportService.swift` (~109L, orchestrator + ImportPreview + findDuplicates extension).
  `// swiftlint:disable file_length` removed from SSHConfigParser.swift (275L < 400L).
  Build: SUCCEEDED after each phase. Tests: 2 pre-existing failures, zero new across all phases.

- **2026-02-25 — Phase 9 COMPLETE** (commit `eeb2ba3`): Extracted 6 read-only query/history
  methods from `SessionManager.swift` into `SessionManager+Queries.swift` (`activeSession`,
  `mostRelevantSession`, `totalTraffic`, `recentCommandBlocks`, `searchCommandHistory`,
  `commandOutput`). File: 1,005 → 969 lines. 400-line target not achievable without a future
  `SessionConnectionCoordinator` extraction. Build: SUCCEEDED. Tests: 2 pre-existing failures,
  zero new.

- **2026-02-25 — Phase 0 COMPLETE** (commit `99ef976`): Created branch `refactor/final-run` from master. Added `// swiftlint:disable file_length` as line 1 of `OpenAIResponsesService.swift`. Build baseline: BUILD SUCCEEDED, 0 warnings. Phase 1 is NOT STARTED.

---

## Target Line Counts After All Phases

| File | Current | Target |
|------|---------|--------|
| `OpenAIResponsesService.swift` | 1,305 | ~250 (class only) |
| `OpenAIResponsesTypes.swift` | — | ~270 |
| `OpenAIResponsesPayloadTypes.swift` | — | ~80 |
| `OpenAIResponsesStreamAccumulator.swift` | — | ~290 |
| `OpenAIResponsesService+Streaming.swift` | — | ~350 |
| `SessionManager.swift` | 1,196 | ~400 (lifecycle only) |
| `SessionSFTPCoordinator.swift` | — | ~200 |
| `SessionAIToolCoordinator.swift` | — | ~120 |
| `SessionShellIOCoordinator.swift` | — | ~180 |
| `SSHConfigParser.swift` | 1,018 | ~290 (parser only) |
| `SSHConfigTokenExpander.swift` | — | ~70 |
| `SSHConfigMapper.swift` | — | ~440 |
| `SSHConfigExporter.swift` | — | ~130 |
| `SSHConfigImportService.swift` | — | ~110 |
| `CertificateAuthorityService.swift` | 985 | ~300 (core logic) |
| `SSHBinaryReader.swift` | — | ~120 |
| `CertificateAuthorityService+BinaryEncoding.swift` | — | ~90 |
| `CertificateAuthorityService+CertificateParsing.swift` | — | ~190 |
| `CertificateAuthorityService+KRL.swift` | — | ~140 |
