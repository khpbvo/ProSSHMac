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
- Feature specs hold **what to do and how**. Each phase has a `- [ ]` checkbox, checked off when completed.

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

- Test bundle: `ProSSHMacTests` — 4 files at the bundle root plus 47 in `ProSSHMacTests/Terminal/Tests/`.
  Migration out of the app target is **complete**; no test sources remain under `ProSSHMac/`.
- Some tests require the host app process (UI/AppKit-backed suites).
- **Full-suite baseline: 883 tests, 1 failure** — see the flaky-test gotcha below. The last
  clean full-suite run recorded 870/0 on 2026-09-03, before later tests were added. A red run in a
  suite you touched is yours; a red `SessionManagerRenderingPathTests` under full-suite load is not.
- Tests must not depend on the developer's real `UserDefaults`. `LLMProviderRegistry` takes an
  injectable `userDefaults:`; agent tests build one via `makeIsolatedOpenAIRegistry()` in
  `AIAgentServiceTests.swift`. Follow that pattern for any new defaults-backed type.
- **Throughput baseline, Release** (state the configuration with every number — Release is ~20x
  Debug, and never compare across the two):

  | Path | MB/s | Measured |
  |---|---|---|
  | Parser/grid, 2 MB (`--benchmark-base64`) | **36.4-37.3** | 2026-09-04 |
  | PTY -> `engine.feed` (`--pty-local`) | **19.20** | 2026-09-03 |
  | Real app path, 8 MB (`--render-detached`, **no window**) | **3.80-5.01** | 2026-09-04, post-R2a |
  | Terminal.app (peer, with rendering) | 26.5 | 2026-09-03 |

  The real-app figure is post-R2a and windowless; R1's windowed figures (0.14 detached /
  0.03-0.05 rendered at 1100x750) could not be reproduced. **Read `Docs/RenderCost.md`
  "Measurement caveats" before trusting or recording any rendered number.**
- **Target is no longer 89 MB/s.** That was a pipe baseline with no terminal emulation. Measured
  peers on this machine (6 MB, with rendering): Terminal.app **26.5 MB/s**, iTerm2 ~1.4 MB/s.
  Current target: match or beat Terminal.app end-to-end. Reproduce with
  `./scripts/benchmark-peer-emulator.sh`. See `docs/Optimization.md`.
- **Perf instrumentation:** `TerminalPerf` (`Terminal/Diagnostics/TerminalPerf.swift`) gates five
  signposts and **19 in-process stage timers** behind `--perf-signposts` / `PROSSH_PERF_SIGNPOSTS=1`
  / `terminal.perf.signposts`. Pass `--perf-signposts` to `benchmark-throughput.sh` to print a stage
  budget. Off by default and verified free (parser/grid unchanged at 36.4-37.3 MB/s with it linked in).
  The budget reports **time, %wall, span, busy% and start offset** per stage: span is first-start to
  last-end, busy is time/span. A stage spanning the whole run at low busy% is **blocked, not slow** —
  that column is what finally attributed R1's missing 18 s. Several stages are deliberate
  caller/callee pairs (`feedCall` vs `parse`, `publish` vs `publishEngineWait`); the difference
  between a pair is actor-hop and queue wait rather than work.

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
│   │                     #   ZshStartupWarningFilter,
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
│   ├── Diagnostics/      # TerminalPerf (runtime-gated signposts + stage timers)
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

All paths relative to repo root, under `ProSSHMac/`. Line counts as of 2026-09-06.

