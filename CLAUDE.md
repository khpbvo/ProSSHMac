# CLAUDE.md — Working Memory

Read automatically at every session start. Current state only — no history, no dated entries.

---

## Memory Architecture

| Layer | File | Purpose |
|-------|------|---------|
| **Working memory** | `CLAUDE.md` (this file) | Current state, conventions, key files, gotchas. Read every session. |
| **Long-term log** | `docs/featurelist.md` | Dated work log, phase progress, loop-log entries. Append-only history. |
| **Feature specs** | `docs/<FeatureName>.md` | Per-feature phased checklist with architecture notes. Created at feature start. |

- `CLAUDE.md` holds **what is true now**. Update when architecture, conventions, key files, or gotchas change.
- `docs/featurelist.md` holds **what happened and when**. Every session appends a dated entry.
- Feature specs hold **what to do and how**. Each phase has a `- [ ]` checkbox, checked off when completed.

---

## Workflow

### Starting a New Feature

1. Create `docs/<FeatureName>.md` with:
   - Overview (goal, architecture sketch, affected files)
   - Phased checklist using `- [ ] Phase N: <title>` checkbox format
   - Each phase should be one session's worth of work
2. Add a reference row to the Reference Docs table below.
3. Log the feature start in `docs/featurelist.md` with today's date.

### Session Workflow (one phase per session)

Each Claude Code session implements exactly one phase from a feature spec.

**Start of session:**
1. This file is read automatically — instant project context.
2. Read the feature spec (`docs/<FeatureName>.md`) to find the current unchecked phase.
3. **Plan mode is enabled** before implementation. Design the phase before writing code.
4. Once the plan is confirmed, exit plan mode and implement.

**During session:**
- Work only on the current phase. Do not jump ahead.
- If a phase is too large for one context window, split it into sub-phases in the feature spec.

**End of session — do ALL of these before the final commit:**
1. Build passes and **targeted tests** pass (only test suites relevant to the changed code):
   `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`
   `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test -only-testing:ProSSHMacTests/<TestClassName>`
   Full test suite (`test` without `-only-testing`) is only needed before major releases or cross-cutting refactors.
2. Check off completed phase in `docs/<FeatureName>.md`
3. Append dated entry to `docs/featurelist.md` (what changed, files modified, build/test status)
4. Update this `CLAUDE.md` if architecture, conventions, key files, or gotchas changed
5. Write the **Next Session Plan** block at the bottom of this file
6. Commit all changes (code + docs) in a single commit

### Continuous Workflow Across Sessions

At the bottom of this file is a `<!-- NEXT SESSION PLAN -->` block. Before ending a session,
write a brief plan there for the next session. This gets injected as context when the next
session starts (as the first user message after `/clear`), creating continuity across context windows.

Contents should include:
- Which feature spec and phase to work on next
- Key decisions or context the next session needs
- Any blockers or open questions

### Plan Mode Protocol

Before every implementation phase, plan mode is enabled. The plan should:
- State the phase goal and which feature spec it belongs to
- List files to modify and why
- Identify conventions to respect (check Architecture Conventions and Known Issues below)
- If too large for one session, propose splitting into sub-phases

---

## Project Overview

**ProSSHMac** is a native macOS SSH/terminal client built with SwiftUI + Metal.
Deployment target: macOS 26.0. Swift 6 language mode (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).

Key capabilities:
- Metal-rendered terminal (glyph atlas + cache, GPU cell buffer, cursor animation, smooth scrolling)
- SSH connections via libssh (C wrapper in `CLibSSH/`, vendored libs in `Vendor/`)
- Local shell sessions via PTY (`LocalPTYProcess` + `LocalShellBootstrap`)
- SFTP file browser sidebar (left, toggle `Cmd+B`)
- AI Terminal Copilot sidebar (right, toggle `Cmd+Opt+I`) — multi-provider LLM support
- Pane splitting, session tabs, broadcast input routing (`Cmd+Shift+B`), session recording/playback
- KeyForge (SSH key generation), certificate management + KRL, port forwarding
- TOTP 2FA (`TOTPStore`/`TOTPGenerator`), biometric password store, Secure Enclave keys
- `~/.ssh/config` import/export, Spotlight host indexing, App Intents / Shortcuts
- Shell integration (command blocks, history index, prompt marks)
- Visual effects: CRT scanlines, barrel distortion, gradient glow, bloom/text glow,
  bold-text color, scanner, transparency, bell, matrix + idle screensaver
