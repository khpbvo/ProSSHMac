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

Key capabilities:
- Metal-rendered terminal (custom glyph atlas, GPU cell buffer, cursor animation)
- SSH connections via libssh (C wrapper in `CLibSSH/`)
- Local shell sessions via PTY (`LocalPTYProcess` + `LocalShellBootstrap`)
- SFTP file browser sidebar (left, toggle `Cmd+B`)
- AI Terminal Copilot sidebar (right, toggle `Cmd+Opt+I`) — multi-provider LLM support
- Pane splitting, session tabs, broadcast input routing, session recording/playback
- KeyForge (SSH key generation), certificate management, port forwarding
- Visual effects: CRT scanlines, barrel distortion, gradient glow, matrix screensaver
- AI tools: `apply_patch` (V4A diff), `send_input` (interactive prompts), broadcast-aware execution

---

## Build & Test

```bash
# Build
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build

# Run all tests
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test

# Run specific test suite
xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test -only-testing:ProSSHMacTests/<TestClassName>
```

- Test bundle: `ProSSHMacTests`. Most test files still compiled under app sources (migration ongoing).
- Known: some tests require host app process; 2 pre-existing test failures (unrelated baseline).

---

## Project Structure

```
ProSSHMac/
├── App/                  # App entry, dependencies, navigation coordinator
├── CLibSSH/              # C wrapper around libssh (ProSSHLibSSHWrapper.c/.h)
├── Models/               # Host, Session, Transfer, SSHKey, SSHCertificate, AuditLogEntry
├── Services/             # SessionManager, TransferManager, EncryptedStorage, PortForwardingManager,
│   │                     #   LocalPTYProcess, LocalShellBootstrap,
│   │                     #   OpenAIResponsesPayloadTypes, OpenAIResponsesStreamAccumulator
│   ├── SSH/              #   LibSSHTransport, MockSSHTransport, SSHCredentialResolver, RemotePath
│   ├── AI/               #   AIToolHandler, AIAgentRunner, AIToolDefinitions, ApplyPatchTool
│   └── LLM/             #   LLMTypes, LLMProvider, LLMProviderRegistry, LLMAPIKeyStore
│       └── Providers/    #   ChatCompletionsClient, Mistral/Ollama/Anthropic/DeepSeek providers
├── Terminal/
│   ├── Grid/             # TerminalGrid + 11 extensions, TerminalCell, ScrollbackBuffer
│   ├── Parser/           # VT parser, CSIHandler, OSCHandler, SGRHandler, ESCHandler, DCSHandler
│   ├── Input/            # KeyEncoder, MouseEncoder, HardwareKeyHandler, LocalTerminalSubsystem
│   ├── Renderer/         # MetalTerminalRenderer + 8 extensions, GlyphAtlas, CellBuffer, Shaders.metal
│   ├── Effects/          # CRT, gradient, scanner, blink, transparency, bell, PromptAppearance
│   └── Features/         # PaneManager, SessionTabManager, TerminalSearch, QuickCommands, SessionRecorder
├── UI/
│   ├── Terminal/         # TerminalView (1,002L), TerminalAIAssistantPane, MetalTerminalSessionSurface,
│   │                     #   TerminalInputCaptureView, ExternalTerminalWindowView, PatchApprovalCardView
│   ├── Hosts/            # HostsView, HostFormView
│   ├── Transfers/        # TransfersView
│   ├── Settings/         # SettingsView + effect settings subviews
│   ├── KeyForge/         # KeyForgeView, KeyInspectorView
│   └── Certificates/     # CertificatesView, CertificateInspectorView
├── ViewModels/           # HostListVM, KeyForgeVM, CertificatesVM, AIProviderSettingsVM, TerminalAIAssistantVM
└── Platform/             # PlatformCompatibility (macOS/iOS shims)
```

---

## Key Files

All paths relative to repo root, under `ProSSHMac/`.

