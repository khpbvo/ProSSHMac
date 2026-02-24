# CLAUDE.md — Project Knowledge Base

This file is the general knowledge memory for Claude Code working on ProSSHMac.
It is read automatically at the start of every session.

---

## Long-Term Memory

The long-term memory for this project lives in `docs/featurelist.md`.

**After every code change, you MUST:**
1. Update `docs/featurelist.md` with a dated loop-log entry describing what was changed and why.
2. Update this `CLAUDE.md` file if any architectural knowledge, conventions, known issues, or key file locations changed.
3. Keep both files current — they are the only persistent memory across sessions.

---

## Active Refactor: Strict Concurrency (RefactorTheActor.md)

### ► CURRENT STATE — START HERE

```
Active branch : refactor/actor-isolation
Current phase : Phase 8 — COMPLETE
Phase status  : COMPLETE
Immediate action: All 8 phases done. Consider merging to master.
Last commit   : 816b9be  "test: add unit tests for refactored components (Phase 8)"
```

**Update this block after every phase** — it is the first thing any new agent reads.

---

### Workflow — two states, repeat until Phase 8

Every phase is in one of two states. Know which state you are in before doing anything.

**State A — Phase is NOT PLANNED** (`RefactorTheActor.md` has only the sketch for this phase):
1. Read every source file the phase will touch — understand what is there before moving anything.
2. Expand the sketch into a granular, numbered step-by-step plan directly in `RefactorTheActor.md`:
   every file to create, every symbol to move, every access modifier to change, every build check.
3. Commit the plan: `docs: expand Phase N plan in RefactorTheActor.md`
4. → Phase is now PLANNED. Switch to State B.

**State B — Phase is PLANNED** (`RefactorTheActor.md` has the full numbered steps):
1. Open `RefactorTheActor.md`, find the current phase, read every step before touching any file.
2. Execute each step in order. After each build-check step, verify `** BUILD SUCCEEDED **`.
3. Check off each `[ ]` as you complete it.
4. When all steps are checked: run tests, commit the phase, update CLAUDE.md phase status table
   and "Current State" block above, add a Refactor Log entry below.
5. → Phase is COMPLETE. Move to the next phase (State A if unplanned, State B if already planned).

**Branch:** `refactor/actor-isolation` — already created. All refactor commits go on this branch.

---

### Phase Status

| Phase | Name | Status |
|-------|------|--------|
| 0 | Baseline audit & branch setup | **COMPLETE** (2026-02-24, commit `9913cdc`) |
| 1 | Split `SSHTransport.swift` into `Services/SSH/` | **COMPLETE** (2026-02-24, commit `f2ff073`) |
| 1b | Swift 6 strict concurrency pass on Phase 1 files | **COMPLETE** (2026-02-24, commit `32dcd70`) |
| 2 | Kill CString pyramid, inject credential resolver | **COMPLETE** (2026-02-24, commit `d7d891d`) |
| 3 | Deduplicate remote path utilities → `RemotePath.swift` | **COMPLETE** (2026-02-24, commit `2fcdc50`) |
| 4 | Generic `PersistentStore<T>` for store boilerplate | **COMPLETE** (2026-02-24, commit `35bfcfb`) |
| 5 | Decompose `SessionManager.swift` into 5 coordinators | **COMPLETE** (2026-02-24, commit `0e876c2`) |
| 6 | Decompose `OpenAIAgentService.swift` into `Services/AI/` | **COMPLETE** (2026-02-24, commits `d12e2ca`–`16043ad`) |
| 7 | Strict concurrency pass (`-strict-concurrency=complete`) | **COMPLETE** (2026-02-24, commit `2c90d5b`) |
| 8 | Test coverage backfill for all extracted types | **COMPLETE** (2026-02-24, commit `816b9be`) |

### Target Directory Layout After Phases 1–6

