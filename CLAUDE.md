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

**Effort:** Separate concerns, eliminate god files, establish clean actor isolation boundaries so
Swift strict concurrency (`-strict-concurrency=complete`) can be enabled incrementally.

**Spec & execution guide:** `RefactorTheActor.md` — this file WILL be fully optimized before
any code work begins. Every phase and every step will be expanded into a granular, numbered
step-by-step guide that can be executed mechanically. After optimization it serves as both the
spec and the run-book.

**Workflow (plan → refactor → repeat):**
1. For the next phase, update `RefactorTheActor.md` with a detailed, step-by-step execution plan
   for that phase — every file creation, every symbol move, every build verification, in order.
2. Execute the refactor by following those steps exactly, one at a time.
3. Commit the completed phase, then return to step 1 for the next phase.

**Branch:** `refactor/actor-isolation` — create it with `git checkout -b refactor/actor-isolation`
before starting Phase 0. All refactor commits go on this branch.

### Phase Status (as of 2026-02-24)

| Phase | Name | Status |
|-------|------|--------|
| 0 | Baseline audit & branch setup | NOT STARTED |
| 1 | Split `SSHTransport.swift` into `Services/SSH/` | NOT STARTED |
| 2 | Kill CString pyramid, inject credential resolver | NOT STARTED |
| 3 | Deduplicate remote path utilities → `RemotePath.swift` | NOT STARTED |
| 4 | Generic `PersistentStore<T>` for store boilerplate | NOT STARTED |
| 5 | Decompose `SessionManager.swift` into 5 coordinators | NOT STARTED |
| 6 | Decompose `OpenAIAgentService.swift` into `Services/AI/` | NOT STARTED |
| 7 | Strict concurrency pass (`-strict-concurrency=complete`) | NOT STARTED |
| 8 | Test coverage backfill for all extracted types | NOT STARTED |

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

| File | What it does | Size / Notes |
|------|-------------|--------------|
| `UI/Terminal/TerminalView.swift` | Main terminal UI, sidebar layout, focus management, input capture | ~3,425 lines |
| `UI/Terminal/TerminalAIAssistantPane.swift` | AI copilot sidebar, composer text view, message rendering | ~781 lines |
| `UI/Terminal/MetalTerminalSessionSurface.swift` | SwiftUI ↔ Metal bridge, snapshot application, selection | Medium |
| `Terminal/Renderer/MetalTerminalRenderer.swift` | Metal draw loop, cell buffer upload, cursor/selection render | ~1,438 lines |
| `Services/SessionManager.swift` | Session lifecycle, shell I/O, SFTP, grid snapshots, history | **1,639 lines — being decomposed in Phase 5** |
| `Services/SSHTransport.swift` | All SSH transport types, protocols, mock actors, LibSSH actors | **1,652 lines — being split into `Services/SSH/` in Phase 1** |
| `Services/OpenAIAgentService.swift` | Agent tool loop, tool dispatch, streaming parser, context mgmt | **1,945 lines — being decomposed into `Services/AI/` in Phase 6** |
| `Terminal/Grid/TerminalGrid.swift` | Terminal grid state, character printing, scrolling, resize/reflow | ~2,311 lines |

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

## Recent Changes (Session Log)

- **2026-02-24**: Established the Strict Concurrency Refactor plan. `RefactorTheActor.md` added to
  repo root as the 8-phase spec. `CLAUDE.md` updated to reflect refactor phase status, rules, and
  the plan→refactor→plan workflow. `RefactorTheActor.md` WILL be edited: each phase gets a full
  step-by-step execution plan written into it before any code is touched for that phase. No code
  has been changed yet — next step is to fully expand Phase 0 in `RefactorTheActor.md`, then
  execute it. Current state: `Services/` is flat (no `SSH/` or `AI/` subdirs), all three god files
  are untouched (SSHTransport.swift = 1,652L, SessionManager.swift = 1,639L,
  OpenAIAgentService.swift = 1,945L), `refactor/actor-isolation` branch does not exist yet.
- **2026-02-23**: Fixed terminal focus loss after clicking AI chat composer. Root cause: clicking the chat input made the `ComposerTextView` first responder, but clicking back on the terminal couldn't reclaim focus because `armForKeyboardInputIfNeeded()` bailed out when `isTextInputFocused` detected the still-active NSTextView. Fix: `focusSessionAndPane()` now explicitly calls `window.makeFirstResponder(nil)` to resign any active NSTextView before setting SwiftUI state, allowing the normal `armForKeyboardInputIfNeeded()` path to succeed.
- **2026-02-23**: Implemented Shell Integration / Device Type configuration. Per-host `ShellIntegrationType` (none, zsh/bash/fish/posixSh, 8 network vendors, custom regex) stored in `ShellIntegrationConfig` on `Host`. UI picker in `HostFormView`. `ShellIntegrationScripts` provides OSC 133 injection for Unix shells (zsh precmd/preexec, bash PROMPT_COMMAND/DEBUG, fish events, POSIX sh PS1 wrapping). Vendor types use regex prompt detection in `TerminalHistoryIndex.looksLikePrompt()`. Local shells inject via overlay rc files; SSH sessions inject via post-connect raw input with 500ms delay. Key new file: `Terminal/Features/ShellIntegrationScripts.swift`.
- **2026-02-23**: Fixed invisible text after TUI programs exit. `disableAlternateBuffer()` now resets SGR attributes to defaults instead of restoring saved (potentially corrupted) colors. Metal shader now has a minimum-contrast safety net: if both fg and bg luminance < 0.06, fg is replaced with white (skipped when `hidden` attribute is set).
- **2026-02-23**: Transformed AI copilot into autonomous terminal agent. Added `execute_and_wait` tool (runs command + returns output/exit code in one step). Rewrote system prompt to declare full terminal control, encourage multi-step reasoning, remove artificial limits. Enabled context persistence. Raised iteration limits (default 50, direct action 15). Increased output caps (command output 16K, screen 300 lines). Enriched tool descriptions. Narrowed direct action detection. All 14 agent tests pass.

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
