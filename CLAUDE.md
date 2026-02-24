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
Current phase : Phase 2 — Kill CString pyramid, inject credential resolver
Phase status  : NOT PLANNED
Immediate action: Open RefactorTheActor.md → Phase 2 → expand sketch into detailed plan (State A)
Key source file : ProSSHMac/Services/SSH/LibSSHTransport.swift  (~797 lines)
Last commit   : 32dcd70  "chore: Phase 1b — Swift 6 strict concurrency pass on Phase 1 files"
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
| 2 | Kill CString pyramid, inject credential resolver | NOT PLANNED |
| 3 | Deduplicate remote path utilities → `RemotePath.swift` | NOT PLANNED |
| 4 | Generic `PersistentStore<T>` for store boilerplate | NOT PLANNED |
| 5 | Decompose `SessionManager.swift` into 5 coordinators | NOT PLANNED |
| 6 | Decompose `OpenAIAgentService.swift` into `Services/AI/` | NOT PLANNED |
| 7 | Strict concurrency pass (`-strict-concurrency=complete`) | NOT PLANNED |
| 8 | Test coverage backfill for all extracted types | NOT PLANNED |

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
│   ├── AIToolHandler.swift                # AIToolHandling protocol + concrete handlers (Phase 6)
│   ├── AIConversationContext.swift        # conversation history management (Phase 6)
│   ├── AIResponseStreamParser.swift       # SSE / streaming response parsing (Phase 6)
│   └── AIAgentRunner.swift                # agent loop (Phase 6)
├── PersistentStore.swift                  # generic actor<T: Codable & Identifiable> (Phase 4)
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
| `ProSSHMac/UI/Terminal/TerminalView.swift` | Main terminal UI, sidebar layout, focus management, input capture | ~3,425 lines |
| `ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift` | AI copilot sidebar, composer text view, message rendering | ~781 lines |
| `ProSSHMac/UI/Terminal/MetalTerminalSessionSurface.swift` | SwiftUI ↔ Metal bridge, snapshot application, selection | Medium |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer.swift` | Metal draw loop, cell buffer upload, cursor/selection render | ~1,438 lines |
| `ProSSHMac/Services/SessionManager.swift` | Session lifecycle, shell I/O, SFTP, grid snapshots, history | **1,640 lines — being decomposed in Phase 5** |
| `ProSSHMac/Services/SSH/LibSSHTransport.swift` | LibSSH transport actor, connect/auth/shell/SFTP/forward logic | ~797 lines — Phase 1 COMPLETE |
| `ProSSHMac/Services/OpenAIAgentService.swift` | Agent tool loop, tool dispatch, streaming parser, context mgmt | **1,946 lines — being decomposed into `ProSSHMac/Services/AI/` in Phase 6** |
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
| `RefactorTheActor.md` | **Active refactor spec & run-book** — optimized per phase before execution; each phase gets a full step-by-step plan written here before any code is touched |
| `docs/featurelist.md` | **Long-term memory** — phase plan, loop log, progress checklist |
| `docs/bugs.md` | 68-bug audit by subsystem and severity |
| `docs/FutureFeatures.md` | Prioritized feature roadmap (competitive analysis) |
| `docs/Optimization.md` | Performance bottleneck analysis and fixes |
| `docs/optimizationspart2.md` | Additional optimization work |
| `AGENTS.md` | Working memory for GPT-based agents (legacy, kept for compatibility) |