```
Services/
├── SSH/
│   ├── SSHTransportTypes.swift            # value types & enums (Phase 1a)
│   ├── SSHTransportProtocol.swift         # protocols + default extension (Phase 1a)
│   ├── SSHAlgorithmPolicy.swift           # algorithm policy struct (Phase 1a)
│   ├── MockSSHTransport.swift             # #if DEBUG mock actors (Phase 1b)
│   ├── LibSSHShellChannel.swift           # LibSSHShellChannel actor (Phase 1c)
│   ├── LibSSHForwardChannel.swift         # LibSSHForwardChannel actor + auth types (Phase 1c)
│   ├── LibSSHTransport.swift              # renamed from SSHTransport.swift (Phase 1d)
│   ├── SSHCredentialResolver.swift        # SSHCredentialResolving protocol (Phase 2)
│   ├── DefaultSSHCredentialResolver.swift # concrete impl (Phase 2)
│   └── RemotePath.swift                   # deduplicated path utilities (Phase 3)
├── AI/
│   ├── AIToolDefinitions.swift            # caseless enum: developer prompt, tool schemas, static helpers (Phase 6)
│   ├── AIConversationContext.swift        # previousResponseID management (Phase 6)
│   ├── AIToolHandler.swift                # tool dispatch, remote/local execution, output parsing (Phase 6)
│   └── AIAgentRunner.swift                # agent iteration loop (Phase 6)
├── PersistentStore.swift                  # @MainActor final class PersistentStore<T: Codable> (Phase 4)
├── SessionReconnectCoordinator.swift      # extracted from SessionManager (Phase 5a)
├── SessionKeepaliveCoordinator.swift      # extracted from SessionManager (Phase 5b)
├── TerminalRenderingCoordinator.swift     # extracted from SessionManager (Phase 5c)
├── SessionRecordingCoordinator.swift      # extracted from SessionManager (Phase 5d)
├── SessionManager.swift                   # target <300 lines after Phase 5e
├── OpenAIAgentService.swift               # target <300 lines after Phase 6
└── ... (existing files, unchanged)
```

### Non-Negotiable Refactor Rules

1. **Build must pass after every file extraction** — do not proceed to the next extraction until
   `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build` succeeds.
2. **Commit after every phase** — each phase is a self-contained commit on `refactor/actor-isolation`.
3. **Header comment on every extracted file** — first non-blank, non-import line must be:
   `// Extracted from [SourceFileName].swift`
4. **Do NOT enable strict concurrency project-wide until Phase 7** — fix Sendable warnings
   file by file; never add `-strict-concurrency=complete` to the project build settings until
   all extracted files are individually clean.
5. **`// swiftlint:disable file_length`** — add to the three god files in Phase 0; remove from
   each file as soon as it shrinks below 400 lines (not before).
6. **Update `RefactorTheActor.md` before each phase** — write the detailed step-by-step plan for
   the upcoming phase into `RefactorTheActor.md` first, then execute it. Never start coding a phase
   without a fully written plan in the file.
7. **Every new Swift file must pass `-strict-concurrency=complete` before its creating commit** —
   add explicit `Sendable` conformances on all value types; use `@unchecked Sendable` only for
   C-interop types (e.g. `OpaquePointer`) and add a `// safe: <reason>` comment. After making
   the changes, temporarily add `-strict-concurrency=complete` to Other Swift Flags in Xcode,
   build, fix any warnings, then remove the flag before committing.

---

## Active Refactor: TerminalView.swift Decomposition (RefactorTerminalView.md)

### ► CURRENT STATE — START HERE

```
Active branch   : master
Current phase   : Phase 9 — COMPLETE
Phase status    : COMPLETE
Immediate action: All 9 phases done. TerminalView.swift is ~1,002 lines. Refactor complete.
Last commit     : 81975fa "refactor(RefactorTV Phase 9): extract sidebar layout store + keyboard shortcut layer, remove dead code"
```

**Update this block after every phase.**

### Phase Status

| Phase | Name | Status |
|-------|------|--------|
| 0 | Baseline audit | COMPLETE (2026-02-24) |
| 1 | Extract DirectTerminalInputNSView + supporting types | COMPLETE (2026-02-24) |
| 2 | Extract TerminalSessionHeaderView + TerminalSessionMetadataView | COMPLETE (2026-02-24) |
| 3 | Extract TerminalSearchBarView | COMPLETE (2026-02-24) |
| 4 | Extract TerminalSessionActionsBar | COMPLETE (2026-02-24) |
| 5 | Extract TerminalSessionTabBar | COMPLETE (2026-02-24, commit `662c5a2`) |
| 6 | Extract TerminalQuickCommandPanel | COMPLETE (2026-02-24) |
| 7 | Extract TerminalFileBrowserSidebar | COMPLETE (2026-02-24) |
| 8 | Extract TerminalSurfaceView | COMPLETE (2026-02-24) |
| 9 | Extract TerminalSidebarLayoutStore + TerminalKeyboardShortcutLayer + cleanup | **COMPLETE** (2026-02-24, commit `81975fa`) |

**Run-book:** `RefactorTerminalView.md` (project root) — contains the full step-by-step
checklist. Read it before starting any phase.

**New files** all go in `ProSSHMac/UI/Terminal/`. Naming convention: `Terminal<ComponentName>.swift`.
Each starts with `// Extracted from TerminalView.swift` as first non-blank, non-import line.

---

## Active Refactor: TerminalGrid.swift Decomposition (RefactorTerminalGrid.md)

### ► CURRENT STATE — START HERE

```
Active branch   : master
Current phase   : Phase 5 — NOT STARTED
Phase status    : NOT STARTED
Immediate action: Begin Phase 5 (extract Scrolling → TerminalGrid+Scrolling.swift).
Last commit     : 5ce0ae4 "refactor(RefactorTG Phase 4): extract Cursor Movement + Cell R/W to TerminalGrid+CursorOps.swift"
```