| File / Group | What it does |
|---|---|
| `Services/AI/AIToolHandler.swift` + 5 extensions | Tool dispatch (1,119L) — largest file. Extensions: ArgumentParsing, RemoteExecution, LocalFilesystem, InteractiveInput, OutputHelpers |
| `UI/Terminal/TerminalView.swift` | Main terminal UI, sidebar layout, focus, input capture (1,066L) |
| `Services/SessionManager.swift` + Queries | Session lifecycle, shell I/O, SFTP, grid snapshots (1,017L) |
| `UI/Terminal/TerminalAIAssistantPane.swift` | AI copilot sidebar, composer, message rendering (966L) |
| `Services/TerminalRenderingCoordinator.swift` | Snapshot publishing, scroll state, resize debounce, alt-buffer policy (972L). `publishGridState` + `publishHousekeeping` make ~7 engine round-trips per publish — the R2b target |
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
| `Services/SessionShellIOCoordinator.swift` | Shell input, the batched parser reader, per-batch bookkeeping (330L). The four post-`feed` engine round-trips here are 46.7% of wall — the R2b target |
| `Services/AI/AIAgentRunner.swift` | Agent iteration loop, direct-action mode, provider mismatch (249L) |
| `Terminal/Renderer/TerminalMetalView.swift` | NSViewRepresentable wrapping MTKView, gesture recognizers (239L) |
| `ViewModels/AIProviderSettingsViewModel.swift` | Multi-provider settings VM (236L) |
| `Services/LocalShellBootstrap.swift` | Child env for local PTY, ZDOTDIR/BASH_ENV injection (202L) |
| `ViewModels/TerminalAIAssistantViewModel.swift` | AI sidebar VM: messages, streaming, patch approval (379L) |
| `UI/Terminal/PatchApprovalCardView.swift` | Inline patch approval card for `apply_patch` (177L) |
| `App/ThroughputBenchmarkRunner.swift` | Parser/grid + PTY-local benchmarks, `BenchmarkSentinelMatcher`, stage-budget print |
| `Terminal/Diagnostics/TerminalPerf.swift` | Runtime-gated signposts + 19 in-process stage timers with span/busy tracking (233L). Start here for any perf work |
| `App/ThroughputBenchmarkRunner+Render.swift` | End-to-end benchmark through the real app path (413L): `--benchmark-render`, `--benchmark-render-detached`, `--benchmark-window WxH`, windowless warning |
| `Terminal/Features/TerminalHistoryIndex.swift` | Command blocks, prompt heuristics, output capture (484L). Raw output is a bounded UTF-8 byte buffer — see gotchas before touching `recordOutputChunk` |
| `Services/ZshStartupWarningFilter.swift` | Bounded zsh startup-warning filter for the PTY path (120L) |
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
  Provider-agnostic types in `LLMTypes.swift`. See `Docs/multiprovider-architecture.md`.
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
  used on ~18 types (coordinators, `SessionManager`, `PaneManager`, `SessionTabManager`,
  `AIToolHandler`, `AIAgentRunner`, `TerminalAIAssistantViewModel`, `V4AParserState`, …).

---

## Known Issues & Gotchas

- **This file was truncated once and nobody noticed for two sessions.** Commit 2c99912 cut it from
  422 lines to 96, dropping Project Overview, Build & Test, Project Structure, Key Files,
  Architecture Conventions, this section, Completed Refactors and Reference Docs — leaving only the
  workflow header and a Next Session Plan, with the sentence introducing that plan cut mid-word.
  Restored 2026-09-06 from 2c99912^. When you edit the Next Session Plan, replace only the text
  below the `## Next Session Plan` heading.

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
- **`SessionManagerRenderingPathTests.testLocalSessionStreamsProgressiveCommandOutput` is
  load-flaky.** It spawns a real `/bin/zsh` and waits 8s for output. Measured 2026-09-06 on an
  unchanged tree: **0.689s passing alone**, 21/21 green running its own suite twice, and **8.094s
  timing out** when four suites run in one `xcodebuild test` invocation. It is not only full-suite
  load — four suites is enough. Last full-suite figure: 883 tests, 1 failure, this one. Treat a
  failure as environment; confirm by re-running the suite alone before believing a regression.
- **The rendered benchmark gets no window when launched with arguments.** `open -n App.app` restores
  a window; `open -n App.app --args <anything at all>` yields a process with `NSApp.windows.count ==
  0` — a harmless unused flag reproduces it, and `applicationShouldHandleReopen` does not recover it.
  `--benchmark-render` then silently measures the detached path. The runner warns loudly now; if you
  see that warning, the number is not comparable to any windowed run. Fixing window acquisition
  unblocks the window-scaling test and the render-vs-detached delta, both still unmeasured.
- **Benchmark numbers drift across a session; only interleaved A/B is trustworthy.** The identical
  baseline binary measured 2.86 MB/s early in a session and 0.92 MB/s hours later at a comparable
  load average, and a `mediaanalysisd` pass (300% CPU) made it 7x slower again with 100x spreads
  inside one launch. Never compare a number against one taken at a different time. Build both
  binaries, alternate launches, and compare within a pair. Check `sysctl -n vm.loadavg` and the top
  CPU consumers first, and record the load with the result.