| File / Group | What it does |
|---|---|
| `UI/Terminal/TerminalView.swift` | Main terminal UI, sidebar layout, focus, input capture (1,002L) |
| `UI/Terminal/TerminalAIAssistantPane.swift` | AI copilot sidebar, composer, message rendering (~781L) |
| `UI/Terminal/PatchApprovalCardView.swift` | Inline patch approval card for `apply_patch` |
| `UI/Terminal/MetalTerminalSessionSurface.swift` | SwiftUI-Metal bridge, snapshot application, selection |
| `UI/Terminal/TerminalInputCaptureView.swift` | NSViewRepresentable keyboard bridge for local sessions (~423L) |
| `UI/Terminal/ExternalTerminalWindowView.swift` | Separate-window terminal session view (~316L) |
| `Terminal/Renderer/MetalTerminalRenderer.swift` + 8 extensions | Metal renderer (331L): glyph resolution, snapshot update, font management, draw loop, view config, selection, post-processing, diagnostics |
| `Terminal/Renderer/TerminalMetalView.swift` | NSViewRepresentable wrapping MTKView, gesture recognizers |
| `Terminal/Grid/TerminalGrid.swift` + 11 extensions | Grid state (457L): modes, OSC, tabs, cursor, scroll, erase, line ops, screen buffer, lifecycle, printing, snapshot |
| `Services/SessionManager.swift` + Queries | Session lifecycle, shell I/O, SFTP, grid snapshots (969L) |
| `Services/Session*Coordinator.swift` (7 files) | Extracted coordinators: AITool, SFTP, ShellIO, Reconnect, Keepalive, Rendering, Recording |
| `Services/SSH/LibSSHTransport.swift` | LibSSH transport actor (~797L) |
| `Services/OpenAIAgentService.swift` | Agent-layer protocols, provider routing (~290L) |
| `Services/AI/AIToolHandler.swift` + 4 extensions | Tool dispatch (~503L), arg parsing, remote exec, local filesystem, output helpers |
| `Services/AI/AIToolDefinitions.swift` | Developer prompt, tool schemas (~373L) |
| `Services/AI/AIAgentRunner.swift` | Agent iteration loop, timeout, provider mismatch (~195L) |
| `Services/AI/ApplyPatchTool.swift` | PatchApprovalTracker, LocalWorkspacePatcher, RemotePatchCommandBuilder (~456L) |
| `Services/AI/UnifiedDiffPatcher.swift` | V4A unified diff parser and applicator (~370L) |
| `Services/LLM/` (4 files) | LLMTypes, LLMProvider protocol, LLMProviderRegistry, LLMAPIKeyStore |
| `Services/LLM/Providers/` (5 files) | ChatCompletionsClient, Mistral/Ollama/Anthropic/DeepSeek providers |
| `Services/LocalPTYProcess.swift` | Actor wrapping forkpty, async output stream (~302L) |
| `Services/LocalShellBootstrap.swift` | Child env for local PTY, ZDOTDIR/BASH_ENV injection (~203L) |
| `ViewModels/TerminalAIAssistantViewModel.swift` | AI sidebar VM: messages, streaming, patch approval (~379L) |
| `ViewModels/AIProviderSettingsViewModel.swift` | Multi-provider settings VM (~175L) |
| `Terminal/Features/PaneManager.swift` | Split-pane tree, input routing, broadcast/solo mode |

---

## Architecture Conventions

- **ObservableObject + @StateObject** throughout (not `@Observable`).
- **Metal rendering**: `MTKView` display-link auto-pauses when idle (`isPaused = true` in draw loop early-exit). Cursor blink driven by a ~15fps `Task` loop in `MetalTerminalRenderer+ViewConfiguration.swift`. Dirty flag skips redundant draws.
- **Grid snapshot flow**: `TerminalGrid.snapshot()` → `SessionManager` nonce++ → SwiftUI `.onChange` → `MetalTerminalRenderer.updateSnapshot()` → `isDirty = true`.
- **Terminal keyboard input**: `DirectTerminalInputNSView` (transparent NSView overlay, `hitTest` returns `nil`).
- **Focus management**: `isAIAssistantComposerFocused` state. `focusSessionAndPane()` resigns at AppKit level, then re-arms terminal. See Known Issues.
- **AI service stack**: `OpenAIAgentService.sendProviderRequest()` routes by `providerRegistry.activeProviderID`. OpenAI → Responses API; others → `LLMProvider` protocol. Provider-agnostic types in `LLMTypes.swift`. See `docs/multiprovider-architecture.md`.
- **AI agent tools**: 11 tools (9 primary + `apply_patch` + `send_input`). Error format: `{ok:false, error, hint}`. Max iterations: 50 (app: 200). See `AIToolDefinitions.swift`.
- **`apply_patch` remote flow**: base64 read → V4A in-process diff → base64 heredoc write. See `docs/RemotePatchingFix.md`.
- **`nonisolated` on TerminalGrid extensions**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes extension methods default to `@MainActor`. All `TerminalGrid+*.swift` methods MUST be explicitly `nonisolated`.
- **Coordinator pattern**: `SessionManager` delegates to 7 `@MainActor final class` coordinators, each with `weak var manager`.
- **Input routing**: `InputRoutingMode` (.singleFocus/.broadcast/.selectGroup) in `PaneManager`. Solo mode: Option+Click in broadcast → single-pane input. `Cmd+Shift+B` toggles broadcast/ends solo. See `docs/Issue15.md`.
- **AI broadcast**: `BroadcastContext` threads through ViewModel → AgentService → Runner → ToolHandler. `target_session` on all tools. See `docs/AIBroadCaster.md`.
- **Local PTY**: `LocalPTYProcess` (actor, forkpty) + `LocalShellBootstrap` (env, ZDOTDIR). `LocalTerminalSubsystem` translates NSEvent → PTY bytes.
- **`nonisolated deinit`**: Required on types with actor-isolated context that may deallocate in non-task contexts (`V4AParserState`, `SessionTabManager`, `PaneManager`).