**Update this block after every phase.**

### Phase Status

| Phase | Name | Status |
|-------|------|--------|
| 0 | Baseline — swiftlint:disable + internal access | **COMPLETE** (2026-02-24) |
| 1 | Extract Mode Setters → `TerminalGrid+ModeSetters.swift` | **COMPLETE** (2026-02-24) |
| 2 | Extract OSC Handlers → `TerminalGrid+OSCHandlers.swift` | **COMPLETE** (2026-02-24) |
| 3 | Extract Tab Stops + Dirty Tracking → `TerminalGrid+TabsAndDirty.swift` | **COMPLETE** (2026-02-25) |
| 4 | Extract Cursor Movement + Cell R/W → `TerminalGrid+CursorOps.swift` | **COMPLETE** (2026-02-25) |
| 5 | Extract Scrolling → `TerminalGrid+Scrolling.swift` | NOT STARTED |
| 6 | Extract Erasing → `TerminalGrid+Erasing.swift` | NOT STARTED |
| 7 | Extract Line Operations → `TerminalGrid+LineOps.swift` | NOT STARTED |
| 8 | Extract Screen Buffer + Cursor Save/Restore → `TerminalGrid+ScreenBuffer.swift` | NOT STARTED |
| 9 | Extract Lifecycle (Full Reset + Resize) → `TerminalGrid+Lifecycle.swift` | NOT STARTED |
| 10 | Extract Print Character → `TerminalGrid+Printing.swift` | NOT STARTED |
| 11 | Extract Snapshot + Text Extraction → `TerminalGrid+Snapshot.swift` | NOT STARTED |

**Run-book:** `RefactorTerminalGrid.md` (project root) — contains the full step-by-step checklist.
Read it before starting any phase.

**Key difference from prior refactors:** All extractions use `extension TerminalGrid` (no new types).
Phase 0 changes `private var` / `private func` → internal throughout the class to enable cross-file
extension access. New files go in `ProSSHMac/Terminal/Grid/`. Naming: `TerminalGrid+<Concern>.swift`.
Each file starts with `// Extracted from TerminalGrid.swift`.

**Critical pattern — `nonisolated` on all extension methods:** `TerminalGrid` is a `nonisolated final class`,
but `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` causes extension methods in separate files to default to
`@MainActor` (even though the class itself is `nonisolated`). All methods in every `TerminalGrid+*.swift`
extension file must be explicitly marked `nonisolated`. Discovered in Phase 1.

---

## Project Overview

**ProSSHMac** is a native macOS SSH/terminal client built with SwiftUI + Metal.

Key capabilities:
- Metal-rendered terminal (custom glyph atlas, GPU cell buffer, cursor animation)
- SSH connections via libssh (C wrapper in `CLibSSH/`)
- Local shell sessions via PTY (`LocalShellChannel`)
- SFTP file browser sidebar (left, toggle `Cmd+B`)
- AI Terminal Copilot sidebar (right, toggle `Cmd+Opt+I`) — uses OpenAI Responses API pinned to `gpt-5.1-codex-max`
- Pane splitting, session tabs, session recording/playback
- KeyForge (SSH key generation), certificate management, port forwarding
- Visual effects: CRT scanlines, barrel distortion, gradient glow, matrix screensaver

---

## Build & Test

```bash
# Build
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build

# Run all tests
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test

# Run specific test suite
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test -only-testing:ProSSHMacTests/OpenAIAgentServiceTests
```

- Test bundle: `ProSSHMacTests`
- Most test files are still compiled under app sources (migration to test bundle is ongoing)
- Known: some tests require the host app process; avoid `-disable-main-thread-checker` unless needed

---

## Project Structure