- **`TerminalHistoryIndex` raw output is UTF-8 bytes, deliberately.** It is appended once per output
  batch and read once per command completion. As a `String` capped on every append it cost four O(n)
  passes over 120k characters per call — a COW copy, two grapheme-cluster `String.count`s and an O(n)
  `removeFirst` — and measured **89% of wall** on the real reader path. Do not reintroduce
  `String.count`, `removeFirst`, or a `var state = sessionStates[id]` copy on that path; the length
  must stay O(1), the trim amortized, and the character cap applied at read time.
- **`recordParsedChunk` runs once per 4 ms batch, not per raw chunk.** It is `@MainActor`, so
  per-chunk it cost ~1290 hops per MB. Everything it does concatenates, so batching is equivalent.
  Do not move it back into the accumulator loop.
- **SourceKit false positives**: "Cannot find type" errors across files. Always verify with
  `xcodebuild build`.
- **Bugs doc is stale**: `Docs/bugs.md` lists 79 numbered bugs, 29 already marked `[FIXED]` — so **50
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
- **Docs directory case**: git tracks **21 files under `Docs/`** and **4 under `docs/`**
  (`FutureFeatures.md`, `Optimization.md`, `RefactorTheFinalRun.md`, `screenshots/`). This only works
  because macOS is case-insensitive — a case-sensitive checkout will split them into two directories.
  Paths in this file are written as the docs themselves reference them; resolve by basename.

---

## Completed Refactors

| Refactor | Phases | Key output | Spec |
|---|---|---|---|
| RefactorTheActor (Strict Concurrency) | 0-8 | `Services/SSH/`, `Services/AI/`, session coordinators | spec file no longer in repo; see `Docs/featurelist.md` |
| RefactorTerminalView | 0-9 | `UI/Terminal/` split into 21 components | `RefactorTerminalView.md` (repo root) |
| RefactorTerminalGrid | 0-11 | 11 `TerminalGrid+*.swift` extensions | `RefactorTerminalGrid.md` (repo root) |
| RefactorMetalTerminalRenderer | 0-8 | 8 `MetalTerminalRenderer+*.swift` extensions | `Docs/RefactorMetalTerminalRenderer.md` |
| RefactorTheFinalRun | 0-19 | 4 god files decomposed | `docs/RefactorTheFinalRun.md` |
| Test migration | — | All tests now in `ProSSHMacTests/` (none under app sources) | `Docs/featurelist.md` |

---

## Reference Docs

