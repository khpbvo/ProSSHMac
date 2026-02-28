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

All work history (refactor logs, feature logs, dated entries) belongs in `docs/featurelist.md`,
not here. CLAUDE.md is working memory only — current state, not history.

---

## Completed Refactors

All major refactors are complete and merged to master. Full specs live in their respective docs.

| Refactor | Phases | Key output | Spec |
|---|---|---|---|
| RefactorTheActor (Strict Concurrency) | 0–8 | `Services/SSH/`, `Services/AI/`, `PersistentStore`, 4 session coordinators | `RefactorTheActor.md` |
| RefactorTerminalView | 0–9 | `UI/Terminal/` split into 11+ components; `TerminalView.swift` → 1,002L | `RefactorTerminalView.md` |
| RefactorTerminalGrid | 0–11 | 11 `TerminalGrid+*.swift` extensions; `TerminalGrid.swift` → 457L | `RefactorTerminalGrid.md` |
| RefactorMetalTerminalRenderer | 0–8 | 8 `MetalTerminalRenderer+*.swift` extensions; `MetalTerminalRenderer.swift` → 331L | `docs/RefactorMetalTerminalRenderer.md` |
| RefactorTheFinalRun | 0–19 | 4 god files decomposed; `SessionManager.swift` → 969L | `docs/RefactorTheFinalRun.md` |

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
- AI `apply_patch` tool: create/update/delete files via V4A diff with user approval flow

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
├── Services/             # SessionManager, TransferManager, EncryptedStorage, PortForwardingManager,
│   ├── SSH/              #   LibSSHTransport, MockSSHTransport, SSHCredentialResolver, RemotePath, etc.
│   └── AI/               #   AIToolHandler, AIAgentRunner, AIToolDefinitions, ApplyPatchTool, etc.
├── Terminal/
│   ├── Grid/             # TerminalGrid + 11 TerminalGrid+*.swift extensions, TerminalCell, ScrollbackBuffer
│   ├── Parser/           # VT parser, CSIHandler, OSCHandler, SGRHandler, ESCHandler, DCSHandler
│   ├── Input/            # KeyEncoder, MouseEncoder, HardwareKeyHandler, PasteHandler
│   ├── Renderer/         # MetalTerminalRenderer + 8 MetalTerminalRenderer+*.swift extensions,
│   │                     #   GlyphAtlas, GlyphCache, CellBuffer, CursorRenderer, Shaders.metal
│   ├── Effects/          # CRT, gradient, scanner, blink, transparency, bell, link detection
│   └── Features/         # PaneManager, SessionTabManager, TerminalSearch, QuickCommands,
│                         #   SessionRecorder, TerminalHistoryIndex, CommandBlock
├── UI/
│   ├── Terminal/         # TerminalView.swift (1,002L), TerminalAIAssistantPane,
│   │                     #   MetalTerminalSessionSurface, + 11 extracted Terminal*.swift components
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
| `ProSSHMac/UI/Terminal/TerminalView.swift` | Main terminal UI, sidebar layout, focus management, input capture | 1,002 lines |
| `ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift` | AI copilot sidebar, composer text view, message rendering | ~781 lines |
| `ProSSHMac/UI/Terminal/PatchApprovalCardView.swift` | Inline patch approval card — diff preview, approve/deny buttons | UI for `apply_patch` |
| `ProSSHMac/UI/Terminal/MetalTerminalSessionSurface.swift` | SwiftUI ↔ Metal bridge, snapshot application, selection | Medium |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer.swift` | Metal infrastructure: init, stored properties, `noGlyphIndex` sentinel | 331 lines |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+GlyphResolution.swift` | Glyph rasterization, atlas upload, font cache, glyph index resolution | |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+SnapshotUpdate.swift` | updateSnapshot, applyPendingSnapshotIfNeeded | |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+FontManagement.swift` | Font metrics init, font change handling, pixel alignment, grid recalc | |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift` | draw(in:), encodeTerminalScenePass — main MTKViewDelegate draw path | |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+ViewConfiguration.swift` | mtkView resize, configureView, FPS control, pause | |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+Selection.swift` | setSelection, clearSelection, selectAll, selectedText, gridCell | |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+PostProcessing.swift` | CRT effect, gradient background, scanner effect, post-process textures | |
| `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+Diagnostics.swift` | cacheHitRate, atlasPageCount, atlasMemoryBytes, cachedGlyphCount, performanceSnapshot | |
| `ProSSHMac/Services/SessionManager.swift` | Session lifecycle, shell I/O, SFTP, grid snapshots, history | 969 lines |
| `ProSSHMac/Services/SessionManager+Queries.swift` | Session query helpers (post-refactor extension) | |
| `ProSSHMac/Services/SessionAIToolCoordinator.swift` | AI tool coordination — execute_and_wait, session context for AI agent | |
| `ProSSHMac/Services/SessionSFTPCoordinator.swift` | SFTP operations extracted from SessionManager | |
| `ProSSHMac/Services/SessionShellIOCoordinator.swift` | Shell I/O coordination extracted from SessionManager | |
| `ProSSHMac/Services/SSH/LibSSHTransport.swift` | LibSSH transport actor, connect/auth/shell/SFTP/forward logic | ~797 lines |
| `ProSSHMac/Services/OpenAIAgentService.swift` | Thin orchestrator: protocols, error types, coordinator wiring | ~172 lines |
| `ProSSHMac/Services/AI/AIToolHandler.swift` | Tool dispatch switch + tool case handlers (`executeSingleToolCall`) | ~503 lines |
| `ProSSHMac/Services/AI/AIToolHandler+ArgumentParsing.swift` | Static argument parsing helpers | ~117 lines |
| `ProSSHMac/Services/AI/AIToolHandler+RemoteExecution.swift` | Remote execution, output parsing, command building | ~421 lines |
| `ProSSHMac/Services/AI/AIToolHandler+LocalFilesystem.swift` | nonisolated static local filesystem methods | ~339 lines |
| `ProSSHMac/Services/AI/AIToolHandler+OutputHelpers.swift` | Output formatting helpers (commandBlockSummary, etc.) | ~123 lines |
| `ProSSHMac/Services/AI/AIToolDefinitions.swift` | Developer prompt, tool schemas, static helpers | ~373 lines |
| `ProSSHMac/Services/AI/AIAgentRunner.swift` | Agent iteration loop, response recovery, timeout | ~187 lines |
| `ProSSHMac/Services/AI/AIConversationContext.swift` | previousResponseID store keyed by session UUID | ~21 lines |
| `ProSSHMac/Services/AI/ApplyPatchTool.swift` | `PatchApprovalTracker`, `LocalWorkspacePatcher`, `RemotePatchCommandBuilder`, tool definition | ~456 lines |
| `ProSSHMac/Services/AI/UnifiedDiffPatcher.swift` | V4A unified diff parser and applicator | ~370 lines |
| `ProSSHMac/Terminal/Grid/TerminalGrid.swift` | Terminal grid state, init, buffer access, grapheme encoding, helpers | 457 lines |
| `ProSSHMac/Terminal/Grid/TerminalGrid+ModeSetters.swift` | Mode flag setters (DEC modes, mouse, charset, SGR) | |
| `ProSSHMac/Terminal/Grid/TerminalGrid+OSCHandlers.swift` | OSC title/color/hyperlink handlers | |
| `ProSSHMac/Terminal/Grid/TerminalGrid+TabsAndDirty.swift` | Tab stops + dirty-row tracking | |
| `ProSSHMac/Terminal/Grid/TerminalGrid+CursorOps.swift` | Cursor movement + cell read/write | |
| `ProSSHMac/Terminal/Grid/TerminalGrid+Scrolling.swift` | Scroll up/down, index, LF, CR, scroll region | |
| `ProSSHMac/Terminal/Grid/TerminalGrid+Erasing.swift` | Erase in line/display, erase characters | |
| `ProSSHMac/Terminal/Grid/TerminalGrid+LineOps.swift` | Insert/delete characters and lines | |
| `ProSSHMac/Terminal/Grid/TerminalGrid+ScreenBuffer.swift` | Alternate screen buffer + cursor save/restore | |
| `ProSSHMac/Terminal/Grid/TerminalGrid+Lifecycle.swift` | Full reset, soft reset, resize, simpleResizeBuffer | |
| `ProSSHMac/Terminal/Grid/TerminalGrid+Printing.swift` | printCharacter, printASCIIBytesBulk, processGroundTextBytes, performWrap | |
| `ProSSHMac/Terminal/Grid/TerminalGrid+Snapshot.swift` | snapshot(), scrollback snapshot, visibleText() | |