```
ProSSHMac/
├── App/                  # App entry, dependencies, navigation coordinator
├── CLibSSH/              # C wrapper around libssh (ProSSHLibSSHWrapper.c/.h)
├── Models/               # Host, Session, Transfer, SSHKey, SSHCertificate, AuditLogEntry
├── Services/             # SessionManager, SSHTransport, TransferManager, EncryptedStorage,
│                         #   PortForwardingManager, KeyStore, CertificateStore, OpenAI services
│                         #   (SSH/ and AI/ subdirs will be created during the refactor)
├── Terminal/
│   ├── Grid/             # TerminalGrid, TerminalCell, ScrollbackBuffer, GridReflow, GridSnapshot
│   ├── Parser/           # VT parser, CSIHandler, OSCHandler, SGRHandler, ESCHandler, DCSHandler
│   ├── Input/            # KeyEncoder, MouseEncoder, HardwareKeyHandler, PasteHandler
│   ├── Renderer/         # MetalTerminalRenderer, GlyphAtlas, GlyphCache, CellBuffer,
│   │                     #   CursorRenderer, SelectionRenderer, FontManager, Shaders.metal
│   ├── Effects/          # CRT, gradient, scanner, blink, transparency, bell, link detection
│   └── Features/         # PaneManager, SessionTabManager, TerminalSearch, QuickCommands,
│                         #   SessionRecorder, TerminalHistoryIndex, CommandBlock
├── UI/
│   ├── Terminal/         # TerminalView.swift (~3400 lines, main terminal UI),
│   │                     #   TerminalAIAssistantPane, MetalTerminalSessionSurface,
│   │                     #   SplitNodeView, PaneDividerView
│   ├── Hosts/            # HostsView, HostFormView
│   ├── Transfers/        # TransfersView
│   ├── Settings/         # SettingsView + effect settings subviews
│   ├── KeyForge/         # KeyForgeView, KeyInspectorView
│   └── Certificates/     # CertificatesView, CertificateInspectorView
├── ViewModels/           # HostListViewModel, KeyForgeViewModel, CertificatesViewModel
└── Platform/             # PlatformCompatibility (macOS/iOS shims)
```

---

## Key Files (most frequently edited)

All paths below are relative to the repo root. Source files live under `ProSSHMac/` (not at root).

| File | What it does | Size / Notes |
|------|-------------|--------------|
| `ProSSHMac/UI/Terminal/TerminalView.swift` | Main terminal UI, sidebar layout, focus management, input capture | ~3,425 lines → target ~1,100 after RefactorTerminalView |
| `ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift` | AI copilot sidebar, composer text view, message rendering | ~781 lines |
| `ProSSHMac/UI/Terminal/MetalTerminalSessionSurface.swift` | SwiftUI ↔ Metal bridge, snapshot application, selection | Medium |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer.swift` | Metal draw loop, cell buffer upload, cursor/selection render | ~1,438 lines |
| `ProSSHMac/Services/SessionManager.swift` | Session lifecycle, shell I/O, SFTP, grid snapshots, history | **1,177 lines** — Phase 5 COMPLETE; 4 coordinators extracted |
| `ProSSHMac/Services/SSH/LibSSHTransport.swift` | LibSSH transport actor, connect/auth/shell/SFTP/forward logic | ~797 lines — Phase 1 COMPLETE |
| `ProSSHMac/Services/OpenAIAgentService.swift` | Thin orchestrator: protocols, error types, coordinator wiring | **~108 lines — Phase 6 COMPLETE** |
| `ProSSHMac/Services/AI/AIToolHandler.swift` | Tool dispatch + 11 tool implementations (local + remote) | ~1,406 lines |
| `ProSSHMac/Services/AI/AIToolDefinitions.swift` | Developer prompt, 11 tool schemas, static helpers | ~373 lines |
| `ProSSHMac/Services/AI/AIAgentRunner.swift` | Agent iteration loop, response recovery, timeout | ~187 lines |
| `ProSSHMac/Services/AI/AIConversationContext.swift` | previousResponseID store keyed by session UUID | ~21 lines |
| `ProSSHMac/Terminal/Grid/TerminalGrid.swift` | Terminal grid state, character printing, scrolling, resize/reflow | ~2,311 lines |

---

## Architecture Conventions

- **ObservableObject + @StateObject** is the pattern used throughout (not `@Observable`)
- **Metal rendering** uses `MTKView` with display-link driven frames (`isPaused = false`, `enableSetNeedsDisplay = false`). Dirty flag skips draws when nothing changed.
- **Grid snapshots** flow: `TerminalGrid.snapshot()` → `SessionManager` stores + increments nonce → SwiftUI `.onChange(of: nonce)` → `MetalTerminalRenderer.updateSnapshot()` → `isDirty = true`
- **Terminal keyboard input** goes through `DirectTerminalInputNSView` (transparent NSView overlay, `hitTest` returns `nil`). It captures keys when it's the first responder.
- **Focus management** between terminal and chat sidebar uses `isAIAssistantComposerFocused` state. The `ComposerTextView` (NSTextView) signals focus via callbacks. `focusSessionAndPane()` resigns text inputs and re-arms terminal input.
- **AI service stack**: `OpenAIResponsesService` (HTTP + retry) → `OpenAIAgentService` (tool loop + safety) → `TerminalAIAssistantViewModel` → `TerminalAIAssistantPane`
- **AI agent tools**: 11 tools total. `execute_and_wait` runs a command and returns output+exit code in one step (marker-based polling in `SessionManager.executeCommandAndWait`). `execute_command` is fire-and-forget for interactive programs. Context persistence is enabled — the AI remembers prior turns via `previousResponseID`. Default max iterations: 50 (app override: 200). Direct action prompts (starting with "run "/"execute "/"cd ") use a restricted 6-tool set with 15-iteration cap.

---

## Known Issues & Gotchas

- **TerminalView.swift** is very large (~3,425 lines). Be careful with edits — read surrounding context before modifying.
- **Focus management** between the AI composer (`NSTextView`) and the terminal (`DirectTerminalInputNSView`) is delicate. The composer must be resigned at the AppKit level (not just SwiftUI state) before the terminal can reclaim first responder. See `focusSessionAndPane()`.
- **SwiftUI state mutations during `updateNSView`** cause warnings and bugs. All NSView bridge callbacks use `DispatchQueue.main.async` or `Task { @MainActor in await Task.yield() }` deferral.
- **SourceKit diagnostics** for `TerminalView.swift` often show false "Cannot find type" errors because SourceKit can't resolve types from other files in the project. The build itself succeeds fine — always verify with `xcodebuild build`.
- **Bugs doc**: `docs/bugs.md` contains a comprehensive 68-bug audit organized by subsystem/severity. Check it before working on a subsystem.
- **Test quarantines**: Previously quarantined tests (`PaneManagerTests`, `testClearConversation`) have been fixed via `nonisolated deinit`. `SessionTabManager` also uses `nonisolated deinit` for the same reason. No active quarantines remain.

### Refactor-Specific Gotchas

- **`Services/` is currently flat** — there are no `SSH/` or `AI/` subdirectories. These must be
  created on disk AND the new files must be added to the Xcode target in `ProSSHMac.xcodeproj`.
  Files created only on disk (without being added to the Xcode project) will not be compiled and
  the build will fail with confusing "missing symbol" errors in the source files still referencing
  the extracted types. Phase 1 creates `Services/SSH/`; Phase 6 creates `Services/AI/`.
- **Every extracted file must start with** `// Extracted from [SourceFileName].swift`
  as its first non-blank, non-import line. This is the audit trail for the refactor.
