# CLAUDE.md — Working Memory

Read automatically at every session start. Current state only — no history, no dated entries.

---

## Memory Architecture

| Layer | File | Purpose |
|-------|------|---------|
| **Working memory** | `CLAUDE.md` (this file) | Current state, conventions, key files, gotchas. Read every session. |
| **Long-term log** | `Docs/featurelist.md` | Dated work log, phase progress, loop-log entries. Append-only history. |
| **Feature specs** | `Docs/<FeatureName>.md` | Per-feature phased checklist with architecture notes. Created at feature start. |

- `CLAUDE.md` holds **what is true now**. Update when architecture, conventions, key files, or gotchas change.
- `Docs/featurelist.md` holds **what happened and when**. Every session appends a dated entry.
  New entries go at the top of its first `## Loop Log` section (newest first).
- Feature specs hold **what to do and how**. Each phase has a `- [ ]` checkbox, checked off when completed.
- When a fact here turns into history (a bug fixed, a measurement superseded), put the story in
  `Docs/featurelist.md` or the feature spec and keep only the resulting rule here.

---

## Workflow

### Starting a New Feature

1. Create `Docs/<FeatureName>.md` with:
   - Overview (goal, architecture sketch, affected files)
   - Phased checklist using `- [ ] Phase N: <title>` checkbox format
   - Each phase should be one session's worth of work
2. Add a reference row to the Reference Docs table below.
3. Log the feature start in `Docs/featurelist.md` with today's date.

### Session Workflow (one phase per session)

Each Claude Code session implements exactly one phase from a feature spec.

**Start of session:**
1. This file is read automatically — instant project context.
2. Read the feature spec (`Docs/<FeatureName>.md`) to find the current unchecked phase.
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
2. Check off completed phase in `Docs/<FeatureName>.md`
3. Append dated entry to `Docs/featurelist.md` (what changed, files modified, build/test status)
4. Update this `CLAUDE.md` if architecture, conventions, key files, or gotchas changed
5. Write the **Next Session Plan** block at the bottom of this file
6. Commit all changes (code + docs) in a single commit

### Continuous Workflow Across Sessions

At the bottom of this file is a `## Next Session Plan` section. Before ending a session,
write a brief plan there for the next session. This gets injected as context when the next
session starts (as the first user message after `/clear`), creating continuity across context windows.

Contents should include:
- Which feature spec and phase to work on next
- Key decisions or context the next session needs
- Any blockers or open questions

When editing it, replace only the text below the `## Next Session Plan` heading, and check
`wc -l CLAUDE.md` before committing — this file was once silently truncated to its last section.

### Plan Mode Protocol

Before every implementation phase, plan mode is enabled. The plan should:
- State the phase goal and which feature spec it belongs to
- List files to modify and why
- Identify conventions to respect (check Architecture Conventions and Known Issues below)
- If too large for one session, propose splitting into sub-phases

---

## Project Overview

**ProSSHMac** is a native macOS SSH/terminal client built with SwiftUI + Metal.
Deployment target: macOS 26.0. App target: Swift 6 language mode; test target: Swift 5.10 with
complete strict concurrency. Both use `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

Key capabilities:
- Metal-rendered terminal (glyph atlas + cache, GPU cell buffer, cursor animation, smooth scrolling)
- SSH connections via libssh (C wrapper in `CLibSSH/`, vendored libs in `Vendor/`)
- Local shell sessions via PTY (`LocalPTYProcess` + `LocalShellBootstrap`)
- SFTP file browser sidebar (left, toggle `Cmd+B`)
- AI Terminal Copilot sidebar (right, toggle `Cmd+Opt+I`) — OpenRouter Chat Completions
- Pane splitting, session tabs, broadcast input routing (`Cmd+Shift+B`), session recording/playback
- KeyForge (SSH key generation), certificate management + KRL, port forwarding
- TOTP 2FA (`TOTPStore`/`TOTPGenerator`), biometric password store, Secure Enclave keys
- `~/.ssh/config` import/export, Spotlight host indexing, App Intents / Shortcuts
- Shell integration (command blocks, history index, prompt marks)
- Keyboard protocols: kitty disambiguation (bit 1 only) and xterm `modifyOtherKeys` for
  Shift+Enter; Shift+Enter inserts an editable newline at a plain shell prompt
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
# Parser/grid only (no PTY, no rendering)
./scripts/benchmark-throughput.sh --configuration Release --benchmark-bytes 2097152 --benchmark-runs 4 --benchmark-chunk 4096
# Real PTY -> engine.feed, but not the app's reader path
./scripts/benchmark-throughput.sh --configuration Release --no-build --pty-local --benchmark-bytes 2097152 --benchmark-runs 4
# The real app path. --render draws; --render-detached parks on .hosts so nothing draws.
# ALWAYS pin the window and record it — results scale with cell count by >10x.
./scripts/benchmark-throughput.sh --configuration Release --no-build --render-detached \
    --benchmark-window 1280x800 --benchmark-bytes 8388608 --benchmark-runs 3 [--perf-signposts]
./scripts/benchmark-peer-emulator.sh          # Terminal.app / iTerm2 comparison
./scripts/benchmark-ssh.sh --host <hostname> --user <username>
```