- AI tools: `apply_patch` (V4A diff), `send_input` (interactive prompts), broadcast-aware execution

---

## Build & Test

```bash
# Build
xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build

# Run all tests
xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' test

# Run specific test suite
xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' test \
  -only-testing:ProSSHMacTests/<TestClassName>

# Throughput benchmarks
# Defaults to Debug. Pass --configuration Release for numbers that reflect a shipping build.
./scripts/benchmark-throughput.sh --configuration Release --benchmark-bytes 2097152 --benchmark-runs 4 --benchmark-chunk 4096
./scripts/benchmark-throughput.sh --configuration Release --no-build --pty-local --benchmark-bytes 2097152 --benchmark-runs 4
./scripts/benchmark-ssh.sh --host <hostname> --user <username>
```

- Test bundle: `ProSSHMacTests` — 4 files at the bundle root plus 47 in `ProSSHMacTests/Terminal/Tests/`.
  Migration out of the app target is **complete**; no test sources remain under `ProSSHMac/`.
- Some tests require the host app process (UI/AppKit-backed suites).
- **Full-suite baseline (2026-09-03): 870 tests, 0 failures.** The suite is green — a red run
  means something you touched, not pre-existing noise.
- Tests must not depend on the developer's real `UserDefaults`. `LLMProviderRegistry` takes an
  injectable `userDefaults:`; agent tests build one via `makeIsolatedOpenAIRegistry()` in
  `AIAgentServiceTests.swift`. Follow that pattern for any new defaults-backed type.
- **Throughput baseline (2026-09-03), Release:** **36.38 MB/s** fullscreen, **35.16 MB/s** partial
  scroll (2 MB parser/grid); **17.97 MB/s** PTY-local. Debug: 1.84 / 1.82 / 1.74 MB/s.
  **Release is ~20x faster than Debug** — always state the configuration with any number, and
  never compare a Debug figure to a Release one.
- **Target is no longer 89 MB/s.** That was a pipe baseline with no terminal emulation. Measured
  peers on this machine (6 MB, with rendering): Terminal.app **22.2 MB/s**, iTerm2 **2.44 MB/s**.
  Current target: match or beat Terminal.app end-to-end. See `docs/Optimization.md`.
- **Perf instrumentation:** `TerminalPerf` (`Terminal/Diagnostics/TerminalPerf.swift`) gates the
  five signposts and the in-process stage timers behind `--perf-signposts` /
  `PROSSH_PERF_SIGNPOSTS=1` / `terminal.perf.signposts`. Pass `--perf-signposts` to
  `benchmark-throughput.sh` to print a stage budget. Off by default and verified free.

---

## Project Structure