- **Do NOT enable strict concurrency project-wide during Phases 1–6.** Only add
  `-strict-concurrency=targeted` to individual new files for local verification. Adding it globally
  before Phase 7 will produce hundreds of unrelated warnings that block the build in unrelated files.
- **`// swiftlint:disable file_length`** must be added to `SSHTransport.swift`,
  `SessionManager.swift`, and `OpenAIAgentService.swift` at the start of Phase 0. Remove it from
  each file only after that file has been reduced to below 400 lines — not before, to avoid
  lint-blocked commits during the intermediate extraction steps.
- **`WARNINGS_BASELINE.txt`** is a scratch file (do NOT commit it). Create it in Phase 0 by
  recording the pre-refactor build warning count. Delete it when Phase 8 is complete.
- **`MockSSHTransport`** currently lives inside `SSHTransport.swift`. After Phase 1b it moves to
  `Services/SSH/MockSSHTransport.swift` wrapped in `#if DEBUG`. The mock is used by
  `SessionManager` when `SSHBackendKind == .mock` — update all references after the move.
- **`SessionManager` has no `// MARK:` sections** for reconnect or keepalive logic. Read the full
  file before starting Phase 5. The keepalive code is near line 1,429 and PTY resize near line 617.

---

## Recent Changes

### Refactor Log (strict concurrency refactor — most recent first)

- **2026-02-24 — Phase 8 COMPLETE** (commit `816b9be`, plan commit: `c5d3ded`): Added 8 test files
  covering all Phase 1–6 extracted types. New test classes: `RemotePathTests` (15 cases — normalize,
  parent, join), `AIConversationContextTests` (7 cases — CRUD on session response IDs),
  `PersistentStoreTests` (6 cases — Host + StoredSSHKey round-trips via EncryptedStorage/Keychain),
  `AIToolDefinitionsTests` (9 cases — static helpers, isDirectActionPrompt, shortTraceID),
  `MockSSHTransportTests` (5 cases — connect/auth/disconnect/sessionNotFound/listDirectory),
  `SessionReconnectCoordinatorTests` (5 cases — pending hosts, scheduleReconnect, cancelPending),
  `SessionKeepaliveCoordinatorTests` (4 cases — task lifecycle with UserDefaults toggle),
  `LibSSHJumpCallParamsTests` (5 cases — LibSSHTargetParams + LibSSHJumpCallParams construction;
  required widening LibSSHAuthenticationMaterial/LibSSHTargetParams/LibSSHJumpCallParams from
  private → internal). Skipped DefaultSSHCredentialResolver (no filesystem injection point).
  AIResponseStreamParser sketch item invalid — file doesn't exist; substituted with
  AIToolDefinitionsTests. Build: SUCCEEDED. Tests: 13 failures (all pre-existing —
  color/mouse/emoji/Base32Tests). Refactor complete — all 8 phases done.