- **Toolchain: Xcode 27.0 (27A266a), Swift 6.4.** The Metal Toolchain component must be installed
  (`xcodebuild -showComponent metalToolchain`). Never exclude `TerminalShaders.metal` from a build;
  if the shader fails to compile, check the component first.
- Test bundle: `ProSSHMacTests` — 5 files at the bundle root plus 51 in `ProSSHMacTests/Terminal/Tests/`,
  ~920 test methods. No test sources live under `ProSSHMac/`.
- Some tests require the host app process (UI/AppKit-backed suites).
- **No full-suite baseline exists on Xcode 27.** Every suite touched since has been run targeted and
  green. Treat any red result in a suite you touched as yours, including
  `SessionManagerRenderingPathTests` (it has no expected failures).
- Tests must not depend on the developer's real `UserDefaults`. `OpenRouterModelStore` and
  `LegacyProviderKeyCleanup` accept an injected defaults suite; AI tests use isolated suites.
- **Throughput baseline, Release** (state the configuration with every number — Release is ~20x
  Debug, and never compare across the two):

  | Path | MB/s | Measured |
  |---|---|---|
  | Parser/grid, 2 MB (`--benchmark-base64`) | **36.4-37.3** | 2026-09-04 |
  | PTY -> `engine.feed` (`--pty-local`) | **19.20** | 2026-09-03 |
  | Real app path, 8 MB (`--render-detached`, **no window**) | **3.80-5.01** | 2026-09-04, pre-R2b |
  | Terminal.app (peer, with rendering) | 26.5 | 2026-09-03 |

  No windowed real-app figure is currently reproducible. **Read `Docs/RenderCost.md`
  "Measurement caveats" before trusting or recording any rendered number.**
- **Target: match or beat Terminal.app end-to-end** (26.5 MB/s; iTerm2 ~1.4 MB/s on the same
  machine, 6 MB with rendering). The old 89 MB/s target was a pipe baseline with no terminal
  emulation — ignore it where older docs cite it. See `docs/Optimization.md`.
- **Perf instrumentation:** `TerminalPerf` (`Terminal/Diagnostics/TerminalPerf.swift`) gates five
  signposts and **19 in-process stage timers** behind `--perf-signposts` / `PROSSH_PERF_SIGNPOSTS=1`
  / `terminal.perf.signposts`. Pass `--perf-signposts` to `benchmark-throughput.sh` to print a stage
  budget. Off by default and verified free when off.
  The budget reports **time, %wall, span, busy% and start offset** per stage: span is first-start to
  last-end, busy is time/span. A stage spanning the whole run at low busy% is **blocked, not slow**.
  Several stages are deliberate caller/callee pairs (`feedCall` vs `parse`, `publish` vs
  `publishEngineWait`); the difference within a pair is actor-hop and queue wait rather than work.
- **Scheduling diagnostics:** `TerminalSchedulingDiagnostics`
  (`Terminal/Diagnostics/TerminalSchedulingDiagnostics.swift`) is a separate opt-in gate —
  `--perf-scheduling` / `PROSSH_PERF_SCHEDULING=1`. It samples thread CPU vs wall time (per QoS)
  around synchronous ground-text/grid work only, plus batch sizes and burst events. Thread clocks
  are never read across an `await`: a suspension can resume on another thread. **It also switches
  on `TerminalPerf`** (`TerminalPerf.swift:32`), so its runs are only comparable with
  signpost-on runs. `benchmark-throughput.sh` forwards unknown flags, so append `--perf-scheduling`;
  the report prints after the stage budget. It has never been run; no results exist yet.

---

## Project Structure