---

## Known Issues & Gotchas

- **TerminalView.swift** (1,002L) is the largest UI file. Read surrounding context before modifying.
- **Focus management** between AI composer (NSTextView) and terminal (DirectTerminalInputNSView) is delicate. Must resign at AppKit level, not just SwiftUI state. See `focusSessionAndPane()`.
- **SwiftUI state mutations during `updateNSView`** cause warnings. Use `DispatchQueue.main.async` or `Task { @MainActor in await Task.yield() }` deferral.
- **SourceKit false positives**: "Cannot find type" errors across files. Always verify with `xcodebuild build`.
- **Bugs doc**: `docs/bugs.md` has a 68-bug audit by subsystem/severity. Check before working on a subsystem.
- **Terminal selection**: `selectedText()` skips wide-char continuation cells. Click-to-deselect in `TerminalSurfaceView.onTap`. `handleDrag` processes `.ended`/`.cancelled` before `gridCell(at:)` guard.

---

## Completed Refactors

| Refactor | Phases | Key output | Spec |
|---|---|---|---|
| RefactorTheActor (Strict Concurrency) | 0-8 | `Services/SSH/`, `Services/AI/`, 4 session coordinators | `RefactorTheActor.md` |
| RefactorTerminalView | 0-9 | `UI/Terminal/` split into 11+ components | `RefactorTerminalView.md` |
| RefactorTerminalGrid | 0-11 | 11 `TerminalGrid+*.swift` extensions | `RefactorTerminalGrid.md` |
| RefactorMetalTerminalRenderer | 0-8 | 8 `MetalTerminalRenderer+*.swift` extensions | `docs/RefactorMetalTerminalRenderer.md` |
| RefactorTheFinalRun | 0-19 | 4 god files decomposed; `SessionManager.swift` → 969L | `docs/RefactorTheFinalRun.md` |

---

## Reference Docs

| Doc | Purpose |
|-----|---------|
| `docs/featurelist.md` | **Long-term memory** — dated work log, phase progress, loop-log entries |
| `docs/bugs.md` | 68-bug audit by subsystem and severity |
| `docs/FutureFeatures.md` | Prioritized feature roadmap (competitive analysis) |
| `docs/Optimization.md` | Performance bottleneck analysis and fixes |
| `docs/multiprovider-architecture.md` | Multi-provider LLM architecture overview |
| `docs/RemotePatchingFix.md` | Remote patching fix (base64 read/write approach) |
| `docs/Issue15.md` | Multi-session broadcast input routing |
| `docs/AIBroadCaster.md` | AI Broadcaster — session-aware agent for multi-pane broadcast |
| `docs/BlackTextRenderingFix.md` | Black text rendering fix (issue #9) |
| `docs/FixTerminalCopyAndSelection.md` | Terminal copy/selection fix (issue #22) |
| `docs/IntegrationOfNewFeats.md` | Pre-built module integration guide (TOTP 2FA, etc.) |
| `docs/Issue11.md` | Visual jitter fix — phased checklist (Phases 0–5) |
| `docs/TextGlow.md` | Bloom / Text Glow — **COMPLETE** (Phases 0–7) |
| `docs/SmoothScroll.md` | Smooth Scrolling — **COMPLETE** (Phases 0–6) |

---

## Next Session Plan

<!-- NEXT SESSION PLAN -->
**All OptimizeP2 and OptimizeP3 phases complete.**

Completed today:
- P3 Phase 4: Blur optimization — hide `NSVisualEffectView` when fully opaque
- P3 Phases 1, 2, 3, 5, 6, 7: Marked as already done (previously implemented or negligible impact)

Next steps:
- Pick from `docs/bugs.md` (68-bug audit) or `docs/FutureFeatures.md` (feature roadmap)
- Consider running full benchmark suite to capture post-optimization numbers

Manual QA for blur optimization:
- Set background opacity to 100% — verify no blur GPU usage
- Set background opacity to 80% — verify blur effect renders correctly
- Toggle opacity back to 100% — verify blur hides again
<!-- /NEXT SESSION PLAN -->