```
ProSSHMac/
├── ProSSHMacApp.swift    # @main entry, Spotlight indexer wiring
├── ContentView.swift
├── App/                  # AppDependencies, AppNavigationCoordinator, AppAppearance,
│   │                     #   AppLaunchCommandStore, ThroughputBenchmarkRunner
├── AppIntents/           # ProSSHShortcuts (App Intents / Siri Shortcuts)
├── CLibSSH/              # C wrapper around libssh (ProSSHLibSSHWrapper.c/.h, bridging header)
├── Models/               # Host, Session, Transfer, SSHKey, SSHCertificate, AuditLogEntry,
│   │                     #   TOTPConfiguration
├── Services/             # SessionManager (+Queries) + 7 coordinators, TransferManager,
│   │                     #   EncryptedStorage, PersistentStore, PortForwardingManager,
│   │                     #   LocalPTYProcess, LocalShellBootstrap, LocalShellChannel,
│   │                     #   KeyForgeService, KeyStore, KnownHostsStore, CertificateStore,
│   │                     #   CertificateAuthorityService (+3 ext), AuditLogManager/Store,
│   │                     #   TOTPGenerator/Store, BiometricPasswordStore, SecureEnclaveKeyManager,
│   │                     #   HostStore, HostSpotlightIndexer, SSHConfig{Parser,Mapper,Importer,
│   │                     #   Exporter,TokenExpander}, OpenAIAgentService, OpenAIResponses*
│   ├── SSH/              #   LibSSHTransport, LibSSH{Shell,Forward}Channel, MockSSHTransport,
│   │                     #   SSHTransportProtocol/Types, SSHAlgorithmPolicy, SSHCredentialResolver,
│   │                     #   SSHBinaryReader, RemotePath
│   ├── AI/               #   AIToolHandler (+5 ext), AIAgentRunner, AIToolDefinitions,
│   │                     #   AIConversationContext, ApplyPatchTool, UnifiedDiffPatcher, apply_diff
│   └── LLM/              #   LLMTypes, LLMProvider, LLMProviderRegistry, LLMAPIKeyStore
│       └── Providers/    #   ChatCompletionsClient, Mistral/Ollama/Anthropic/DeepSeek providers
├── Terminal/
│   ├── Grid/             # TerminalGrid + 11 extensions, TerminalCell, CursorState, CharacterWidth,
│   │                     #   GridReflow, GridSnapshot, ScrollbackBuffer
│   ├── Parser/           # TerminalEngine, VTParserTables, VTConstants, CSI/OSC/SGR/ESC/DCS/Charset
│   ├── Input/            # KeyEncoder, MouseEncoder, HardwareKeyHandler, LocalTerminalSubsystem,
│   │                     #   InputModeState, PasteHandler, KeyboardToolbar
│   ├── Renderer/         # MetalTerminalRenderer + 8 extensions, TerminalMetalView, CellBuffer,
│   │                     #   GlyphAtlas/Cache/Rasterizer, FontManager, Cursor/SelectionRenderer,
│   │                     #   SmoothScrollEngine, TerminalUniforms, TerminalShaders.metal,
│   │                     #   RendererPerformanceMonitor, RendererStressHarness
│   ├── Effects/          # CRT, gradient, bloom, scanner, cursor, transparency, bell, resize,
│   │                     #   BoldTextColor, SmoothScrollConfiguration, ScrollIndicator,
│   │                     #   LinkDetector, PromptAppearance, Matrix + IdleScreensaver
│   └── Features/         # PaneManager, SplitNode, PaneLayoutStore, SessionTabManager,
│                         #   TerminalSearch, QuickCommands, SessionRecorder, CommandBlock,
│                         #   ShellIntegrationScripts, TerminalHistoryIndex, TerminalFileBrowserTree
├── UI/
│   ├── Terminal/         # 21 files: TerminalView, TerminalSurfaceView, MetalTerminalSessionSurface,
│   │                     #   TerminalPaneView/SplitNodeView/PaneDividerView, TerminalAIAssistantPane,
│   │                     #   PatchApprovalCardView, TerminalFileBrowserSidebar, session tab/header/
│   │                     #   actions/metadata bars, search bar, scrollbar, quick commands,
│   │                     #   TerminalInputCaptureView, ExternalTerminalWindowView, MatrixScreensaverView,
│   │                     #   TerminalKeyboardShortcutLayer, TerminalSidebarLayoutStore
│   ├── Hosts/            # HostsView, HostFormView, PortForwardingRuleEditor, SSHConfigImportPreviewView
│   ├── Transfers/        # TransfersView
│   ├── Settings/         # SettingsView + 8 effect settings subviews
│   ├── KeyForge/         # KeyForgeView, KeyInspectorView
│   └── Certificates/     # CertificatesView, CertificateInspectorView
├── ViewModels/           # HostListVM, KeyForgeVM, CertificatesVM, AIProviderSettingsVM,
│                         #   TerminalAIAssistantVM
└── Platform/             # PlatformCompatibility (macOS/iOS shims)
```

---

## Key Files

All paths relative to repo root, under `ProSSHMac/`. Line counts as of 2026-09-03.