```
ProSSHMac/
├── ProSSHMacApp.swift    # @main entry, Spotlight indexer wiring
├── ContentView.swift
├── App/                  # AppDependencies, AppNavigationCoordinator/Section, AppAppearance,
│   │                     #   AppLaunchCommandStore, ThroughputBenchmarkRunner (+Render)
├── AppIntents/           # ProSSHShortcuts (App Intents / Siri Shortcuts)
├── CLibSSH/              # C wrapper around libssh (ProSSHLibSSHWrapper.c/.h, bridging header)
├── Models/               # Host, Session, Transfer, SSHKey, SSHCertificate, AuditLogEntry,
│   │                     #   TOTPConfiguration
├── Services/             # SessionManager (+Queries) + 7 coordinators, TransferManager,
│   │                     #   EncryptedStorage, PersistentStore, PortForwardingManager,
│   │                     #   LocalPTYProcess, LocalShellBootstrap, LocalShellChannel,
│   │                     #   ZshStartupWarningFilter, SSHBinaryReader,
│   │                     #   KeyForgeService, KeyStore, KnownHostsStore, CertificateStore,
│   │                     #   CertificateAuthorityService (+3 ext) / Store, AuditLogManager/Store,
│   │                     #   TOTPGenerator/Store, BiometricPasswordStore, SecureEnclaveKeyManager,
│   │                     #   HostStore, HostSpotlightIndexer, SSHConfig{Parser,Mapper,ImportService,
│   │                     #   Exporter,TokenExpander}, AIAgentService
│   ├── SSH/              #   LibSSHTransport, LibSSH{Shell,Forward}Channel, MockSSHTransport,
│   │                     #   SSHTransportProtocol/Types, SSHAlgorithmPolicy,
│   │                     #   (Default)SSHCredentialResolver, RemotePath
│   ├── AI/               #   AIToolHandler (+5 ext), AIAgentRunner, AIToolDefinitions,
│   │                     #   AIConversationContext, AISharedTypes,
│   │                     #   OpenRouterClient/Types/ModelStore/APIKeyStore,
│   │                     #   ApplyPatchTool, UnifiedDiffPatcher, apply_diff
├── Terminal/
│   ├── Diagnostics/      # TerminalPerf (runtime-gated signposts + stage timers),
│   │                     #   TerminalSchedulingDiagnostics (thread CPU vs wall, opt-in)
│   ├── Grid/             # TerminalGrid + 11 extensions, TerminalCell, CursorState, CharacterWidth,
│   │                     #   GridReflow, GridSnapshot, ScrollbackBuffer
│   ├── Parser/           # TerminalEngine, VTParserTables, VTConstants, CSI/OSC/SGR/ESC/DCS/Charset
│   ├── Input/            # KeyEncoder, MouseEncoder, HardwareKeyHandler, LocalTerminalSubsystem,
│   │                     #   InputModeState, PasteHandler, KeyboardToolbar, TerminalPointerSelection
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
│   ├── Terminal/         # 22 files: TerminalView, TerminalSurfaceView, MetalTerminalSessionSurface,
│   │                     #   TerminalPaneView/SplitNodeView/PaneDividerView, TerminalAIAssistantPane,
│   │                     #   ReasoningStreamView, PatchApprovalCardView, TerminalFileBrowserSidebar,
│   │                     #   session tab/header/actions/metadata bars, search bar, scrollbar,
│   │                     #   quick commands, TerminalInputCaptureView, ExternalTerminalWindowView,
│   │                     #   MatrixScreensaverView, TerminalKeyboardShortcutLayer,
│   │                     #   TerminalSidebarLayoutStore
│   ├── Hosts/            # HostsView, HostFormView, PortForwardingRuleEditor, SSHConfigImportPreviewView
│   ├── Transfers/        # TransfersView
│   ├── Settings/         # SettingsView + 8 effect settings subviews, OpenRouterModelPicker
│   ├── KeyForge/         # KeyForgeView, KeyInspectorView
│   └── Certificates/     # CertificatesView, CertificateInspectorView
├── ViewModels/           # HostListVM, KeyForgeVM, CertificatesVM, OpenRouterSettingsVM,
│                         #   TerminalAIAssistantVM
└── Platform/             # PlatformCompatibility (macOS/iOS shims)
```

---

## Key Files

All paths relative to repo root, under `ProSSHMac/`. Line counts as of 2026-10-11.