- **2026-02-24 — Phase 7 COMPLETE** (commit `2c90d5b`, plan commit: `dbdb216`): Verified app
  target already fully strict-concurrency clean under Swift 6 + SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor (0 warnings with -strict-concurrency=complete, no source changes). Updated test
  target (ProSSHMacTests) build configs AB100009 + AB10000A: SWIFT_STRICT_CONCURRENCY minimal →
  complete; added SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor to match app target's isolation model.
  Committed two previously-untracked files (SSHConfigParser.swift + SSHConfigParserTests.swift)
  that were blocking test bundle compilation. Build settings change alone resolved all actor
  isolation errors — no @MainActor annotation needed on SSHConfigParserTests class.
  Deleted WARNINGS_BASELINE.txt (Phase 0 scratch file, gitignored). Build: SUCCEEDED.
  Tests: 12 pre-existing failures (within ≤23 baseline). Phase 8 is NOT PLANNED.

- **2026-02-24 — Phase 6 COMPLETE** (commits `d12e2ca`–`16043ad`, plan commit: `4fbc3a9`): Decomposed
  `OpenAIAgentService.swift` (1,946→108 lines) into four `@MainActor final class` coordinators under
  `ProSSHMac/Services/AI/` using the same weak-reference coordinator pattern as Phase 5.
  Created: `AIToolDefinitions` (caseless `enum`, ~373L — developer prompt, 11 tool schemas, 8 static
  helpers; caseless enum prevents Swift 6 `@MainActor` inference on statics); `AIConversationContext`
  (~21L — `previousResponseIDBySessionID: [UUID: String]` with `responseID(for:)`, `update(responseID:for:)`,
  `clear(sessionID:)` methods); `AIToolHandler` (~1,406L — `executeToolCalls`, 11 `handle*` tool
  implementations, `nonisolated static` local filesystem methods, remote tool execution via
  `sessionProvider` extracted from `service?` at dispatch entry point); `AIAgentRunner` (~187L —
  `run(sessionID:prompt:)` agent loop, `createResponseWithRecovery(request:previousResponseID:traceID:)`,
  `runWithTimeout(timeoutSeconds:operation:)` with explicit timeout parameter).
  Key corrections vs. plan sketch: `AIResponseStreamParser.swift` → `AIToolDefinitions.swift` (no
  SSE streaming in `OpenAIAgentService`); `nonisolated static` filesystem methods stay on
  `AIToolHandler` (not moved to separate file); `runWithTimeout` takes explicit `timeoutSeconds: Int`
  parameter (coordinator accesses `service?.requestTimeoutSeconds` and passes in). OpenAIAgentService
  `private let` properties widened to `let` (internal) so coordinators can access via `service?`.
  Build: SUCCEEDED. Strict concurrency: zero warnings with `-strict-concurrency=complete`. Pre-existing
  test build failure in `SSHConfigParserTests.swift` (actor isolation errors, unrelated to Phase 6).
  Phase 7 is NOT PLANNED.