| File / Group | What it does |
|---|---|
| `Services/AI/AIToolHandler.swift` + 5 extensions | Tool dispatch (1,119L) — largest file. Extensions: ArgumentParsing, RemoteExecution, LocalFilesystem, InteractiveInput, OutputHelpers |
| `UI/Terminal/TerminalView.swift` | Main terminal UI, sidebar layout, focus, input capture (1,066L) |
| `Services/SessionManager.swift` + Queries | Session lifecycle, shell I/O, SFTP, grid snapshots (1,017L) |
| `UI/Terminal/TerminalAIAssistantPane.swift` | AI copilot sidebar, composer, message rendering (966L) |
| `Services/TerminalRenderingCoordinator.swift` | Snapshot publishing, scroll state, resize debounce, alt-buffer policy (958L) |
| `Services/SSH/LibSSHTransport.swift` | LibSSH transport actor (822L); channels in `LibSSHShellChannel`/`LibSSHForwardChannel` |
| `Terminal/Parser/TerminalEngine.swift` | VT parser hot path, merged parse/apply loop (733L) |
| `Terminal/Renderer/MetalTerminalRenderer.swift` + 8 extensions | Metal renderer (496L): glyph resolution, snapshot update, font management, draw loop, view config, selection, post-processing, diagnostics |
| `Terminal/Renderer/SmoothScrollEngine.swift` | CPU scroll physics, rubber-band, jumpTo, frame-rate independence |
| `Terminal/Grid/TerminalGrid.swift` + 11 extensions | Grid state (457L): modes, OSC, tabs, cursor, scroll, erase, line ops, screen buffer, lifecycle, printing, snapshot |
| `Services/Session*Coordinator.swift` (6) + `TerminalRenderingCoordinator.swift` | 7 extracted coordinators: AITool, SFTP, ShellIO, Reconnect, Keepalive, Recording, Rendering |
| `Services/AI/ApplyPatchTool.swift` | PatchApprovalTracker, LocalWorkspacePatcher, RemotePatchCommandBuilder (605L) |
| `Services/AI/UnifiedDiffPatcher.swift` | V4A unified diff parser and applicator (491L) |
| `UI/Terminal/MetalTerminalSessionSurface.swift` | SwiftUI-Metal bridge, snapshot application, selection, tap-to-deselect (406L) |
| `UI/Terminal/TerminalInputCaptureView.swift` | NSViewRepresentable keyboard bridge for local sessions (422L) |
| `Terminal/Features/PaneManager.swift` | Split-pane tree, input routing, broadcast/solo mode (444L) |
| `UI/Terminal/ExternalTerminalWindowView.swift` | Separate-window terminal session view (341L) |
| `Services/AI/AIToolDefinitions.swift` | Developer prompt, 8 tool schemas, direct-action filter, error helpers (320L) |
| `Services/OpenAIAgentService.swift` | Agent-layer protocols, provider routing, tool definition assembly (317L) |
| `Services/LocalPTYProcess.swift` | Actor wrapping forkpty, async output stream (301L) |
| `Services/AI/AIAgentRunner.swift` | Agent iteration loop, direct-action mode, provider mismatch (249L) |
| `Terminal/Renderer/TerminalMetalView.swift` | NSViewRepresentable wrapping MTKView, gesture recognizers (239L) |
| `ViewModels/AIProviderSettingsViewModel.swift` | Multi-provider settings VM (236L) |
| `Services/LocalShellBootstrap.swift` | Child env for local PTY, ZDOTDIR/BASH_ENV injection (202L) |
| `ViewModels/TerminalAIAssistantViewModel.swift` | AI sidebar VM: messages, streaming, patch approval (379L) |
| `UI/Terminal/PatchApprovalCardView.swift` | Inline patch approval card for `apply_patch` (177L) |
| `App/ThroughputBenchmarkRunner.swift` | Parser/grid + PTY-local benchmarks, `BenchmarkSentinelMatcher` |
| `Services/LLM/` (4 files) | LLMTypes, LLMProvider protocol, LLMProviderRegistry, LLMAPIKeyStore |
| `Services/LLM/Providers/` (5 files) | ChatCompletionsClient, Mistral/Ollama/Anthropic/DeepSeek providers |

---

## Architecture Conventions

- **ObservableObject + @StateObject** throughout (not `@Observable`).
- **Metal rendering**: demand-driven `MTKView` (`enableSetNeedsDisplay = true`, `isPaused = true`).
  `requiresContinuousFrames()` aggregates cursor lerp, smooth scroll, scanner, gradient animation;
  all redraw triggers go through `requestFrame()`. Dirty flag skips redundant draws.
- **Grid snapshot flow**: `TerminalGrid.snapshot()` → `SessionManager` nonce++ → SwiftUI `.onChange` →
  `MetalTerminalRenderer.updateSnapshot()` → `isDirty = true`.
- **Terminal keyboard input**: `DirectTerminalInputNSView` (transparent NSView overlay, `hitTest` returns `nil`).
- **Focus management**: `isAIAssistantComposerFocused` state. `focusSessionAndPane()` resigns at AppKit
  level, then re-arms terminal. See Known Issues.
- **AI service stack**: `OpenAIAgentService.sendProviderRequest()` routes by
  `providerRegistry.activeProviderID`. OpenAI → Responses API; others → `LLMProvider` protocol.
  Provider-agnostic types in `LLMTypes.swift`. See `docs/multiprovider-architecture.md`.