| File / Group | What it does |
|---|---|
| `Services/AI/AIToolHandler.swift` + 5 extensions | Tool dispatch (1,119L) — largest file. Extensions: ArgumentParsing, RemoteExecution, LocalFilesystem, InteractiveInput, OutputHelpers |
| `Services/TerminalRenderingCoordinator.swift` | Snapshot publishing, scroll state, resize debounce, alt-buffer policy, shell-buffer throttle (1,066L). An ordinary publish is two engine calls (`publishViewportState`, then `publishSnapshot` carrying housekeeping) with MainActor scroll-anchor policy between them |
| `UI/Terminal/TerminalView.swift` | Main terminal UI, sidebar layout, focus, input capture (1,034L). `sessionPanel` is the only place a session's terminal surface is built |
| `Services/SessionManager.swift` + Queries | Session lifecycle, shell I/O, SFTP, grid snapshots (1,020L) |
| `UI/Terminal/TerminalAIAssistantPane.swift` | AI copilot sidebar, composer, message rendering, pipe tables (992L) |
| `Terminal/Parser/TerminalEngine.swift` | VT parser hot path, merged parse/apply loop, `feedAndCollectOutcome`, `primaryBufferVisibleText` (843L) |
| `Services/SSH/LibSSHTransport.swift` | LibSSH transport actor (822L); channels in `LibSSHShellChannel`/`LibSSHForwardChannel` |
| `Terminal/Renderer/MetalTerminalRenderer.swift` + 8 extensions | Metal renderer (510L): glyph resolution, snapshot update, font management, draw loop, view config, selection, post-processing, diagnostics |
| `Terminal/Renderer/SmoothScrollEngine.swift` | CPU scroll physics, rubber-band, jumpTo, frame-rate independence |
| `Terminal/Grid/TerminalGrid.swift` + 11 extensions | Grid state (461L): modes (incl. per-screen keyboard-mode stacks), OSC, tabs, cursor, scroll, erase, line ops, screen buffer, lifecycle, printing, snapshot |
| `Services/Session*Coordinator.swift` (6) + `TerminalRenderingCoordinator.swift` | 7 extracted coordinators: AITool, SFTP, ShellIO, Reconnect, Keepalive, Recording, Rendering |
| `Services/AI/ApplyPatchTool.swift` | PatchApprovalTracker, LocalWorkspacePatcher, RemotePatchCommandBuilder (604L) |
| `Terminal/Features/TerminalHistoryIndex.swift` | Command blocks, prompt heuristics, output capture, input-escape-sequence tracking (519L). Raw output is a bounded UTF-8 byte buffer — see gotchas before touching `recordOutputChunk` |
| `Services/AI/UnifiedDiffPatcher.swift` | V4A unified diff parser and applicator (491L) |
| `Terminal/Features/PaneManager.swift` | Split-pane tree, input routing, broadcast/solo mode (444L) |
| `UI/Terminal/TerminalInputCaptureView.swift` | NSViewRepresentable keyboard bridge for local sessions (422L) |
| `App/ThroughputBenchmarkRunner+Render.swift` | End-to-end benchmark through the real app path (419L): `--benchmark-render`, `--benchmark-render-detached`, `--benchmark-window WxH`, windowless warning |
| `UI/Terminal/MetalTerminalSessionSurface.swift` | SwiftUI-Metal bridge, snapshot application, selection from mouse events (394L) |
| `ViewModels/TerminalAIAssistantViewModel.swift` | AI sidebar VM: messages, streaming, patch approval (379L) |
| `UI/Terminal/ExternalTerminalWindowView.swift` | Separate-window terminal session view (341L) |
| `Terminal/Input/KeyEncoder.swift` | Key → byte encoding driven by `KeyEncoderOptions` (application cursor keys, kitty disambiguation, `modifyOtherKeys`); Shift+Enter fallback (315L) |
| `Services/AI/AIToolDefinitions.swift` | Developer prompt, 8 tool schemas, direct-action filter, error helpers (315L) |
| `Services/SessionShellIOCoordinator.swift` | Shell input, the batched parser reader, per-batch bookkeeping (307L). Each batch is one `feedAndCollectOutcome` call, applied in one MainActor handoff with no post-feed engine reads; also filters the AI tool wrapper echo |
| `Services/LocalPTYProcess.swift` | Actor wrapping forkpty, async output stream (274L) |
| `Terminal/Renderer/TerminalMetalView.swift` | NSViewRepresentable wrapping `TerminalMTKView` (left-mouse events with click count), wheel scrolling (204L) |
| `Terminal/Diagnostics/TerminalPerf.swift` | Runtime-gated signposts + 19 in-process stage timers with span/busy tracking (236L). Start here for any perf work |
| `Services/SessionAIToolCoordinator.swift` | AI one-shot command wrapping with private OSC 7777 start/completion events (206L) |
| `Services/LocalShellBootstrap.swift` | Child env for local PTY, ZDOTDIR/BASH_ENV injection (202L) |
| `UI/Terminal/PatchApprovalCardView.swift` | Inline patch approval card for `apply_patch` (177L) |
| `UI/Terminal/ReasoningStreamView.swift` | Native `NSScrollView`/`NSTextView` (TextKit 1) reasoning panel (132L) |
| `Services/ZshStartupWarningFilter.swift` | Bounded zsh startup-warning filter for the PTY path (120L) |
| `Terminal/Input/InputModeState.swift` | Actor mirroring grid input modes for the encoder; synced from grid snapshots (103L) |
| `Terminal/Diagnostics/TerminalSchedulingDiagnostics.swift` | Opt-in (`--perf-scheduling`) thread CPU vs wall sampling around synchronous grid work, batch sizes, burst events (96L) |
| `Services/AIAgentService.swift` | Agent-layer protocols and tool definition assembly |
| `Services/AI/AIAgentRunner.swift` | Agent iteration loop, direct-action mode, structured transcript replay |
| `Services/AI/OpenRouterClient.swift` | OpenRouter catalog and streamed Chat Completions transport |
| `Services/AI/OpenRouterModelStore.swift` | Explicit model selection and catalog disappearance checks |
| `ViewModels/OpenRouterSettingsViewModel.swift` | OpenRouter key state and catalog refresh |
| `App/ThroughputBenchmarkRunner.swift` | Parser/grid + PTY-local benchmarks, `BenchmarkSentinelMatcher`, stage-budget print |

---

## Architecture Conventions