---

## Architecture Conventions

- **ObservableObject + @StateObject** is the pattern used throughout (not `@Observable`)
- **Metal rendering** uses `MTKView` with display-link driven frames (`isPaused = false`, `enableSetNeedsDisplay = false`). Dirty flag skips draws when nothing changed.
- **Grid snapshots** flow: `TerminalGrid.snapshot()` → `SessionManager` stores + increments nonce → SwiftUI `.onChange(of: nonce)` → `MetalTerminalRenderer.updateSnapshot()` → `isDirty = true`
- **Terminal keyboard input** goes through `DirectTerminalInputNSView` (transparent NSView overlay, `hitTest` returns `nil`). It captures keys when it's the first responder.
- **Focus management** between terminal and chat sidebar uses `isAIAssistantComposerFocused` state. The `ComposerTextView` (NSTextView) signals focus via callbacks. `focusSessionAndPane()` resigns text inputs and re-arms terminal input.
- **AI service stack**: `OpenAIResponsesService` (HTTP + retry) → `OpenAIAgentService` (tool loop + safety) → `TerminalAIAssistantViewModel` → `TerminalAIAssistantPane`
- **AI agent tools**: 11 tools + `apply_patch`. `execute_and_wait` runs a command and returns output+exit code in one step (marker-based polling). `execute_command` is fire-and-forget for interactive programs. Context persistence via `previousResponseID`. Default max iterations: 50 (app override: 200). Direct action prompts (starting with "run "/"execute "/"cd ") use a restricted tool set with 15-iteration cap.
- **`apply_patch` remote update flow** (Phase 3 fix, 2026-02-27): `buildReadCommand(path:)` (emits `base64 <path>`) → `decodeBase64FileOutput(_:)` (filters output to base64-only lines, decodes UTF-8) → `applyDiff(input:diff:)` (V4A in-process) → `buildWriteCommand(path:content:)` (base64 heredoc write). This replaced `buildRemoteReadFileChunkCommand` (sed) which contaminated `originalContent` with the shell prompt and command echo, causing V4A context matching failures. `V4AParserState` in `apply_diff.swift` uses `nonisolated deinit` to prevent `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` from routing deallocation through `swift_task_deinitOnExecutorImpl` (which crashes in non-task contexts such as XCTest callbacks).
- **`nonisolated` on TerminalGrid extension methods**: `TerminalGrid` is a `nonisolated final class` but `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` causes methods in separate extension files to default to `@MainActor`. All methods in every `TerminalGrid+*.swift` file must be explicitly `nonisolated`.
- **Coordinator pattern for SessionManager**: Responsibilities are extracted into `@MainActor final class` coordinators (`SessionReconnectCoordinator`, `SessionKeepaliveCoordinator`, `TerminalRenderingCoordinator`, `SessionRecordingCoordinator`, `SessionAIToolCoordinator`, `SessionSFTPCoordinator`, `SessionShellIOCoordinator`). Each holds `weak var manager: SessionManager?`.