- **AI agent tools**: 10 exposed schemas — 8 in `AIToolDefinitions` (`get_command_output`,
  `get_current_screen`, `search_filesystem`, `search_file_contents`, `read_files`,
  `get_recent_commands`, `execute_command`, `execute_and_wait`) plus `apply_patch` (gated on
  `patchToolEnabled`) and `send_input`. The handler also accepts the legacy/internal names
  `read_file_chunk`, `get_session_info`, and the `search_terminal_history` alias.
  Error format: `{ok:false, error, hint}`.
- **Direct-action mode**: prompts starting `run `/`execute `/`cd ` filter to 8 tools and cap
  iterations at `min(maxToolIterations, 15)` (`AIAgentRunner`). Default `maxToolIterations` is 50;
  `AppDependencies` constructs the service with **200**.
- **`apply_patch` remote flow**: base64 read → V4A in-process diff → base64 heredoc write.
  See `docs/RemotePatchingFix.md`.
- **`nonisolated` on TerminalGrid extensions**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes
  extension methods default to `@MainActor`. All `TerminalGrid+*.swift` methods MUST be explicitly
  `nonisolated`.
- **Coordinator pattern**: `SessionManager` delegates to 7 `@MainActor final class` coordinators,
  each with `weak var manager`.
- **Input routing**: `InputRoutingMode` (.singleFocus/.broadcast/.selectGroup) in `PaneManager`.
  Solo mode: Option+Click in broadcast → single-pane input. `Cmd+Shift+B` toggles broadcast/ends solo.
  See `docs/Issue15.md`.
- **AI broadcast**: `BroadcastContext` threads through ViewModel → AgentService → Runner → ToolHandler.
  `target_session` on all tools. See `docs/AIBroadCaster.md`.
- **Local PTY**: `LocalPTYProcess` (actor, forkpty) + `LocalShellBootstrap` (env, ZDOTDIR).
  `LocalTerminalSubsystem` translates NSEvent → PTY bytes.
- **`nonisolated deinit`**: required on `@MainActor` types that may deallocate off the main actor —
  used on ~18 types (coordinators, `SessionManager`, `PaneManager`, `SessionTabManager`,
  `AIToolHandler`, `AIAgentRunner`, `TerminalAIAssistantViewModel`, `V4AParserState`, …).

---

## Known Issues & Gotchas

- **Swift 6.3 / Xcode 26.6**: declaration-level `nonisolated` on an `actor` is invalid and fails to
  compile. Actors keep their isolated state; await their initializers at cross-isolation call sites.
  (Bit `LibSSHShellChannel`/`LibSSHForwardChannel` — see the 2026-07-13 featurelist entry.)
- **`AIToolHandler.swift` (1,119L)** is now the largest file, ahead of `TerminalView.swift` (1,066L)
  and `SessionManager.swift` (1,017L). Read surrounding context before modifying.
- **Focus management** between AI composer (NSTextView) and terminal (DirectTerminalInputNSView) is
  delicate. Must resign at AppKit level, not just SwiftUI state. See `focusSessionAndPane()`.
- **SwiftUI state mutations during `updateNSView`** cause warnings. Use `DispatchQueue.main.async` or
  `Task { @MainActor in await Task.yield() }` deferral.
- **Alternate buffer scroll policy**: viewport scrolling is blocked during alt-buffer
  (`TerminalRenderingCoordinator.scrollTerminal`/`scrollToRow` early-return); the smooth scroll engine
  is reset on every alt-buffer snapshot and `scrollJumpTo` is skipped in `MetalTerminalSessionSurface`.
  Do not re-enable alt-buffer viewport scroll without re-testing TUI (Claude Code, htop) output.
- **Resize**: primary-buffer grid resize is debounced *together with* the PTY resize so both settle on
  one geometry. View/font geometry changes must NOT reserve `CellBuffer` storage — only a matching
  snapshot may change buffer dimensions. `CellBuffer.resize(columns:rows:)` was deliberately removed.
- **Benchmark sentinels**: PTY-local benchmark completion markers are emitted from two shell arguments
  so the literal sentinel cannot appear in the shell's echo of the command; `BenchmarkSentinelMatcher`
  handles markers split across PTY chunks. Don't inline the sentinel back into one string.