- **2026-02-24 — Phase 5 COMPLETE** (`0e876c2`, plan commit: `597c147`): Decomposed
  `SessionManager.swift` (1,640→1,177 lines) into four `@MainActor final class` coordinators using
  the weak-reference coordinator pattern. Each coordinator holds `weak var manager: SessionManager?`
  and writes `@Published` properties via the manager reference (no delegate protocols needed).
  Created: `SessionReconnectCoordinator` (~60L, owns NWPathMonitor + reconnect logic);
  `SessionKeepaliveCoordinator` (~60L, owns keepalive task + UserDefaults reads);
  `TerminalRenderingCoordinator` (~315L, owns grid snapshots, scroll offsets, PTY state, and all
  render-publish pipeline methods); `SessionRecordingCoordinator` (~120L, owns SessionRecorder
  instance + all recording/playback methods). Key corrections vs. plan: coordinator `init()` takes
  no args (two-phase Swift init pattern — manager weak ref set after SessionManager stored
  properties initialize); `nonisolated deinit {}` empty body matches codebase pattern (tasks use
  `[weak self]` and terminate naturally); `NWPathMonitor` is `nonisolated let` so it can be
  cancelled in coordinator's `nonisolated deinit`. SessionManager retains all `@Published`
  properties (SwiftUI observes them via `@EnvironmentObject`) and exposes one-line forwarding
  wrappers for the public API surface. `// swiftlint:disable file_length` retained (1,177L > 400L
  — plan's 300L target unrealistic given remaining SFTP/AI/lifecycle code not yet extracted).
  Build: SUCCEEDED. Tests: 22 pre-existing failures (color rendering + mouse encoding — within
  ≤23 baseline). Phase 6 is NOT PLANNED.

- **2026-02-24 — Phase 4 COMPLETE** (`35bfcfb`, plan commit: `3f6f05e`): Created
  `Services/PersistentStore.swift` — `@MainActor final class PersistentStore<T: Codable>` with
  `load()` / `save()` and four conditional conformance extensions for `HostStoreProtocol`,
  `KeyStoreProtocol`, `CertificateStoreProtocol`, and `CertificateAuthorityStoreProtocol`. Deleted
  `FileHostStore` (HostStore.swift −49L), `FileKeyStore` (KeyStore.swift −46L),
  `FileCertificateStore` (CertificateStore.swift −48L), `FileCertificateAuthorityStore`
  (CertificateAuthorityStore.swift −48L). Updated 4 instantiation sites in `AppDependencies.swift`.
  Sketch corrections: used `@MainActor final class` (not `actor`) to directly satisfy all four
  `@MainActor` protocols without bridging; dropped `upsert`/`delete` (no call site uses per-item
  operations); dropped `Identifiable` constraint (bulk array serialization only); left
  `AuditLogStore`, `KnownHostsStore`, and Keychain-backed stores untouched (incompatible designs).
  Build: SUCCEEDED. Tests: 186 tests, 2 pre-existing failures (within ≤23 baseline). Phase 5
  is NOT PLANNED.

- **2026-02-24 — Phase 3 COMPLETE** (`2fcdc50`, plan commit: `1cad47a`): Created
  `Services/SSH/RemotePath.swift` with `normalize(_:)`, `parent(of:)`, and `join(_:_:)` static
  methods. All three marked `nonisolated` (Swift 6 infers `@MainActor` on enum static methods in
  this module — same pattern observed in Phase 2). Replaced 4 call sites in `LibSSHTransport` and
  7 call sites in `MockSSHTransport`; deleted 14-line `normalizeRemotePath` from LibSSHTransport
  and 33-line block of 3 methods from MockSSHTransport. `TransferManager.swift` left untouched
  (different `normalizeRemotePath` impl with `..` resolution, different return type for parent).
  Build: SUCCEEDED. Tests: 186 tests, 2 pre-existing failures (within ≤23 baseline). Phase 4
  is NOT PLANNED.
- **2026-02-24 — Phase 2 COMPLETE** (`d7d891d`, Phase 2a: `334afc4`): Extracted 6 credential-loading
  helpers from `LibSSHTransport` into `DefaultSSHCredentialResolver` (implementing new
  `SSHCredentialResolving` protocol). Injected resolver via `init(credentialResolver:)` with
  `DefaultSSHCredentialResolver()` default. Dropped `nonisolated` from `resolveAuthenticationMaterial`.
  Added `LibSSHTargetParams` and `LibSSHJumpCallParams` file-scope structs; replaced the 140-line
  18-level `withCString` pyramid in `connectViaJumpHost` with a clean 40-line body.
  Key correction vs plan: Swift 6 infers `@MainActor` on file-scope struct methods and protocol
  declarations in this module — all affected methods required explicit `nonisolated` annotation.
  `Int32(errorBuffer.count)` cast was wrong direction; C function takes `Int`. Build: SUCCEEDED.
  Tests: 186 tests, 2 pre-existing failures (emoji rendering — within ≤23 baseline).
  Phase 3 is NOT PLANNED.
- **2026-02-24 — Phase 1b COMPLETE** (`32dcd70`): Added explicit Sendable conformances to
  Host, AuthMethod, AlgorithmPreferences, PortForwardingRule (Models/Host.swift);
  SSHBackendKind, SSHTransportError (SSHTransportTypes.swift); SSHAlgorithmPolicy
  (SSHAlgorithmPolicy.swift); LibSSHConnectFailure, LibSSHAuthenticationMaterial
  (LibSSHTransport.swift). LibSSHConnectResult annotated @unchecked Sendable with safety comment
  (holds OpaquePointer owned exclusively by actor-isolated handles dict). All Phase 1 files now
  pass -strict-concurrency=complete with zero warnings. Build: SUCCEEDED. Tests: 186 tests,
  2 pre-existing failures (emoji rendering — within ≤23 baseline). Phase 2 is NOT PLANNED.
- **2026-02-24 — Phase 1 COMPLETE** (`f2ff073`): Split SSHTransport.swift (1,653L) into 6 files
  under Services/SSH/. Key corrections vs. original plan: removed xcodeproj registration steps
  (project uses PBXFileSystemSynchronizedRootGroup file-system sync); added #if DEBUG guard to
  AppDependencies.swift line 46 (MockSSHTransport now DEBUG-only); kept swiftlint:disable in
  LibSSHTransport.swift (~797L) and MockSSHTransport.swift (~466L); kept Array<CChar>.asString
  private in LibSSHTransport.swift (conflict with KeyForgeService.swift's private copy) and added
  private copies to LibSSHShellChannel.swift and LibSSHForwardChannel.swift instead; made
  extension AuthMethod non-private (no conflict). Build: SUCCEEDED. Tests: 22 failures (all
  pre-existing color rendering — within ≤23 baseline). Phase 2 is NOT PLANNED.
- **2026-02-24 — Phase 1 PLANNED** (`97a602b`): Expanded Phase 1 from a 4-bullet sketch into a
  17-step execution plan based on reading `SSHTransport.swift` in full. Key corrections captured:
  `UncheckedOpaquePointer` → `SSHTransportTypes.swift` (used by LibSSH actors, not just Mock);
  `LibSSHConnectResult/Failure/AuthMaterial` stay in `LibSSHTransport.swift`; mock branch in
  `SSHTransportFactory` needs `#if DEBUG` guard; `private extension AuthMethod` and
  `private extension Array<CChar>` lose `private` keyword so LibSSHShellChannel/ForwardChannel
  can see `asString`. Xcode target registration steps included per sub-phase.
- **2026-02-24 — Phase 0 COMPLETE** (`9913cdc`): Branch `refactor/actor-isolation` created.
  Build baseline: 0 warnings, BUILD SUCCEEDED. Test baseline: 861 tests, 23 pre-existing failures
  (color rendering + mouse encoding, unrelated to refactor). `// swiftlint:disable file_length`
  added to all three god files as line 1. `WARNINGS_BASELINE.txt` created and gitignored.
- **2026-02-24 — Refactor established**: `RefactorTheActor.md` added as 8-phase spec. Workflow
  defined: expand phase plan in `RefactorTheActor.md` → execute → commit → repeat. Each phase gets
  a full granular plan before any code is touched. `Services/` is flat (no subdirs yet). God file
  sizes at start: SSHTransport=1,652L, SessionManager=1,639L, OpenAIAgentService=1,945L.

### Feature Log (non-refactor changes — most recent first)

- **2026-02-24**: Integrated TOTP 2FA module and SSH Config Import/Export pipeline.
  - `Host` model gains `totpConfiguration: TOTPConfiguration?` (Codable, persisted in `hosts.json`).
  - `BiometricPasswordStore` conforms to `SecretStorageProtocol` via raw-Keychain helpers (no biometric gate, `kSecAttrAccessibleAfterFirstUnlock`). `TOTPStore` initialised in `AppDependencies`, injected into `SessionManager` + `HostListViewModel`.
  - `SessionManager.connect()` auto-fills TOTP before `transport.authenticate()` when `authMethod == .keyboardInteractive` and `totpConfiguration != nil`; uses `generateSmartCode` to avoid near-expiry codes; logs to audit log.
  - C kbdint loop in `ProSSHLibSSHWrapper.c` now sends TOTP code as answer to prompt[0].
  - `HostFormView` has new "Two-Factor Authentication" section (keyboard-interactive, edit-mode only): `TOTPLiveCodeView` (1s timer, countdown ring) + `TOTPProvisioningSheetView` (URI-paste and manual-entry tabs).
  - `exportSSHConfig()` upgraded to use `SSHConfigExporter` (full field coverage); `importSSHConfig` replaced with `previewSSHConfigImport` + preview-sheet flow via new `SSHConfigImportPreviewView`.
  - Old `parseSSHConfig()` static helper removed from `HostListViewModel`.
- **2026-02-23**: Fixed terminal focus loss after clicking AI chat composer. `focusSessionAndPane()`
  now calls `window.makeFirstResponder(nil)` to resign the NSTextView before setting SwiftUI state.
- **2026-02-23**: Implemented Shell Integration / Device Type configuration. Per-host
  `ShellIntegrationType` stored in `ShellIntegrationConfig`. OSC 133 injection for Unix shells.
  New file: `ProSSHMac/Terminal/Features/ShellIntegrationScripts.swift`.
- **2026-02-23**: Fixed invisible text after TUI programs exit. `disableAlternateBuffer()` resets
  SGR to defaults. Metal shader minimum-contrast safety net added.
- **2026-02-23**: Transformed AI copilot into autonomous terminal agent. Added `execute_and_wait`
  tool. Raised iteration limits, increased output caps. All 14 agent tests pass.

---

## Reference Docs

| Doc | Purpose |
|-----|---------|
| `RefactorTerminalGrid.md` | **Active refactor spec & run-book** — 12-phase plan to decompose `TerminalGrid.swift` (2,311 lines) into `extension TerminalGrid` files in `Terminal/Grid/` |
| `RefactorTheActor.md` | Completed refactor spec (actor isolation, Phases 0–8) |
| `docs/featurelist.md` | **Long-term memory** — phase plan, loop log, progress checklist |
| `docs/bugs.md` | 68-bug audit by subsystem and severity |
| `docs/FutureFeatures.md` | Prioritized feature roadmap (competitive analysis) |
| `docs/Optimization.md` | Performance bottleneck analysis and fixes |
| `docs/optimizationspart2.md` | Additional optimization work |
| `AGENTS.md` | Working memory for GPT-based agents (legacy, kept for compatibility) |