---

## Known Issues & Gotchas

- **TerminalView.swift** is still the largest UI file (1,002 lines). Read surrounding context carefully before modifying.
- **Focus management** between the AI composer (`NSTextView`) and the terminal (`DirectTerminalInputNSView`) is delicate. The composer must be resigned at the AppKit level (not just SwiftUI state) before the terminal can reclaim first responder. See `focusSessionAndPane()`.
- **SwiftUI state mutations during `updateNSView`** cause warnings and bugs. All NSView bridge callbacks use `DispatchQueue.main.async` or `Task { @MainActor in await Task.yield() }` deferral.
- **SourceKit diagnostics** often show false "Cannot find type" errors because SourceKit can't resolve types across files. The build itself succeeds — always verify with `xcodebuild build`.
- **Bugs doc**: `docs/bugs.md` contains a comprehensive 68-bug audit organized by subsystem/severity. Check it before working on a subsystem.
- **Terminal selection**: `selectedText()` in `MetalTerminalRenderer+Selection.swift` skips wide-char continuation cells (cells following a `CellAttributes.wideChar` cell) to avoid spurious spaces in copied text. Click-to-deselect is handled in `TerminalSurfaceView.swift`'s `onTap` callback. `handleDrag` in `MetalTerminalSessionSurface.swift` processes `.ended`/`.cancelled` phases before the `gridCell(at:)` guard to prevent stale `dragStart`.
- **Test quarantines**: Previously quarantined tests (`PaneManagerTests`, `testClearConversation`) have been fixed via `nonisolated deinit`. `SessionTabManager` and `V4AParserState` (in `apply_diff.swift`) also use `nonisolated deinit`. No active quarantines remain.

---

## Reference Docs

| Doc | Purpose |
|-----|---------|
| `docs/featurelist.md` | **Long-term memory** — dated work log, phase plan, loop log, progress checklist |
| `docs/bugs.md` | 68-bug audit by subsystem and severity |
| `docs/FutureFeatures.md` | Prioritized feature roadmap (competitive analysis) |
| `docs/Optimization.md` | Performance bottleneck analysis and fixes |
| `docs/optimizationspart2.md` | Additional optimization work |
| `docs/RefactorTheFinalRun.md` | Completed refactor spec — 20-phase god file decomposition |
| `docs/RefactorMetalTerminalRenderer.md` | Completed refactor spec — MetalTerminalRenderer (Phases 0–8) |
| `RefactorTerminalGrid.md` | Completed refactor spec — TerminalGrid decomposition (Phases 0–11) |
| `RefactorTerminalView.md` | Completed refactor spec — TerminalView decomposition (Phases 0–9) |
| `RefactorTheActor.md` | Completed refactor spec — Strict Concurrency / actor isolation (Phases 0–8) |
| `AGENTS.md` | Working memory for GPT-based agents (legacy, kept for compatibility) |