- **`TerminalGrid` partial-region `scrollUp`** rotates the row map in place (fast paths for ±1 line,
  cycle rotation otherwise). Avoid reintroducing per-scroll `regionKeys`/`regionPhysicalRows` arrays —
  that was the 32 MB partial-throughput cliff.
- **Tests read real `UserDefaults`**: `LLMProviderRegistry` restores the persisted active provider,
  so all 17 `AIAgentServiceTests` fail with `providerNotConfigured(...)` on a machine whose last
  selected provider (e.g. DeepSeek) has no API key. The tests do not inject an isolated defaults
  suite — treat these failures as environment leakage, not agent-layer regressions.
- **Bounded startup filters**: `ZshStartupWarningFilter` strips zsh's one-off `can't set tty pgrp`
  warning and **switches off after 32 KB**. Its predecessor only switched off when the warning was
  actually found, so under `sh`/`bash` it scanned every chunk forever — 92.6% of local-shell wall
  time. Any "scan the opening output for X" filter added to the PTY path must be bounded the same
  way. Tests: `ZshStartupWarningFilterTests`.
- **`SessionManagerRenderingPathTests.testLocalSessionStreamsProgressiveCommandOutput` is flaky**
  under full-suite load: it spawns a real `/bin/zsh` and waits 8s for output. It passes in
  isolation and fails in the full suite both before and after recent changes — so the CLAUDE.md
  "870 tests, 0 failures" line does not reproduce today. Current: **883 tests, 1 failure**, that
  one. Treat it as environment, not regression, but verify by running it in isolation.
- **SourceKit false positives**: "Cannot find type" errors across files. Always verify with
  `xcodebuild build`.
- **Bugs doc is stale**: `docs/bugs.md` lists 79 numbered bugs, 29 already marked `[FIXED]` — so **50
  are open** (13 High / 16 Medium / 21 Low), and its summary table ("68 total, 1 Critical") is wrong:
  the sole Critical (Bug 51, QuickCommands) is fixed. Its `**File:**` paths predate the refactors —
  of 48 distinct paths, 18 have moved (`Views/` → `UI/`, `SSH/` → `Services/SSH/`, `Services/Security/`
  → `Services/`) and 10 no longer exist. Resolve paths by basename before trusting an entry.
- **Cell colour is stored packed, not semantic**: `TerminalCell` keeps only `fgPackedRGBA`;
  `cell.fgColor` is a lossy reverse lookup, and `TerminalDefaults.boldIsBright` (true, xterm-style)
  is **pre-applied at write time**. So bold + red reads back as `.indexed(9)`, and `.rgb(0,0,0)`
  reads back as `.indexed(16)`. Assert rendered RGB via `XCTAssertRendersAs`, never the enum case.
- **Terminal selection**: `selectedText()` skips wide-char continuation cells. Plain-tap deselection
  lives in `MetalTerminalSessionSurface` (shared by embedded and external windows).
  `handleDrag` processes `.ended`/`.cancelled` before the `gridCell(at:)` guard.
- **Docs directory case**: git tracks 19 files under `Docs/` and 4 under `docs/`
  (`FutureFeatures.md`, `Optimization.md`, `RefactorTheFinalRun.md`, `screenshots/`). This only works
  because macOS is case-insensitive — a case-sensitive checkout will split them into two directories.

---

## Completed Refactors

| Refactor | Phases | Key output | Spec |
|---|---|---|---|
| RefactorTheActor (Strict Concurrency) | 0-8 | `Services/SSH/`, `Services/AI/`, session coordinators | spec file no longer in repo; see `docs/featurelist.md` |
| RefactorTerminalView | 0-9 | `UI/Terminal/` split into 21 components | `RefactorTerminalView.md` (repo root) |
| RefactorTerminalGrid | 0-11 | 11 `TerminalGrid+*.swift` extensions | `RefactorTerminalGrid.md` (repo root) |
| RefactorMetalTerminalRenderer | 0-8 | 8 `MetalTerminalRenderer+*.swift` extensions | `docs/RefactorMetalTerminalRenderer.md` |
| RefactorTheFinalRun | 0-19 | 4 god files decomposed | `docs/RefactorTheFinalRun.md` |
| Test migration | — | All tests now in `ProSSHMacTests/` (none under app sources) | `docs/featurelist.md` |

---

## Reference Docs

| Doc | Purpose |
|-----|---------|
| `docs/featurelist.md` | **Long-term memory** — dated work log, phase progress, loop-log entries |
| `docs/bugs.md` | Bug audit by subsystem/severity — 50 of 79 still open; paths are pre-refactor |
| `docs/FutureFeatures.md` | Prioritized feature roadmap (competitive analysis) |
| `docs/Optimization.md` | Performance bottleneck analysis, benchmark commands, current numbers |
| `docs/FasterThenYouWillEverLiveToBe.md` | Throughput gap profiling — **Phases 0,1,2,3,5 done; only optional Phase 4 left** |
| `docs/optimizationspart2.md` | Throughput recovery playbook (Part 2) |
| `docs/OptimizeP2.md` / `docs/OptimizeP3.md` | P2 / P3 optimization phased checklists — **COMPLETE** |
| `docs/PhaseB.md` | Local Input V2 Phase B checklist (make byte-first local input the only path) |
| `docs/multiprovider-architecture.md` | Multi-provider LLM architecture overview |
| `docs/AIpatchfeatureIntegration.md` | `apply_patch` integration guide |
| `docs/RemotePatchingFix.md` | Remote patching fix (base64 read/write approach) |
| `docs/Issue15.md` | Multi-session broadcast input routing |
| `docs/AIBroadCaster.md` | AI Broadcaster — session-aware agent for multi-pane broadcast |
| `docs/BlackTextRenderingFix.md` | Black text rendering fix (issue #9) |
| `docs/FixTerminalCopyAndSelection.md` | Terminal copy/selection fix (issue #22) |
| `docs/IntegrationOfNewFeats.md` | Pre-built module integration guide (TOTP 2FA, etc.) |
| `docs/Issue11.md` | Visual jitter fix — phased checklist (Phases 0–5) |
| `docs/TextGlow.md` | Bloom / Text Glow — **COMPLETE** (Phases 0–7) |
| `docs/SmoothScroll.md` | Smooth Scrolling — **COMPLETE** (Phases 0–6) |

Note: `AGENTS.md` (repo root) is a parallel working-memory file for non-Claude assistants and points
at `Docs/featurelist.md`. Keep it in sync when process guidance changes.

---

## Next Session Plan

**Last completed work (2026-09-03): FasterThenYouWillEverLiveToBe Phases 0, 1, 2, 3 and 5.**

The "50x gap" was three separate things:

1. **A Debug build** — every historical number used `-Onone`. Release is ~20x faster on
   parser/grid (1.84 → 36.40 MB/s). `benchmark-throughput.sh` now takes `--configuration`.
2. **A startup filter that never switched off** — `LocalPTYProcess.yieldSanitized` stripped zsh's
   one-off `can't set tty pgrp` warning, but only stopped scanning if it actually found it. Under
   `sh`/`bash` it decoded, lowercased, case-insensitively searched and re-encoded every chunk for
   the whole session: **92.6% of local-shell wall time**. Extracted to
   `ZshStartupWarningFilter` and bounded to 32 KB. **PTY-local 6.81 → 17.97 MB/s.**