- **ObservableObject + @StateObject** throughout (not `@Observable`).
- **Metal rendering**: demand-driven `MTKView` (`enableSetNeedsDisplay = true`, `isPaused = true`).
  `requiresContinuousFrames()` aggregates cursor lerp, smooth scroll, scanner, gradient animation;
  all redraw triggers go through `requestFrame()`. Dirty flag skips redundant draws.
- **Grid snapshot flow**: `TerminalGrid.snapshot()` → `SessionManager` nonce++ → SwiftUI `.onChange` →
  `MetalTerminalRenderer.updateSnapshot()` → `isDirty = true`.
- **Publish cadence** (`TerminalRenderingCoordinator`): snapshots every 8 ms normally, 16 ms in burst
  mode / alt buffer, 24 ms for prompt redraws, 40 ms during synchronized output. Burst mode turns on
  at >3 publish requests within 16 ms and reverts 200 ms after the last request. Visible-text
  (`shellBuffers`) extraction is throttled to 33 ms, or 200 ms in burst mode.
- **Terminal keyboard input**: `DirectTerminalInputNSView` (transparent NSView overlay, `hitTest` returns `nil`).
- **Keyboard modes**: the grid tracks kitty disambiguation as independent bounded (16-entry)
  stacks for the main and alternate screens, plus xterm `modifyOtherKeys`. `CSIHandler` updates
  them and calls `InputModeState.syncFromSnapshot`; grid snapshots carry them to the embedded and
  external windows' encoder options. Shift+Enter sends `CSI 13;2u` (disambiguation), else
  `CSI 27;2;13~` (`modifyOtherKeys`), else quoted-insert + LF (`0x16 0x0A`). Only enhancement bit 1
  is supported and reported. Soft/full reset clears all keyboard modes.
- **Focus management**: `isAIAssistantComposerFocused` state. `focusSessionAndPane()` resigns at AppKit
  level, then re-arms terminal. See Known Issues.
- **AI service stack**: `AIAgentService` uses one `OpenRouterClient` for Chat Completions.
  `OpenRouterModelStore` requires explicit selection and refreshes the tool-capable text-model catalog.
  `AIConversationContext` stores per-session structured turns; a model switch drops reasoning blocks
  but keeps messages and tool history. `OpenRouterAPIKeyStore` owns the single Keychain entry.
  `Docs/multiprovider-architecture.md` is superseded historical context.
- **AI reasoning panel**: `ReasoningStreamView` bridges a native `ReasoningStreamScrollView`;
  TextKit owns viewport-width wrapping, document height, selection and autoscroll across thinking chains.
  `ReasoningStreamViewTests` check actual line fragments over ten chain replacements and sidebar resizes.
- **AI terminal tool completion**: `SessionAIToolCoordinator` wraps one-shot commands with private
  OSC 7777 start/completion events, filters the echoed wrapper in the parser reader, and takes the
  exit code from `TerminalEngine`'s event callback. Remote filesystem helpers use the same command
  path. The chat pane renders pipe tables and collapses blank paragraph spacing.
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
  See `Docs/RemotePatchingFix.md`.
- **`nonisolated` on TerminalGrid extensions**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes
  extension methods default to `@MainActor`. All `TerminalGrid+*.swift` methods MUST be explicitly
  `nonisolated`.
- **Coordinator pattern**: `SessionManager` delegates to 7 `@MainActor final class` coordinators,
  each with `weak var manager`.
- **Input routing**: `InputRoutingMode` (.singleFocus/.broadcast/.selectGroup) in `PaneManager`.
  Solo mode: Option+Click in broadcast → single-pane input. `Cmd+Shift+B` toggles broadcast/ends solo.
  See `Docs/Issue15.md`.
- **AI broadcast**: `BroadcastContext` threads through ViewModel → AgentService → Runner → ToolHandler.
  `target_session` on all tools. See `Docs/AIBroadCaster.md`.
- **Local PTY**: `LocalPTYProcess` (actor, forkpty) + `LocalShellBootstrap` (env, ZDOTDIR).
  `LocalTerminalSubsystem` translates NSEvent → PTY bytes.
- **`nonisolated deinit`**: required on `@MainActor` types that may deallocate off the main actor —
  used on 17 types (coordinators, `SessionManager`, `PaneManager`, `SessionTabManager`,
  `AIToolHandler`, `AIAgentRunner`, `TerminalAIAssistantViewModel`, `V4AParserState`, …).

---

## Known Issues & Gotchas

### Toolchain and tests
- **Swift 6.3+: declaration-level `nonisolated` on an `actor` is invalid** and fails to compile.
  Actors keep their isolated state; await their initializers at cross-isolation call sites.
- **Test doubles for app protocols must be `@MainActor final class`, not `actor`.** The test module
  sees `KnownHostsStoreProtocol`, `SSHTransporting`, `SSHForwardChannel` and `SSHShellChannel` as
  `MainActor`-isolated (diagnostic points at `<unknown>:0`), so `actor Fake: KnownHostsStoreProtocol`
  fails with "actor cannot conform to global-actor-isolated protocol" — even though the app's own
  actors conform fine.