| Doc | Purpose |
|-----|---------|
| `Docs/featurelist.md` | **Long-term memory** — dated work log, phase progress, loop-log entries |
| `Docs/bugs.md` | Bug audit by subsystem/severity — 50 of 79 still open; paths are pre-refactor |
| `docs/FutureFeatures.md` | Prioritized feature roadmap (competitive analysis) |
| `docs/Optimization.md` | Performance bottleneck analysis, benchmark commands, current numbers |
| `Docs/RenderCost.md` | **Active spec.** What rendering actually costs — R0/R1/R2a done, **R2b open**. Read its "Measurement caveats" before any perf measurement |
| `Docs/FasterThenYouWillEverLiveToBe.md` | Throughput gap profiling — Phases 0,1,2,3,5 done. **Phase 4 is abandoned, not optional**: it proposed optimising `parse + grid`, which measures 0.1-24% depending on configuration but was never the constraint |
| `Docs/optimizationspart2.md` | Throughput recovery playbook (Part 2) |
| `Docs/OptimizeP2.md` / `Docs/OptimizeP3.md` | P2 / P3 optimization phased checklists — **COMPLETE** |
| `Docs/PhaseB.md` | Local Input V2 Phase B checklist (make byte-first local input the only path) |
| `Docs/multiprovider-architecture.md` | Multi-provider LLM architecture overview |
| `Docs/AIpatchfeatureIntegration.md` | `apply_patch` integration guide |
| `Docs/RemotePatchingFix.md` | Remote patching fix (base64 read/write approach) |
| `Docs/Issue15.md` | Multi-session broadcast input routing |
| `Docs/AIBroadCaster.md` | AI Broadcaster — session-aware agent for multi-pane broadcast |
| `Docs/BlackTextRenderingFix.md` | Black text rendering fix (issue #9) |
| `Docs/FixTerminalCopyAndSelection.md` | Terminal copy/selection fix (issue #22) |
| `Docs/IntegrationOfNewFeats.md` | Pre-built module integration guide (TOTP 2FA, etc.) |
| `Docs/Issue11.md` | Visual jitter fix — phased checklist (Phases 0–5) |
| `Docs/TextGlow.md` | Bloom / Text Glow — **COMPLETE** (Phases 0–7) |
| `Docs/SmoothScroll.md` | Smooth Scrolling — **COMPLETE** (Phases 0–6) |

Note: `AGENTS.md` (repo root) is a parallel working-memory file for non-Claude assistants and points
at `Docs/featurelist.md`. Keep it in sync when process guidance changes.

---

<!-- NEXT SESSION PLAN -->

## Next Session Plan

**Last completed milestone (2026-09-06/07): RenderCost R2b implementation and focused verification.**
R2b stays open for the throughput-variability investigation; do not reimplement the actor-call changes.

- `TerminalEngine.feedAndCollectOutcome(Data)` preserves ordinary `feed`'s Bool/queueing contract
  while collecting modes, sync exits and the live sync fallback frame for the streaming reader.
  `handleFeedOutcome` applies them in one MainActor handoff with no post-feed engine reads.
- `publishViewportState` then `publishSnapshot` leave scroll-anchor policy on MainActor.
  Ordinary publishes include housekeeping in the second result. The drain loop collects
  housekeeping once after the final snapshot, preserving bell consumption and throttled text.
- Metadata is applied before history observation awaits, avoiding a stale-mode overwrite.
- `visibleTextScan` now sums extraction and observation separately (two timer calls per refresh).
  Outcome collection is inside `feedCall`; ordinary-publish collection is in `publishEngineWait`.
- Debug and Release builds succeeded. Focused tests: **167 tests, 0 failures, 2 instrumentation-only
  skips**: rendering 21, parser 125, history 8, perf 7, benchmark 6. No full-suite run or claim.

**Starting point for the next task:** fresh baseline `af933f4` and the R2b candidate both remain
bimodal. Three instrumented interleaved pairs gave median to-sentinel ratios **5.01x, 0.33x,
1.02x**. In a single unchanged candidate launch, parse/grid elapsed time rose from ~270 ms to
780 ms while to-sentinel throughput fell from ~19 to 5.88 MB/s. Direct launch with instrumentation
off also varies, so neither signposts nor LaunchServices alone explains it. All three direct/off
pair medians favor baseline (0.88x, 0.29x, 0.87x); a performance regression cannot be ruled out. All runs had zero
windows; no real rendered-throughput claim is supported.

**Next actions / end point:**
1. Read `Docs/RenderCost.md` and `Docs/R2bBenchmarkResults.md`, including all pairs, not just the
   first apparent win. Preserve the current changes and inspect git status before proceeding.
2. Distinguish CPU work from scheduler suspension: add opt-in thread CPU versus wall timing around
   synchronous `grid.processGroundTextBytes` calls (not across async suspension/thread migration).
   Correlate with burst entry/revert counts, batch sizes, process activity and host load.
3. Establish whether the slow regime is scheduler/CPU placement or application scheduling before
   changing the 8/16/24/40 ms publish intervals or burst thresholds. Leave visible-text extraction
   alone unless new evidence changes its ranking; it remained below 0.4% in the candidate.
4. Compare interleaved Release runs with identical launch/window/instrumentation conditions.
   Restore genuine window acquisition before claiming rendered or peer-comparable throughput.
5. Close R2b only when the remaining variability is explained or bounded enough for a repeatable
   comparison; update `Docs/featurelist.md`, `Docs/RenderCost.md`, this plan and `AGENTS.md`.

Build/test logs and comparison bundles are `/tmp/prossh-r2b-baseline*` and
`/tmp/prossh-r2b-candidate*`; raw reports and the exact reproduction commands are preserved in
`Docs/R2bBenchmarkResults.md`. `/tmp` files are conveniences, not durable evidence.

Unrelated open work remains in `Docs/bugs.md`, `Docs/PhaseB.md` and the `Docs/` vs `docs/` case split.