3. **A target derived from a pipe that does no emulation** — 89 MB/s is unreachable by any real
   emulator here. Terminal.app does 22.2 MB/s with rendering, iTerm2 2.44 MB/s.

`TerminalPerf` now gates the five signposts plus in-process stage timers behind
`--perf-signposts`; that instrumentation is what found #2, in a stage none of the plan's four
ranked hypotheses had named. H2 and H3 were measured and killed.

**Current Release numbers:** 36.38 MB/s parser/grid fullscreen, 17.97 MB/s PTY-local.

Next steps:
- **Optional: Phase 4** — the dominant stage is now `parse + grid` (44% of wall), and the rest is
  reader/`AsyncStream` overhead: 2592 chunks for 2.67 MB is ~1 KB per chunk, ~2600 actor hops.
  Try coalescing reads before the hand-off. Judge against ~22 MB/s, not 89.
- **The real unknown is rendering cost.** No benchmark here measures it — peers were measured with
  rendering, ProSSHMac without. Measuring it is higher-value than more parser work.
- `SessionManagerRenderingPathTests.testLocalSessionStreamsProgressiveCommandOutput` is flaky
  under full-suite load (pre-existing, fails at HEAD too). Worth stabilising.
- Unrelated open work: `docs/bugs.md` (50 open), `docs/PhaseB.md`, the `Docs/` vs `docs/` case split.