- **A pass-or-full-timeout test (never merely slow) is a lost update, not load.** Root-cause it
  before calling it flaky.
- **`testAlternateBufferSplitRedrawPublishesOnlyAfterQuiescentWindow` has thin timing margins** —
  12 ms sleeps against a 16 ms reschedule interval. If it goes red once, re-run before suspecting code.
- **Every `XCTestCase` subclass warns** "main actor-isolated initializer 'init()' has different actor
  isolation from nonisolated overridden declaration" — target-wide, from default MainActor
  isolation. Not caused by your change; don't chase it per file.
- **SourceKit false positives**: "Cannot find type" errors across files. Always verify with
  `xcodebuild build`.

### Terminal pipeline
- **The `shellBuffers` throttle must defer, never drop.** A throttled refresh in
  `shouldPublishShellBuffer` schedules one trailing `refreshDeferredShellBuffer` at window end, which
  reads `TerminalEngine.primaryBufferVisibleText()` (nil in the alt buffer, consumes no bells).
  Dropping it leaves `shellBuffers` stale until the next output, breaking terminal search,
  copy-last-line, the AI's `get_current_screen`/per-turn snapshot and history-index command
  completion. Tests: `testThrottledShellBufferRefreshCatchesUpAfterOutputStops`,
  `testDeferredShellBufferRefreshSkipsAlternateBuffer`,
  `testLocalSessionStreamsProgressiveCommandOutput` (a failure there is a real regression).
- **Bounded startup filters**: `ZshStartupWarningFilter` strips zsh's one-off `can't set tty pgrp`
  warning and **switches off after 32 KB** whether or not it found it. Any "scan the opening output
  for X" filter added to the PTY path must be bounded the same way — an unbounded one once cost 92.6%
  of local-shell wall time under `sh`/`bash`. Tests: `ZshStartupWarningFilterTests`.
- **`TerminalHistoryIndex` raw output is UTF-8 bytes, deliberately.** It is appended once per output
  batch and read once per command completion. Do not reintroduce `String.count`, `removeFirst`, or a
  `var state = sessionStates[id]` copy on that path; the length must stay O(1), the trim amortized,
  and the character cap applied at read time. (As a capped `String` it measured 89% of wall.)
- **`recordParsedChunk` runs once per 4 ms batch, not per raw chunk.** It is `@MainActor`; per-chunk
  it cost ~1290 hops per MB. Do not move it back into the accumulator loop.
- **`TerminalGrid` partial-region `scrollUp`** rotates the row map in place (fast paths for ±1 line,
  cycle rotation otherwise). Avoid reintroducing per-scroll `regionKeys`/`regionPhysicalRows`
  arrays — that was a 32 MB partial-throughput cliff.
- **Keyboard-mode CSI ordering**: `CSI ? u` / `CSI > u` / `CSI < u` / `CSI = u`, `CSI > 4 ; Pv m`
  and `CSI > 4 n` must be handled in `CSIHandler` **before** DEC modes, cursor restore (`CSI u`) and SGR (`m`), which
  share final bytes. Unknown private-marker sequences must be ignored, never fall through.
- **Shift+Enter shell fallback depends on the line editor's quoted-insert (`^V`) binding** — verified
  in zsh only. Shell-prompt tests must wait for line-editor mode; sending during startup hits tty
  LF→CR translation and proves nothing. The history index tracks ESC/CSI/SS3 and quoted input across
  calls so key sequences never pollute or submit command history.
- **Alternate buffer scroll policy**: viewport scrolling is blocked during alt-buffer
  (`TerminalRenderingCoordinator.scrollTerminal`/`scrollToRow` early-return); the smooth scroll engine
  is reset on every alt-buffer snapshot and `scrollJumpTo` is skipped in `MetalTerminalSessionSurface`.
  Do not re-enable alt-buffer viewport scroll without re-testing TUI (Claude Code, htop) output.
- **Resize**: primary-buffer grid resize is debounced *together with* the PTY resize so both settle on
  one geometry. View/font geometry changes must NOT reserve `CellBuffer` storage — only a matching
  snapshot may change buffer dimensions. `CellBuffer.resize(columns:rows:)` was deliberately removed.
- **Cell colour is stored packed, not semantic**: `TerminalCell` keeps only `fgPackedRGBA`;
  `cell.fgColor` is a lossy reverse lookup, and `TerminalDefaults.boldIsBright` (true, xterm-style)
  is **pre-applied at write time**. So bold + red reads back as `.indexed(9)`, and `.rgb(0,0,0)`
  reads back as `.indexed(16)`. Assert rendered RGB via `XCTAssertRendersAs`, never the enum case.
- **Terminal selection comes from mouse events, never gesture recognizers.** An
  `NSPanGestureRecognizer` claimed every trackpad click (sub-pixel movement), so click-to-clear,
  double- and triple-click never fired (Bug 85). `TerminalMTKView` forwards `mouseDown` (with
  `clickCount`)/`mouseDragged`/`mouseUp`, and `TerminalPointerSelection` decides: a press clears or
  selects a word/line, and a drag selects only after leaving its start cell. The model lives in
  `MetalTerminalSessionSurface` (shared by embedded and external windows); `mouseUp` needs no grid
  cell. `selectedText()` skips wide-char continuation cells. Tests: `TerminalPointerSelectionTests`.
- **View-keyed registries must remove by identity, not by key.** When SwiftUI rebuilds a view, the
  new view's `onAppear` can run *before* the old view's `onDisappear`.
  `TerminalSelectionCoordinator.unregister(sessionID:model:)` therefore removes an entry only if it
  still belongs to the caller; removing by session ID alone broke all terminal copy after the surface
  was rebuilt (Bug 81). Apply the same rule to any registry filled in `onAppear`.
- **The terminal surface owns the renderer, so its view identity is the renderer's lifetime.**
  `MetalTerminalSurfaceModel` (and its `MetalTerminalRenderer`) is a `@StateObject`; SwiftUI keys it
  to the view's structural position, and `.id(session.id)` only matches within one position. Build
  the surface in exactly one place per layout (`TerminalView.sessionPanel`) and express layout modes
  (`terminalOnly`) as conditional *siblings* and modifier values, never as a second build site — a
  second site made Maximize Terminal rebuild the renderer (Bug 82). Window resizes do not rebuild it.
  Tab switches and split/unsplit still do (Bug 84, `Docs/Bug84.md`). Regression test:
  `TerminalSurfaceIdentityTests` (hosts the real `TerminalView`; assert renderer identity).

### UI
- **Four files are over 1,000 lines**: `AIToolHandler.swift` (1,119L),
  `TerminalRenderingCoordinator.swift` (1,066L), `TerminalView.swift` (1,034L),
  `SessionManager.swift` (1,020L). Read surrounding context before modifying.
- **Focus management** between AI composer (NSTextView) and terminal (DirectTerminalInputNSView) is
  delicate. Must resign at AppKit level, not just SwiftUI state. See `focusSessionAndPane()`.
- **SwiftUI state mutations during `updateNSView`** cause warnings. Use `DispatchQueue.main.async` or
  `Task { @MainActor in await Task.yield() }` deferral.
- **Live validation needs a relaunch.** A running Debug app does not pick up a rebuild; compare the
  process start time with the binary's build time before judging a fix from a screenshot.

### Benchmarks
- **The rendered benchmark gets no window when launched with arguments.** `open -n App.app --args
  <anything>` yields `NSApp.windows.count == 0` (`applicationShouldHandleReopen` does not recover it),
  so `--benchmark-render` silently measures the detached path. The runner warns loudly; a warned run
  is not comparable to any windowed run. Fixing window acquisition unblocks the window-scaling test
  and the render-vs-detached delta, both still unmeasured.
- **Benchmark numbers drift across a session; only interleaved A/B is trustworthy.** The same binary
  has varied 3x over hours and 7x under a `mediaanalysisd` pass. Build both binaries, alternate
  launches, compare within a pair, and record `sysctl -n vm.loadavg` plus the top CPU consumers
  with every result.
- **Benchmark sentinels**: PTY-local completion markers are emitted from two shell arguments so the
  literal sentinel cannot appear in the shell's echo; `BenchmarkSentinelMatcher` handles markers
  split across PTY chunks. Don't inline the sentinel back into one string.

### Repo and docs
- **AI test isolation**: agent and model-store tests use isolated defaults suites, mock OpenRouter
  responses, and never read the developer's saved model or API key.
- **`Docs/bugs.md` file paths predate the refactors** (`Views/` → `UI/`, `SSH/` → `Services/SSH/`,
  `Services/Security/` → `Services/`; some files no longer exist). Resolve by basename before
  trusting an entry. Open/fixed counts are in its Summary table.
- **Docs directory case**: git tracks 23 files under `Docs/` and 4 under `docs/`
  (`FutureFeatures.md`, `Optimization.md`, `RefactorTheFinalRun.md`, `screenshots/`). This only works
  because macOS is case-insensitive — a case-sensitive checkout splits them. Resolve by basename.

---

## Reference Docs

| Doc | Purpose |
|-----|---------|
| `Docs/featurelist.md` | **Long-term memory** — dated work log, phase progress, loop-log entries |
| `Docs/RenderCost.md` | **Active spec.** What rendering actually costs — R0/R1/R2a done, **R2b open** (code merged, performance unvalidated). Read its "Measurement caveats" before any perf measurement |
| `Docs/R2bBenchmarkResults.md` | R2b A/B evidence: exact commands and all raw reports for the six baseline/candidate pairs |
| `Docs/Bug84.md` | **Queued.** One terminal renderer per session across tab switches and split changes (per-session model store) — Phase 0 next |
| `Docs/bugs.md` | Bug and tech-debt register by subsystem/severity (counts in its Summary table); paths are pre-refactor |
| `Docs/PhaseB.md` | Local Input V2 Phase B checklist (make byte-first local input the only path) — open |
| `Docs/OpenRouterArchitecture.md` | Current OpenRouter AI architecture, settings, transcript, and verification |
| `docs/FutureFeatures.md` | Prioritized feature roadmap (competitive analysis) |
| `docs/Optimization.md` | Performance bottleneck analysis, benchmark commands, current numbers |
| `Docs/FasterThenYouWillEverLiveToBe.md` | Throughput gap profiling — Phases 0,1,2,3,5 done. **Phase 4 is abandoned, not optional**: `parse + grid` was never the constraint |
| `Docs/optimizationspart2.md` | Throughput recovery playbook (Part 2) |
| `Docs/OptimizeP2.md` / `Docs/OptimizeP3.md` | P2 / P3 optimization phased checklists — **COMPLETE** |
| `Docs/AIpatchfeatureIntegration.md` | `apply_patch` integration guide |
| `Docs/RemotePatchingFix.md` | Remote patching fix (base64 read/write approach) |
| `Docs/Issue15.md` | Multi-session broadcast input routing |
| `Docs/AIBroadCaster.md` | AI Broadcaster — session-aware agent for multi-pane broadcast |
| `Docs/BlackTextRenderingFix.md` | Black text rendering fix (issue #9) |
| `Docs/FixTerminalCopyAndSelection.md` | Terminal copy/selection fix (issue #22) |
| `Docs/IntegrationOfNewFeats.md` | Pre-built module integration guide (TOTP 2FA, etc.) |
| `Docs/Issue11.md` | Visual jitter fix — **COMPLETE** (Phases 0–5) |
| `Docs/TextGlow.md` | Bloom / Text Glow — **COMPLETE** (Phases 0–7) |
| `Docs/SmoothScroll.md` | Smooth Scrolling — **COMPLETE** (Phases 0–6) |
| `Docs/RefactorMetalTerminalRenderer.md` | Renderer split into 8 extensions — **COMPLETE** |
| `docs/RefactorTheFinalRun.md` | 4 god files decomposed — **COMPLETE** (Phases 0–19) |
| `RefactorTerminalView.md` / `RefactorTerminalGrid.md` (repo root) | `UI/Terminal/` split and 11 `TerminalGrid+*` extensions — **COMPLETE** |
| `Docs/multiprovider-architecture.md` | Superseded historical multi-provider design |

The strict-concurrency refactor (RefactorTheActor, which produced `Services/SSH/`, `Services/AI/`
and the session coordinators) has no spec file left; see `Docs/featurelist.md`.

---

## Next Session Plan

**Active work: `Docs/RenderCost.md` R2b — explain or bound the throughput variability.**
R2b (fewer engine actor calls per batch and per publish) is merged on `master` but unvalidated:
both it and baseline `af933f4` are bimodal, and every instrumentation-off A/B pair median favored
the baseline (0.88x, 0.29x, 0.87x), so a regression is possible. Don't reimplement it — the change
list is in `Docs/RenderCost.md` and the raw reports in `Docs/R2bBenchmarkResults.md`.

1. Run `--render-detached --perf-scheduling` on a Release build, several launches, recording
   `sysctl -n vm.loadavg` and top CPU consumers. In slow runs, does ground-text CPU stay flat while
   wall grows (scheduling/placement) or does CPU itself grow (real work)? Correlate with burst
   transitions and batch-size distribution.
2. Only with that evidence, choose between tuning the publish intervals / burst thresholds (see
   Publish cadence above) and reverting R2b. Leave visible-text extraction alone (<0.4%).
3. Repeat interleaved Release A/B against `af933f4` under identical launch/window/instrumentation
   conditions. Restore genuine window acquisition before any rendered or peer-comparable claim.
4. Close R2b when the variability is explained or bounded; update `Docs/featurelist.md`,
   `Docs/RenderCost.md` and this plan.

**Terminal selection and surface follow-ups** (Bugs 82 and 85 fixed and verified live). Queued, in order:
1. `Docs/Bug84.md` Phase 0 — measure which layout changes still rebuild the surface, and renderer memory.
2. Bug 83 (registry audit), then Bug 80 (one shared copy path — Bug 84 Phase 3 may absorb it).
All in `Docs/bugs.md`.

**Pending live checks (need a relaunched app and a user at the keyboard):**
- Shift+Enter: inserts a newline at a plain zsh prompt and is distinguished inside Claude Code;
  not yet exercised over a live SSH session or in bash.
- Reasoning panel: the native TextKit renderer was never validated live against the original
  second-turn wrapping glitch (the screenshot predated the build).
- OpenRouter: tool-wrapper hiding, table rendering and paragraph spacing in the running app;
  compare GLM 5.3 Flash against a stronger model once a test key is available.

Unrelated open work: `Docs/bugs.md`, `Docs/PhaseB.md`, the `Docs/` vs `docs/` case split, and a
first full-suite baseline on Xcode 27.
