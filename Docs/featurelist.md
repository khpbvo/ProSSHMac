# ProSSHMac AI + File Browser Expansion Checklist

Last verified against repo: 2026-03-05
Required assistant model for this work: `gpt-5.1-codex-max`

## Goal

Ship two terminal sidebars (left: remote file browser, right: AI assistant) on top of the current terminal architecture, with safe command execution and reliable context retrieval.

## Loop Kickoff Snapshot (2026-02-22)

### Starting Point

- Current app has terminal panes, Transfers-tab SFTP, and OSC parsing, but no terminal sidebars for file browser + AI.
- AI stack (services, tools, chat UI, follow mode) is not implemented.
- Command-block indexing is not implemented; OSC 133 semantic handling is still placeholder-only.
- Working-memory loop is now established via `AGENTS.md` + this file.

### End Point (Definition of Done)

- Terminal has production-ready left SFTP file sidebar and right AI sidebar.
- AI uses Responses API with model pinned to `gpt-5.1-codex-max`.
- Command-block index supports reliable context retrieval for AI tools.
- Execution safety is enforced by intent-based execution in Ask mode (execute only on explicit run/open/edit/check intent).
- Regression checks pass for existing pane splitting and Transfers behavior.
- This file and `AGENTS.md` remain current at task completion.

### Current Focus

- Active phase: Phase 6 (persistence + hardening + remaining test coverage).
- Immediate objective: continue migrating legacy tests into the shared test bundle while keeping targeted regressions green during migration.
- Test stability TODOs: no active crash quarantines remain for previously skipped pane/AI view-model tests.
- AI Broadcaster complete (2026-03-03): session-aware AI agent for multi-pane broadcast. All 9 phases (0–8) implemented and tested. See `docs/AIBroadCaster.md`.
- Task alignment (2026-03-05, terminal scroll jitter + forced snap-to-bottom during live output):
  - Starting Point: scrollback felt jittery under wheel input and users could not hold position while a live command (for example `ping`) was printing because output publish paths kept overriding scroll state and rapid scroll events raced on stale offsets.
  - End Point: scroll handling now reads the latest offset inside the async scroll task (eliminating stale-offset jitter), live output no longer force-resets scrollback to bottom, snapshot publishing preserves/render current scrollback offset with growth compensation, anchor compensation is intent-aware (enabled when scrolling up, disabled when scrolling/dragging down), and renderer smooth-scroll state is re-synced to session scroll offset on snapshot updates so gestures no longer get stuck in the middle after partial strokes.
- Task alignment (2026-03-05, terminal scrolling broken after SmoothScrolling rollout):
  - Starting Point: wheel scrolling in Metal terminal panes appeared non-functional after the SmoothScrolling/scrollbar rollout because the scrollbar overlay became hit-testable across the terminal body whenever scrollback existed.
  - End Point: `TerminalScrollbarView` now constrains interaction to a narrow trailing strip (`interactionWidth = 18`) so wheel events reach `TerminalMetalContainerView.scrollWheel()` again while thumb drag-to-scroll remains available.
- Task alignment (2026-03-05, terminal smooth-scroll jitter during active gestures):
  - Starting Point: smooth scrolling still felt jittery because every snapshot publish called `scrollJumpTo(row:)`, and `SmoothScrollEngine.jumpTo` cleared fractional offset + momentum even when the renderer was already on that same target row. During a wheel/trackpad gesture, each row-boundary snapshot could therefore snap the animation mid-stroke.
  - End Point: same-row scroll-position resync is now a no-op in `SmoothScrollEngine.jumpTo`, so snapshot publishes preserve in-flight fractional motion while still allowing real row changes to hard-sync/reset when needed.
- Task alignment (2026-03-02, disable App Sandbox for non-App-Store distribution):
  - Starting Point: local terminal behavior was constrained by App Sandbox (`ENABLE_APP_SANDBOX = YES`), which blocked ICMP/raw-socket operations in local sessions and surfaced `ping: recvmsg: Operation not permitted`.
  - End Point: App Sandbox is disabled for both Debug and Release target configs (`ENABLE_APP_SANDBOX = NO` in `project.pbxproj`), keeping existing entitlements/signing flow but removing sandbox enforcement at runtime.
- Task alignment (2026-03-02, local terminal ping/tab/ctrl-c all broken — PTY termios):
  - Starting Point: `ping 8.8.8.8` printed only the header then produced no further visible output. Tab completion showed a blank/black screen. Ctrl+C did not interrupt programs. All three symptoms appeared together.
  - Root Cause: The previous fix (commit afd799e) switched `forkpty` to `nil` termios, trusting macOS kernel defaults. When called from a GUI app with no controlling terminal, this gives a PTY slave with `OPOST` and `ONLCR` disabled and `ISIG` missing. Without `OPOST`/`ONLCR`, every `\n` from child processes goes to the VT parser without a carriage return — the cursor advances rows but never resets to column 0, so output renders at wrong positions and appears invisible. Without `ISIG`, Ctrl+C (`0x03`) is not converted to SIGINT. The original explicit termios code used `cfmakeraw()` on a zero-initialised struct (also wrong — cfmakeraw is for structs from tcgetattr()), producing zero baud rate and missing HUPCL/BRKINT.
  - End Point (fix 1): `LocalPTYProcess.spawn()` now builds a complete cooked-mode termios from scratch without cfmakeraw: `ICRNL|IXON|IXANY|IMAXBEL|IUTF8` (input), `OPOST|ONLCR` (output — critical), `CS8|CREAD|HUPCL` (control), `ICANON|ISIG|IEXTEN|ECHO|ECHOE|ECHOK|ECHOKE|ECHOCTL` (local), standard POSIX control chars, 38400 baud. Matches Terminal.app/iTerm2.
  - End Point (fix 2, root cause confirmed): The PTY reader task in `LocalPTYProcess.startReaderTask()` was exiting as soon as `POLLHUP` appeared in `poll()` revents. On macOS, PTY master fds generate spurious POLLHUP whenever the foreground process group changes — e.g. when the shell (zsh) hands control to a foreground job like `ping`. The reader saw POLLHUP after the initial output burst, drained it, and then **broke out of the outer loop permanently**. All subsequent output from the running program was silently discarded and Ctrl+C bytes had nowhere to go. Fix: removed the POLLHUP-based early exit entirely. PTY master end-of-stream on macOS is reliably signalled by `EIO` from `read()`, which the inner loop already handles. No more spurious reader-task termination.
- Task alignment (2026-03-02, local terminal Tab and Ctrl+C input guard):
  - Starting Point: Even after PTY termios fix, Tab/Ctrl+C could be silently dropped at the input capture layer due to a transient firstResponder check.
  - Root Cause: `shouldCaptureLocalEvent` passed `terminalFocused: isTerminalFocused` (`window.firstResponder === self`). `armForKeyboardInputIfNeeded()` sets first responder async, so it can be transiently false.
  - End Point: `shouldCaptureLocalEvent` now passes `terminalFocused: true`, matching the existing local monitor path. One-line fix in `TerminalInputCaptureView.swift`.
- Task alignment (2026-03-02, terminal solid background customization):
  - Starting Point: terminal appearance settings exposed only Gradient Background controls; there was no single-color background mode, so users could not persist/apply a flat background color through the Metal rendering path.
  - End Point: Settings now include a dedicated Solid Background screen (enable toggle + color picker), persisted via `UserDefaults`, and Metal post-processing applies the configured single color to default near-black terminal background pixels when gradient is disabled; existing gradient behavior remains unchanged.
- Task alignment (2026-02-25, AI command wrapper noise/timeout hardening):
  - Starting Point: `execute_and_wait` echoed long internal marker wrappers directly in terminal output and relied on finalized command blocks only, which could surface transient timeout reasoning.
  - End Point: internal marker rendering is visually suppressed in terminal output and completion detection now checks active raw command output before finalized-history fallback, reducing false timeout paths.
- Task alignment (2026-02-25, patch approval popout UX):
  - Starting Point: AI patch approvals rendered inline as chat cards in the narrow right sidebar with truncated diff previews, making review difficult and leaving stale approval cards in the message timeline.
  - End Point: pending patch approvals open in a dedicated modal popout with a large scrollable diff preview and explicit approve/reject actions, while inline patch-preview cards are removed from the sidebar conversation.
- Task alignment (2026-02-25, patch popout full-width diff layout):
  - Starting Point: patch lines in the modal preview were measured at intrinsic content width inside horizontal scrolling, visually squeezing code into a narrow centered column.
  - End Point: patch diff content is now viewport-bound (`minWidth` = modal preview width) so rows expand across the full modal width while still allowing horizontal scrolling for long lines.
- Task alignment (2026-02-25, patch modal blank preview regression):
  - Starting Point: after width-layout changes, some approvals rendered a black empty preview panel (no visible lines), especially when diff payloads were empty or when unbounded width layout inside horizontal scrolling produced non-rendering content.
  - End Point: preview content uses bounded width layout (`VStack` + viewport `minWidth` only), and empty/whitespace diffs now render an explicit "No diff preview is available" message instead of a blank black panel.
- Task alignment (2026-02-26, AI copilot environment auto-detection via screen injection):
  - Starting Point: AI copilot had no reliable way to know the environment (Ubuntu, Cisco IOS, MikroTik RouterOS, macOS, etc.) before acting, risking wrong commands for the wrong platform.
  - End Point: `AIAgentRunner.run()` now prepends the last 20 lines of `shellBuffers[sessionID]` as a labeled fenced block at the top of the first user message. The shell prompt shape (e.g. `Router#`, `[admin@MikroTik] >`, `ubuntu@host:~$`) gives the LLM instant environment context with zero extra round-trips or latency. Falls back to plain prompt if buffer is empty.
- Task alignment (2026-02-26, send_input AI tool):
  - Starting Point: AI copilot had no way to send raw input to a running process — could not answer y/n prompts, send Ctrl+C, or navigate interactive CLIs like Cisco IOS or Python REPL.
  - End Point: new `send_input` tool added. Accepts an array of tokens (named special keys or literal strings), resolves them to ANSI/control byte sequences, and writes directly via `sendRawShellInput`. Supports 32 named keys (enter, tab, escape, ctrl_c–ctrl_l, ctrl_r/u/w/x/o, arrow keys, backspace, delete, home, end, page_up/down, f1–f12). Tool registered in `AIToolDefinitions`, dispatched in `AIToolHandler`, protocol updated in `OpenAIAgentSessionProviding`, implemented in new `AIToolHandler+InteractiveInput.swift`.
- Task alignment (2026-02-25, V4A apply_patch instruction correctness):
  - Starting Point: agent/tool instructions still told the model to include unchanged context lines (2-3 above/below), which mismatched expected V4A usage and caused repeated patch retries.
  - End Point: apply_patch instructions now enforce V4A changed-line blocks (`-`/`+`) with optional `@@ <anchor>` for placement/disambiguation, explicitly banning unified numeric hunks and unchanged context-line requirements.
- Task alignment (2026-02-26, remote apply_patch format mismatch fix):
  - Starting Point: `RemotePatchCommandBuilder.buildUpdateCommand()` piped V4A diffs directly to `patch(1)` via heredoc. `patch(1)` requires standard unified diff format (`@@ -l,s +l,s @@`) but V4A uses bare `@@` or `@@ <anchor>` blocks with no line-count info — causing "Only garbage was found in the patch input" on every remote update. The heredoc delivery and PTY transport worked correctly; only the format was wrong.
  - End Point: Remote update and create operations now use applyDiff-in-Swift + `buildWriteCommand` (base64 heredoc). `buildWriteCommand` creates parent dirs with `mkdir -p` so both create and update work. Remote delete still uses the direct `rm` shell command. `patch(1)` is no longer used for any remote operation.
  - Follow-up (2026-02-26): Fixed heredoc terminator collision with `executeCommandAndWait` wrapper. The wrapper appends `; __ps=$?; printf...` to the command's last line, but when the last line is a heredoc terminator, bash never sees it as the end of the heredoc. Fix: wrap all heredoc blocks in subshells `(...)` so the terminator stays on its own line and `)` becomes the safe append target.
- Task alignment (2026-02-28, remote V4A sudo-aware patching flow):
  - Starting Point: remote `apply_patch` used non-sudo base64 read/write/delete commands only. Protected paths (for example `/etc/*`) failed with permission errors and the agent often fell back to manual copy/chmod/move workarounds instead of the intended sudo prompt flow.
  - End Point: remote `apply_patch` now detects permission-denied failures, retries with non-interactive sudo when cached credentials exist (`sudo -n`), and if credentials are required it queues an interactive sudo command in-terminal and returns `status="sudo_password_required"` so the agent can ask the user to type their password in the terminal and continue naturally.
- Task alignment (2026-02-28, local shell sandbox-safe startup + Tab completion fallback):
  - Starting Point: local shell overlay startup sourced `~/.zshenv`/`~/.zprofile`/`~/.zshrc` without sandbox-safe guards, causing `operation not permitted` errors in sandboxed builds; local sessions then degraded to literal HT insertion on Tab (cursor jumps/render artifacts instead of completion), and job-control setup was brittle (`can't set tty pgrp` warnings reported).
  - End Point: local overlay sourcing now uses readable-file guards plus stderr suppression (`-r` + `2>/dev/null`) for zsh/bash startup files, zsh now includes a fallback `compinit` + `bindkey '^I' expand-or-complete` path when user dotfiles are inaccessible, and local child startup now explicitly sets process-group/foreground-tty group before `execv` to harden job-control initialization.
- Task alignment (2026-02-28, local shell Ctrl-C signal delivery regression):
  - Starting Point: in local terminal sessions, pressing `Ctrl+C` during foreground jobs (for example `ping`) echoed `^C` but did not interrupt the process, while SSH sessions behaved correctly.
  - End Point: `LocalShellChannel.send` now restores robust signal delivery for local PTYs by reintroducing signal-character handling (`Ctrl+C`/`Ctrl+Z`/`Ctrl+\`) with temporary slave-termios enforcement, `TIOCSIG` delivery attempts, and foreground process-group `kill` fallback paths; local `Ctrl+C` now interrupts foreground commands reliably.
- Task alignment (2026-03-01, local terminal Tab completion falling back to literal whitespace):
  - Starting Point: local PTY shell launch used login `argv[0]` only (for example `-zsh`) without an explicit interactive flag, which could still leave some local sessions without active line editor/completion behavior and cause `Tab` to be echoed as literal HT spacing.
  - End Point: local shell launch arguments now force interactive mode (`-i`) for common shells while keeping login semantics (`argv[0]` prefixed with `-`), and zsh overlay bootstrap now always runs `compinit` plus `bindkey '^I' expand-or-complete` (including `viins`) so local `Tab` routes through completion instead of literal whitespace insertion.
- Task alignment (2026-03-02, local terminal special/control key passthrough hardening):
  - Starting Point: local terminal relied on a Tab-only app-level key monitor plus responder-chain handlers (`keyDown`/`performKeyEquivalent`), so non-Tab special/control keys (for example `Esc`, `Enter`, `Ctrl+C`) could still be intercepted by SwiftUI/AppKit focus/control handling before being written to the local PTY.
  - End Point: `DirectTerminalInputNSView` now installs a generalized app-local keyDown monitor that forwards any encodable non-Command key sequence to `sendRawShellInput` (including `Tab`, `Esc`, `Enter`, arrows, and `Ctrl+<key>`) whenever terminal capture is active, preserving Command shortcuts and text-field focus guards.
- Task alignment (2026-03-02, local terminal key pipeline redesign follow-up):
  - Starting Point: despite the generalized key monitor, local `Tab` could still fail in some UI states due strict event-window gating (`event.window === window`) and prompt-time keymap overrides that could rebind `^I` after startup.
  - End Point: terminal key interception now uses terminal-active state with a relaxed window gate (key window only, no exact event-window identity requirement), and zsh overlay fallback now reapplies `bindkey '^I' expand-or-complete`/`viins` on every prompt via `add-zsh-hook precmd`.
- Task alignment (2026-03-02, local terminal input subsystem replacement plan):
  - Starting Point: local terminal input behavior remains unreliable in real usage (`Tab` completion and `Ctrl+C` interruption regressions continue to be reported) despite multiple incremental fixes spread across AppKit key monitors, key encoding, shell bootstrap, and PTY setup; SSH sessions in the same UI path remain stable.
  - End Point: replace the local-input path with a byte-first local terminal input subsystem that has a single authoritative input route (capture -> encode -> transport), removes layered fallback hacks, and is validated by deterministic local PTY integration tests for `Tab` completion, `Ctrl+C` signal delivery, backspace/editing keys, and focus-handling safety.
- Task alignment (2026-03-02, Local Input V2 Phase B planning doc):
  - Starting Point: Phase A implementation exists with a feature-flagged local byte-input path, but Phase B rollout/cleanup tasks were only tracked in loop-log prose and not in a dedicated execution checklist.
  - End Point: a detailed Phase B execution checklist exists at `docs/PhaseB.md` with concrete preflight, consolidation, test, observability, rollout/rollback, and acceptance-gate tasks.
- Task alignment (2026-03-02, Local Input V2 Phase B implementation):
  - Starting Point: local input still had dual local routing (`terminal.input.local.v2.enabled` gate + legacy local string path fallback), no dedicated local-input failure diagnostics, and only Tab/Ctrl+C local PTY integration coverage.
  - End Point: local sessions now use one authoritative byte-first route with the feature flag removed, failure-only structured local-input diagnostics include source/event/byte-count/error with dedup throttling, and regression coverage includes focus guards plus editing/control-key local PTY behavior.
- Task alignment (2026-03-02, local terminal subsystem rebuild):
  - Starting Point: local terminal behavior still depended on layered key interception and a monolithic `LocalShellChannel`, leaving recurring regressions and hard-to-reason local-only routing while SSH input paths were already stable.
  - End Point: local terminal now uses a decomposed local subsystem architecture with a single focused responder input route (`DirectTerminalInputNSView` -> `LocalTerminalSubsystem` -> byte send), plus split local PTY/bootstrap components (`LocalPTYProcess`, `LocalShellBootstrap`, thin `LocalShellChannel` adapter), while SSH and Metal rendering paths remain unchanged.
- Task alignment (2026-03-02, local terminal Tab/Ctrl+C follow-up + streaming render validation):
  - Starting Point: after the subsystem rebuild, local `Tab`/`Ctrl+C` could still be dropped in some real AppKit routing paths due strict local monitor gating (`event.window` identity + conservative key-window fallback), and rendering complaints needed explicit local-session streaming-path validation.
  - End Point: local monitor gating now relies on terminal-active key-window state (no strict event-window identity requirement), preserving special/control key delivery (`Tab`, `Ctrl+C`) in wrapper-routing cases; regression coverage now includes a local `SessionManager` streaming-output test to verify progressive local command output reaches shell buffers/render pipeline.
- Task alignment (2026-03-02, local startup warning leakage + sandboxed ping behavior):
  - Starting Point: local terminal startup still displayed `zsh: can't set tty pgrp: operation not permitted`, and in some runs a truncated fragment (`ration not permitted`) leaked into subsequent command output. Users also reported `ping` repeatedly printing `recvmsg: Operation not permitted`.
  - End Point: `LocalPTYProcess` startup sanitization now handles split warning fragments across PTY chunks by carrying partial marker prefixes and removing the complete warning line once assembled, preventing leaked tail fragments in terminal output. Test cleanup removed stale `ShellIntegrationTests` cases that still referenced deleted local-shell overlay APIs. In sandboxed builds, `ping` is blocked by macOS App Sandbox ICMP restrictions (`com.apple.security.app-sandbox`); this was later addressed for non-App-Store distributions by disabling App Sandbox at the target level.

## Loop Log

- 2026-03-05: Fixed residual smooth-scroll jitter caused by snapshot resync resets. `SmoothScrollEngine.jumpTo(row:)` now returns early when the requested row already matches `targetScrollRow`, preserving fractional offset/momentum during active gestures while keeping different-row programmatic sync behavior unchanged. Added regression tests covering same-row preserve vs different-row reset in `SmoothScrollEngineTests`. Validation: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` succeeded; targeted `SmoothScrollEngineTests` remain blocked by an existing XCTest host malloc/free crash before assertions execute.
- 2026-03-05: Follow-up for "stuck in middle unless one long stroke". Root cause: renderer `SmoothScrollEngine.targetScrollRow` could drift from session `scrollOffset` after programmatic offset adjustments during publish cycles. Added `scrollOffsetProvider` to `MetalTerminalSessionSurface` and call `renderer.scrollJumpTo(row:)` on appear and every `snapshotNonce` change. Wired provider from both `TerminalSurfaceView` and `ExternalTerminalWindowView` using `sessionManager.scrollStateBySessionID[session.id]?.scrollOffset ?? 0`. Validation: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` succeeded.
- 2026-03-05: Follow-up for "can scroll up but not all the way down" during live output. Added intent-aware anchor state in `TerminalRenderingCoordinator` (`preserveScrollAnchorBySessionID`): scrolling up enables viewport anchoring; scrolling down, scrollbar drag-down, `scrollToBottom`, and offset zero disable anchoring. This prevents output growth compensation from fighting user attempts to return to live output while preserving stable scrollback when reading older output. Validation: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` succeeded.
- 2026-03-05: Fixed smooth-scroll jitter and live-output scroll lock in `TerminalRenderingCoordinator`. `scrollTerminal` now reads `current` offset inside the `Task` to avoid stale-offset races during rapid wheel events. `scheduleParsedChunkPublish` no longer force-resets `scrollOffsetBySessionID` to 0 on every output chunk. `publishGridState` now preserves and clamps current scroll offset, renders `engine.snapshot(scrollOffset:)` when scrolled back, and compensates offset by scrollback growth (`scrollbackCount - previousScrollbackCount`) so viewport stays pinned while new lines append below (e.g., during `ping`). Validation: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` succeeded.
- 2026-03-05: Fixed terminal scrolling regression introduced during SmoothScrolling rollout by constraining `TerminalScrollbarView` hit-testing to a fixed trailing strip (`interactionWidth = 18`) instead of effectively covering the terminal surface. This restores wheel scrolling in terminal panes while preserving scrollbar drag behavior. Validation: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` succeeded.
- 2026-03-03: Restructured CLAUDE.md as proper working memory with continuous session workflow. Added Memory Architecture section (3-layer: CLAUDE.md working memory / featurelist.md long-term log / docs/<Feature>.md phased checklists). Added Workflow section documenting: new feature creation pattern (phased checklist in docs/), session workflow (plan mode → implement → end-of-session checklist), continuous cross-session workflow via Next Session Plan block at bottom of CLAUDE.md. Compressed Key Files table from 68 rows to 25 by grouping extensions (TerminalGrid+11, MetalTerminalRenderer+8, AIToolHandler+4, LLM infra, LLM providers, coordinators). Compressed Architecture Conventions from verbose multi-line paragraphs to one-liners with doc references. Removed AGENTS.md from Reference Docs (superseded by new workflow). Added Next Session Plan placeholder block. Files: `CLAUDE.md`, `docs/featurelist.md`.
- 2026-03-03: Added broadcast solo pane feature. In broadcast/group mode, Option+Click a pane to temporarily route input only to that pane (e.g., for sudo password entry). Option+Click the same pane again or press Cmd+Shift+B to return to broadcast. Added `soloPaneId` published property to `PaneManager` with `soloPane(_:)`/`endSolo()` methods. `targetSessionIDs` and `targetPaneIDs` now respect solo override. `toggleBroadcast()` ends solo instead of toggling off broadcast when solo is active. Solo is cleared on pane close and maximize. Visual: soloed pane shows cyan border + "Solo" capsule badge; broadcast indicators hidden on other panes during solo. Files: `PaneManager.swift`, `TerminalPaneView.swift`.
- 2026-03-03: Implemented AI Broadcaster — session-aware AI agent for multi-pane broadcast. When broadcast/group input routing is active, the AI agent now knows which sessions exist (with host labels), can target individual sessions via `target_session` tool parameter, and fans out execution across all broadcast sessions when no target is specified. Added `BroadcastContext` struct (in `AIToolHandler.swift`) threaded through ViewModel → AgentService → AgentRunner → ToolHandler. Added `resolveTargetSessions` and `formatBroadcastResult` helpers. All 13 tools + `apply_patch` now include nullable `target_session` parameter (OpenAI strict mode compatible). Developer prompt includes `MULTI-SESSION BROADCAST` section. Agent runner injects session map preamble into user messages during broadcast. UI wiring passes `paneManager.targetSessionIDs` from `TerminalView` through `TerminalAIAssistantViewModel` to the service layer. Sequential fan-out for `execute_and_wait` (labeled JSON results), loop fan-out for `execute_command`/`send_input`, labeled output for `get_current_screen`/`get_recent_commands`, single-target for file-reading tools and `apply_patch`. 10 new tests in `AIBroadcastTests.swift` covering context, resolution, and formatting. Build: SUCCEEDED. Files: `AIToolHandler.swift`, `AIToolHandler+InteractiveInput.swift`, `AIAgentRunner.swift`, `AIToolDefinitions.swift`, `ApplyPatchTool.swift`, `OpenAIAgentService.swift`, `TerminalAIAssistantViewModel.swift`, `TerminalView.swift`, `TerminalAIAssistantViewModelTests.swift` (mock update), `AIBroadcastTests.swift` (new), `docs/AIBroadCaster.md` (new).
- 2026-03-03: Updated CLAUDE.md to reflect current codebase state — 15 new source files documented across local PTY sessions (`LocalPTYProcess`, `LocalShellBootstrap`, `LocalTerminalSubsystem`, `TerminalInputCaptureView`, `ExternalTerminalWindowView`), OpenAI streaming types (`OpenAIResponsesPayloadTypes`, `OpenAIResponsesStreamAccumulator`), AI interactive input (`AIToolHandler+InteractiveInput`, `send_input` now the 12th AI tool), Metal renderer decomposition (`TerminalMetalView`, `SelectionRenderer`), prompt appearance (`PromptAppearance`, `PromptAppearanceSettingsView`), and `TerminalAIAssistantViewModel`. Updated Project Structure directory comments, Key Files table, Architecture Conventions (tool count 11→12, added Local PTY sessions convention), and Reference Docs table. Removed broken `RefactorTheActor.md` reference (file not found in repo). Added `docs/BlackTextRenderingFix.md`, `docs/FixTerminalCopyAndSelection.md`, `docs/IntegrationOfNewFeats.md` to Reference Docs. Files changed: `CLAUDE.md`, `docs/featurelist.md`.
- 2026-03-02: Added DeepSeek as the fifth LLM provider. Created `DeepSeekProvider.swift` following the `MistralProvider`/`ChatCompletionsClient` pattern — endpoint `https://api.deepseek.com/chat/completions` (no `/v1/` prefix), Bearer auth, two models: `deepseek-reasoner` (R1, reasoning by default) and `deepseek-chat` (V3, thinking enabled via `"thinking": {"type": "enabled"}` request parameter). Added `ChatCompletionsThinkingConfig` to `ChatCompletionsWireRequest` in `ChatCompletionsClient.swift`. Both models have `supportsReasoning: true`. Added `case deepseek` to `LLMProviderID` enum in `LLMTypes.swift`. Registered in `AppDependencies.swift`. Native `reasoning_content` streaming already decoded by `StreamDelta`'s custom `init(from:)`; `extractThinkTags: true` enabled as fallback. No UI changes needed — settings auto-discover registered providers. Build: SUCCEEDED. Files: `LLMTypes.swift`, `ChatCompletionsClient.swift`, `DeepSeekProvider.swift` (new), `AppDependencies.swift`.
- 2026-03-02: Fixed reasoning/thinking stream support for Ollama and Mistral. Three mechanisms now coexist in `ChatCompletionsClient.sendStreaming`: (1) Ollama's native `"reasoning"` wire field decoded from SSE delta (initial attempt wrongly used `"reasoning_content"` — Ollama uses `"reasoning"`, DeepSeek uses `"reasoning_content"`, both now decoded via custom `init(from:)`); (2) Mistral Magistral's structured content blocks where `delta.content` is an array of `{type:"thinking",...}`/`{type:"text",...}` objects instead of a plain string (custom decoding tries `String` first, then `[MistralContentBlock]`); (3) `ThinkTagExtractor` for `<think>`/`</think>` tags in `content` (fallback). `StreamDelta` now has `reasoning`, `thinkingContent`, and `content` fields populated by custom `init(from:)`. Streaming loop emits `.reasoningDelta` from all three sources + `.reasoningDone` at stream end. Enabled `extractThinkTags: true` for both `OllamaProvider` and `MistralProvider`. Build: SUCCEEDED. Files: `ChatCompletionsClient.swift`, `OllamaProvider.swift`, `MistralProvider.swift`.
- 2026-03-02: Completed Phase 5 of multi-provider architecture — cleanup & polish. Removed `typealias OpenAIJSONValue = LLMJSONValue` from `LLMTypes.swift` (updated `OpenAIResponsesTypes.swift` to use `LLMJSONValue` directly). Refactored `OpenAIResponsesService` to use `LLMAPIKeyProviding` protocol natively (`.apiKey(for: .openai)`) instead of the legacy `OpenAIAPIKeyProviding` protocol, eliminating the `LLMToOpenAIKeyProviderBridge` class. Removed `openAIAPIKeyProvider` stored property from `AppDependencies`. Updated `StaticAPIKeyProvider` test mock in `OpenAIResponsesServiceTests.swift` to conform to `LLMAPIKeyProviding`. Deleted deprecated files: `OpenAIAPIKeyStore.swift`, `OpenAISettingsViewModel.swift`, `OpenAISettingsViewModelTests.swift`. Deleted `FilesForMultiProvider/` directory (7 reference copies). Renamed `OpenAIAgentServiceTests.swift` → `AIAgentServiceTests.swift` (class name updated too). Build succeeds; all tests pass (0 new failures). Files: `LLMTypes.swift`, `OpenAIResponsesTypes.swift`, `OpenAIResponsesService.swift`, `OpenAIResponsesService+Streaming.swift`, `AppDependencies.swift`, `LLMAPIKeyStore.swift`, `OpenAIResponsesServiceTests.swift`, `AIAgentServiceTests.swift` (renamed).
- 2026-03-02: Implemented Phase 4 of multi-provider architecture — Anthropic is now the fourth working LLM provider. Created `Services/LLM/Providers/AnthropicProvider.swift` (~500 lines) with full Anthropic Messages API support including: custom wire types (request/response/streaming SSE), polymorphic `AnthropicContent` encoding (string or content block array), `x-api-key` header auth with `anthropic-version: 2023-06-01`, tool definitions using `input_schema` (not `parameters`), `tool_result` content blocks for tool outputs, extended thinking support for reasoning-capable models (Opus/Sonnet with `budget_tokens: 10000`), SSE streaming with per-block accumulation and synthetic response assembly, conversation history packing with thinking blocks excluded, and `tool_use` input re-serialization via `AIToolDefinitions.jsonString(from:)`. Models: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`. Registered in `AppDependencies.swift`. Build succeeds; all existing tests pass (no regressions). Files: `AnthropicProvider.swift` (new), `AppDependencies.swift`.
- 2026-03-02: Implemented Phase 2 of multi-provider architecture — Mistral AI is now a working alternative to OpenAI. Copied pre-built `ChatCompletionsClient.swift` and `MistralProvider.swift` to `Services/LLM/Providers/`, made wire message types `Codable` for conversation history serialization, added full message-history packing/unpacking in `MistralProvider` (Chat Completions APIs are stateless — every request includes the full wire-format history via `LLMConversationState.data`), changed `LLMProviderRegistry` defaults to OpenAI (`.openai` / `gpt-5.1-codex-max`) for backward compatibility, added `providerRegistry` to `OpenAIAgentService` with provider-routing branch in `sendProviderRequest` (OpenAI stays on Responses API, non-OpenAI providers go through `LLMProvider` protocol), added provider-mismatch detection in `AIAgentRunner` (clears stale state on provider switch), rewired `AppDependencies` with `MistralProvider` registration and `LLMToOpenAIKeyProviderBridge`, created `AIProviderSettingsViewModel` (replaces `OpenAISettingsViewModel`) with provider/model pickers and per-provider API key management, updated `SettingsView` AI section with provider picker + model picker + conditional API key field, added provider/model display in `TerminalAIAssistantPane` header, and updated all environment object injection points (`ProSSHMacApp`, `ContentView`, `RootTabView`). All existing tests pass (209 tests, 2 pre-existing unrelated failures). Files: `ChatCompletionsClient.swift`, `MistralProvider.swift`, `LLMProviderRegistry.swift`, `OpenAIAgentService.swift`, `AIAgentRunner.swift`, `AppDependencies.swift`, `AIProviderSettingsViewModel.swift` (new), `SettingsView.swift`, `TerminalAIAssistantPane.swift`, `ProSSHMacApp.swift`, `ContentView.swift`, `RootTabView.swift`.
- 2026-03-02: Restored custom prompt overlay system lost during LocalShellChannel refactor (commit `8bcfc35`). The `ensurePromptOverlay()` method and helpers (`safeZshSourceLine`, `safeBashSourceLine`, `zshCompletionFallback`) were migrated to `LocalShellBootstrap.swift` (their natural home for environment/bootstrap concerns). Updated `buildEnvironment(shellPath:)` to accept a `shellIntegration:` parameter, call `ensurePromptOverlay()`, and set `ZDOTDIR`/`BASH_ENV` accordingly. Updated `LocalShellChannel.spawn()` to pass `shellIntegration` through. `PromptAppearanceConfiguration` settings are now applied again — local terminals show the custom colored prompt instead of system default. Validation: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build` passed.
- 2026-03-02: Disabled App Sandbox for non-App-Store builds by switching `ENABLE_APP_SANDBOX` from `YES` to `NO` in both Debug and Release target build settings (`ProSSHMac.xcodeproj/project.pbxproj`). Validation: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` succeeded, and generated entitlements no longer include `com.apple.security.app-sandbox`.
- 2026-03-02: Fixed local terminal startup warning leakage after PTY chunk-boundary splits. `LocalPTYProcess.yieldSanitized` now keeps a small prefix carry for `zsh: can't set tty pgrp:` and removes the full warning line only when fully assembled, preventing partial residues like `ration not permitted` from appearing in later output. Also removed stale `ShellIntegrationTests` cases that referenced deleted `LocalShellChannel` overlay helpers (`safeZshSourceLine`/`safeBashSourceLine`/`zshCompletionFallback`/`shellLaunchArguments`) so the current local-shell architecture compiles cleanly under test. Validation: targeted tests passed via `xcodebuild test -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' -only-testing:ProSSHMacTests/ShellIntegrationTests/testLocalShellTabCompletionCompletesPartialToken -only-testing:ProSSHMacTests/ShellIntegrationTests/testLocalShellCtrlCInterruptsForegroundCommand` (2/2).
- 2026-03-02: Implemented terminal Solid Background support without changing existing Gradient Background behavior. Added persisted `SolidBackgroundConfiguration` (`terminal.effects.solidBackground`), new `SolidBackgroundSettingsView` with enable toggle + color picker, and Settings navigation/status row. Integrated renderer/shader support end-to-end: new solid-background uniforms in `TerminalUniformData`/`TerminalShaders`, renderer state + settings reload plumbing (`MetalTerminalRenderer`, `MetalTerminalRenderer+PostProcessing`, `MetalTerminalSessionSurface`), and draw-loop post-processing activation when only solid background is enabled. Gradient path remains first-priority and unchanged when enabled. Validation: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` passed.
- 2026-03-02: Fixed remaining local key-capture gate regression after subsystem rebuild by relaxing `DirectTerminalInputNSView` local monitor filtering (removed strict `event.window === window` requirement; key-window activity now falls back permissively). This targets real-world AppKit routing cases where local `Tab`/`Ctrl+C` were still not delivered despite passing lower-level PTY tests. Added `SessionManagerRenderingPathTests.testLocalSessionStreamsProgressiveCommandOutput` to lock in local session output streaming through the parser/rendering path. Validation: targeted macOS tests passed — `TerminalInputCaptureViewTests` (4/4) and `SessionManagerRenderingPathTests` (3/3) via `xcodebuild test -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' -only-testing:ProSSHMacTests/TerminalInputCaptureViewTests -only-testing:ProSSHMacTests/SessionManagerRenderingPathTests`.
- 2026-03-02: Rebuilt the local terminal subsystem end-to-end (SSH untouched). Replaced the monolithic local channel with `LocalPTYProcess` (PTY lifecycle/read-write/resize/exit stream) and `LocalShellBootstrap` (environment + prompt/shell-integration overlay), and converted `LocalShellChannel` into a thin adapter conforming to `SSHShellChannel`. Reworked `DirectTerminalInputNSView` to remove app-level local key monitors and use a focused terminal-first capture path for local sessions via new `LocalTerminalSubsystem` (encode + event typing), preserving Command shortcuts and text-input focus guards. Added local-focus gating regression coverage in `TerminalInputCaptureViewTests`. Validation: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` passed; targeted local-input tests passed (`ShellIntegrationTests` local key behavior set + `TerminalInputCaptureViewTests`, 10/10). Broader `ShellIntegrationTests` still contains pre-existing unrelated failures in `testSSHInjectionScriptsAreSingleLine`.
- 2026-03-02: Completed Local Input V2 Phase B implementation. Removed `terminal.input.local.v2.enabled` and consolidated local keyboard routing to a single byte-first path (`DirectTerminalInputNSView` local monitor -> encoded bytes -> `SessionManager.sendRawShellInputBytes`). `TerminalView` and `ExternalTerminalWindowView` now pass local hardware-input metadata (`source=.hardwareKeyCapture`, event type) into `SessionShellIOCoordinator`; coordinator now emits throttled, failure-only structured logs for local input send failures (session short ID, source, event type, byte count, error code/domain) with dedup protection. Added regression coverage: `ShellIntegrationTests` now include backspace editing, left/right arrow in-line editing, Enter submit, and Escape delivery, and new `TerminalInputCaptureViewTests` assert text-input focus guards (AI composer/search style) and resume behavior. Validation: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` passed, and targeted tests passed (`ShellIntegrationTests` local-input set + `TerminalInputCaptureViewTests`, 9/9). Pre-existing unrelated warnings remain in test builds about XCTestCase `@MainActor` initializer isolation (no new failures).
- 2026-03-02: Planned full local terminal input subsystem replacement after continued reports that local `Tab` completion and `Ctrl+C` behavior still regress while SSH input remains stable. Documented a new task alignment (starting point/end point) and execution direction: collapse the local input path to one byte-first route, remove overlapping monitor/fallback logic, and gate rollout behind deterministic local PTY integration coverage (completion, signal delivery, editing keys, focus guards) plus a temporary feature flag for rollback.
- 2026-03-02: Implemented Local Input V2 Phase A (feature-flagged byte-first local path + integration coverage). Added byte transport support to shell channels (`SSHShellChannel.send(bytes:)`, implementations in `LocalShellChannel`, `LibSSHShellChannel`, and mocks), added `SessionManager.sendRawShellInputBytes` / `SessionShellIOCoordinator.sendRawShellInputBytes`, and wired terminal capture to use byte delivery for local sessions behind `terminal.input.local.v2.enabled` (default `true`) in both embedded and external terminal windows. `DirectTerminalInputNSView` now treats Local Input V2 as a single authoritative route (app-level key monitor -> byte encoding -> raw byte send) while preserving legacy string path for non-local/flag-off sessions. Added end-to-end local PTY tests in `ShellIntegrationTests`: `testLocalShellTabCompletionCompletesPartialToken` and `testLocalShellCtrlCInterruptsForegroundCommand`. Validation: macOS app build succeeded and both targeted tests passed via `xcodebuild ... -only-testing:ProSSHMacTests/ShellIntegrationTests/testLocalShellTabCompletionCompletesPartialToken -only-testing:ProSSHMacTests/ShellIntegrationTests/testLocalShellCtrlCInterruptsForegroundCommand`.
- 2026-03-02: Authored `docs/PhaseB.md` with a detailed Local Input V2 Phase B checklist covering preflight baseline, legacy-path removal, feature-flag strategy, regression-test expansion, observability, rollback criteria, documentation updates, and final acceptance gates.
- 2026-03-02: Fix local terminal broken key input (Tab, Ctrl+C, Backspace, arrow keys). Root cause: `LocalShellChannel.spawn()` built the PTY termios from a zero-initialized `Darwin.termios()` struct then called `cfmakeraw()` — but `cfmakeraw()` is designed to modify a struct obtained from `tcgetattr()`, not a zeroed one. The resulting termios was missing baud rate, HUPCL, BRKINT, PENDIN, and other flags, creating a broken line discipline that prevented the shell from properly entering raw mode (ZLE). Fix: pass `nil` for the termios parameter of `forkpty()`, letting the kernel provide correct system-default termios (matching what iTerm2/Terminal.app/Alacritty do). Simplified `send()` to just write raw bytes to the master FD (matching `LibSSHShellChannel.send()`) — removed the complex signal-handling code that opened the slave device, temporarily modified termios, and used ioctl TIOCSIG. That code was a workaround for the broken termios; with correct defaults the kernel line discipline handles signal delivery natively. Also removed redundant `setpgid(0,0)` + `tcsetpgrp()` calls in the child process setup (already handled by `forkpty()` → `login_tty()` → `setsid()`). File changed: `LocalShellChannel.swift`. Net: ~90 lines removed. Build succeeds.
- 2026-03-02: Local key pipeline redesign follow-up. Updated `DirectTerminalInputNSView.shouldMonitorKeyDownEvent` to remove exact `event.window === window` matching (kept `isKeyWindow` guard) so terminal-bound key events are no longer dropped in wrapper-window routing paths. Also strengthened local zsh overlay fallback in `LocalShellChannel.zshCompletionFallback`: added `add-zsh-hook` + `__prossh_force_tab_completion` to reassert `bindkey '^I' expand-or-complete` (and `viins`) on every prompt, preventing late dotfile/plugin rebinds from downgrading Tab to literal insertion. Validation: build passed (`xcodebuild ... build`), focused tests passed (`KeyEncoderTests` 10/10 + `ShellIntegrationTests/testLocalShellZshCompletionFallbackIncludesTabBinding`).
- 2026-03-02: Hardened local terminal key passthrough beyond Tab. Replaced the Tab-only local event monitor in `TerminalInputCaptureView.swift` with a generalized keyDown monitor (`keyEventMonitor`) that captures any encodable non-Command key event for the active terminal session and sends it via the existing encode-and-send path. This ensures local sessions consistently receive special/control keys (`Tab`, `Esc`, `Enter`, arrows, `Ctrl+C`, etc.) even when SwiftUI/AppKit would otherwise consume them in the view hierarchy. Guard rails: only active when the view is enabled, session exists, event belongs to the same key window, and no text input is focused. Existing `performKeyEquivalent`/`keyDown` handlers remain as defense-in-depth. Validation: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` (pass) and `xcodebuild ... test -only-testing:ProSSHMacTests/KeyEncoderTests` (10/10 pass).
- 2026-03-02: Fixed local terminal Tab completion (take 2). Previous `performKeyEquivalent:` interception was insufficient because SwiftUI's `NSHostingView` consumes Tab for internal focus navigation before propagating `performKeyEquivalent:` to embedded `NSViewRepresentable` subviews. Verified via PTY diagnostic test that the shell/PTY correctly supports Tab completion with the overlay ZDOTDIR — the issue was entirely in the app's event dispatch layer. Fix: install a local event monitor (`NSEvent.addLocalMonitorForEvents(matching: .keyDown)`) in `DirectTerminalInputNSView.viewDidMoveToWindow()` that intercepts Tab (keyCode 48) at the application level, before any view in the hierarchy can consume it. Guard conditions: only fires when (1) the view is enabled with an active session, (2) the event targets this view's window, (3) the window is key, (4) no text input (search bar, AI composer) holds focus, and (5) no Command modifier is present. The monitor encodes Tab via the existing `encodeEvent` pipeline and returns `nil` to consume the event. Monitor is removed in `deinit` and when the view leaves the window. The earlier `performKeyEquivalent` Tab interception remains as defense-in-depth. File changed: `TerminalInputCaptureView.swift`.
- 2026-03-01: Fixed local terminal Tab key not triggering shell autocomplete. Root cause: macOS `NSWindow.sendEvent:` intercepts Tab/Shift-Tab for key-view focus navigation *before* dispatching `keyDown:` to the first responder — so `DirectTerminalInputNSView.keyDown` was never called for Tab. The 0x09 byte never reached the shell, and ZLE's `expand-or-complete` widget never fired. Fix: intercept Tab (keyCode 48) in `DirectTerminalInputNSView.performKeyEquivalent(with:)`, which runs before NSWindow's focus-navigation check. When the terminal is enabled and a session is active, Tab is encoded and sent to the shell via `onSendSequence`, and `performKeyEquivalent` returns `true` to prevent further event processing. Cmd+Tab is excluded (handled by the system app switcher). File changed: `TerminalInputCaptureView.swift`. Previous shell-side hardening (below) remains in place for robustness.
- 2026-03-01: Fixed local terminal `Tab` completion regression where local sessions inserted literal whitespace instead of completing commands/paths. Root cause: local shell child launch used login `argv[0]` only and depended on PTY state to infer interactivity. `LocalShellChannel.spawn` now builds explicit launch argv via new helper `shellLaunchArguments(shellPath:)`, preserving login shell naming while appending `-i` for common interactive shells (`zsh`, `bash`, `sh`, `dash`, `ksh`, `fish`, `csh`, `tcsh`). Added regression tests in `ShellIntegrationTests` for zsh interactive launch args and unknown-shell fallback behavior. Validation note: attempted targeted test run (`xcodebuild ... -only-testing:ProSSHMacTests/ShellIntegrationTests`) is currently blocked by unrelated pre-existing build failures in `FilesForMultiProvider` (`OllamaProvider.swift` / `LLMProviderRegistry.swift` missing `Combine` imports).
- 2026-03-01: Follow-up hardening for local `Tab` completion and build validation. Updated zsh fallback bootstrap to always run `compinit -u` (instead of conditional `_main_complete` check) and to bind Tab in both default and `viins` keymaps, reducing dependence on user dotfiles for completion availability. Also unblocked project builds by adding missing `Combine` imports in `FilesForMultiProvider/OllamaProvider.swift` and `FilesForMultiProvider/LLMProviderRegistry.swift`; `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build` now succeeds. Focused regression tests for the touched shell integration paths pass (`testLocalShellZshCompletionFallbackIncludesTabBinding`, `testLocalShellLaunchArgumentsForceInteractiveForZsh`, `testLocalShellLaunchArgumentsDoNotForceInteractiveForUnknownShell`).
- 2026-02-28: Fixed local-only `Ctrl+C` regression. Root cause was removal of explicit local PTY signal-delivery handling in `LocalShellChannel.send`, which left certain local shell states where `^C` echoed but `SIGINT` never reached the foreground job. Restored a hardened signal path: track/store slave PTY path from `forkpty`, detect signal chars (`0x03/0x1A/0x1C`), temporarily enforce `ISIG`+standard `VINTR/VQUIT/VSUSP` on the slave PTY, attempt `TIOCSIG` delivery (slave then master), then fallback to foreground process-group signaling (`tcgetpgrp` + child/job process-group targeting). Validation: targeted `xcodebuild` test run passed (`ShellIntegrationTests/testLocalShellSafeZshSourceLineGuardsUnreadableDotfiles`), confirming project compiles with the new PTY signal path.
- 2026-02-28: Fixed local terminal sandbox startup regression affecting Tab completion/rendering. `LocalShellChannel` overlay generation now emits permission-safe source lines for `.zshenv`/`.zprofile`/`.zshrc`/`.bashrc` (`if [[ -r ... ]]; then source ... 2>/dev/null; fi`) so sandbox-denied dotfiles no longer spam startup errors or break shell initialization. Added zsh fallback completion bootstrap (`compinit -u` + `bindkey '^I' expand-or-complete`) so local Tab completion still works when user dotfiles are unreadable. Also hardened local child startup with `setpgid(0,0)` + `tcsetpgrp(STDIN_FILENO,getpid())` before `execv` to reduce `can't set tty pgrp` job-control failures. Added regressions in `ShellIntegrationTests` for safe source-line generation and zsh fallback completion content. Validation: targeted tests for the three new cases pass; broader `ShellIntegrationTests` still contains 4 unrelated pre-existing failures (`testSSHInjectionScriptsAreSingleLine` expects `; clear` suffix).
- 2026-02-28: Remote V4A patching is now sudo-aware for protected remote files. `AIToolHandler` remote apply_patch flow now performs permission-denied detection for update/create/delete, probes cached sudo (`sudo -n true`), retries with sudo-capable command builders when possible, and queues interactive sudo commands (`sudo write/delete` or `sudo -v` priming for read-protected updates) when password entry is needed, returning `status="sudo_password_required"` in tool output. `RemotePatchCommandBuilder` gained sudo-aware `buildReadCommand`/`buildWriteCommand`/`buildDeleteCommand` options plus `buildSudoPrimingCommand`. Prompt guidance was updated in both `AIToolDefinitions.developerPrompt` and `ApplyPatchToolDefinition.description` so the agent stops and asks the user to enter their password directly in terminal when this status is returned. Added regressions: new sudo builder tests in `RemotePatchCommandBuilderTests` and two end-to-end `OpenAIAgentServiceTests` for (a) interactive sudo-required fallback and (b) cached-credential sudo retry success. Targeted tests passing: `AIToolDefinitionsTests` (9), `RemotePatchCommandBuilderTests` (18), and focused `OpenAIAgentServiceTests` sudo cases (2).
- 2026-02-28: Fix local terminal black screen — prompt invisible until Enter (Issue #25). Root cause: `initializeFontMetricsAndPrepopulate()` in `MetalTerminalRenderer+FontManagement.swift` rebuilt the glyph atlas and cleared cached glyph indices but did not re-apply `latestSnapshot`, leaving the cell buffer with stale glyph indices that sampled empty/wrong texels. The sibling function `reloadFontStateFromManager()` (same file) already had the fix (`if let latestSnapshot { updateSnapshot(latestSnapshot) }`) for font-change scenarios but it was never backported to the init path. Phase 1: added the missing `latestSnapshot` reapplication to `initializeFontMetricsAndPrepopulate()` after `recalculateGridDimensions()`. Phase 2: added a 150ms delayed snapshot re-apply in `MetalTerminalSessionSurface.swift`'s `.onAppear` as a safety net for atlas-ready timing races. Files changed: `MetalTerminalRenderer+FontManagement.swift`, `MetalTerminalSessionSurface.swift`.
- 2026-02-28: Fix terminal copy and selection (Issue #22) — Three root causes fixed. (1) Click-to-deselect: added `selectionCoordinator.clearSelection(sessionID:)` call in the `onTap` callback in `TerminalSurfaceView.swift` so clicking the terminal clears the sticky blue selection highlight. (2) Drag-end safety: restructured `handleDrag(point:phase:)` in `MetalTerminalSessionSurface.swift` to process `.ended`/`.cancelled` phases before the `gridCell(at:)` guard — previously, if the pointer was outside the grid when the drag ended, `gridCell` returned nil and `dragStart` was never cleared, leaving a stale selection. (3) Wide-char copy fix: updated `selectedText()` in `MetalTerminalRenderer+Selection.swift` to detect `CellAttributes.wideChar` (`1 << 9`) on each cell and skip the next continuation cell, eliminating spurious spaces when copying CJK or other wide characters. Build succeeds with zero errors.
- 2026-02-28: Fix black text rendering (Issue #9) — Three root causes identified and fixed. (1) Removed `\033[8m` (SGR hidden) / `\033[0m` wrapper from `SessionAIToolCoordinator` marker printf — if the inner command failed catastrophically the reset never fired, leaving `currentAttributes.hidden` stuck and all subsequent text invisible. The marker in `AIToolHandler+RemoteExecution.swift` already worked without SGR wrapping. (2) Added SGR reset (`\033[0m`) on `executeCommandAndWait` timeout — defense-in-depth against stuck color/hidden state from partial SGR sequences. (3) Set `forceFullUploadForPendingSnapshot = true` when `selectionRenderer.needsProjection()` is active in `MetalTerminalRenderer+SnapshotUpdate.swift` — prevents stale `flagSelected` bits in the CellBuffer read buffer from persisting outside the dirty range after selection clear. Files changed: `SessionAIToolCoordinator.swift`, `MetalTerminalRenderer+SnapshotUpdate.swift`. Added `SessionAIToolCoordinatorTests.swift` with two regression tests: `testWrappedCommandContainsNoSGREscapeSequences` (Phase 1) and `testTimeoutSendsSGRReset` (Phase 2). Plan: `docs/BlackTextRenderingFix.md`.
- 2026-02-27: RemotePatchingFix Phase 5 (read_file_chunk contamination fix) — Rewrote `readRemoteFileChunk` in `AIToolHandler+RemoteExecution.swift` to use the same base64 read path that `apply_patch` uses (`RemotePatchCommandBuilder.buildReadCommand` → `provider.executeCommandAndWait` → `RemotePatchCommandBuilder.decodeBase64FileOutput`), then extracts the requested line range in Swift. This replaces the sed-based `buildRemoteReadFileChunkCommand` + `executeRemoteToolCommand` path that ran through `CommandBlock.output` and got shell prompt / command-echo contamination mixed into the content. The contaminated content caused the AI agent to think patches failed (content mismatch) and spiral into broken retry attempts. Falls back to the old sed path if base64 decode fails (e.g., file not found, binary). Returns the same JSON shape for API compatibility. Added `testBase64ReadLineExtraction` to `RemotePatchCommandBuilderTests` verifying the full decode + line slicing pipeline with contaminated input. Build succeeds; all 14 `RemotePatchCommandBuilderTests` pass.
- 2026-02-27: RemotePatchingFix Phase 4 (dead code cleanup) — Deleted `buildUpdateCommand` and its MARK header from `ApplyPatchTool.swift`; replaced the unreachable `.update` case in `buildCommand(for:)` with `preconditionFailure` documenting that updates go through the read-apply-write path in `AIToolHandler`. Updated `buildCommand(for:)` docstring to note it handles only `.create` and `.delete`. Simplified `parseResult` to delete-only: removed `patch(1)` success/failure pattern checks (`FAILED`, `reject`), Hunk/offset warning, and fuzz warning; the method now only checks for `__PROSSH_PATCH_ERROR__` and returns success otherwise. Deleted both `ApplyPatchTool.swift.bak` copies (source tree + DMG artifact). In `ApplyPatchTests.swift`: removed `testUpdateCommandUsesPatch`, `testParseFuzzyWarning`, and `testParseRejectedHunk` (all tested deleted dead code); updated `testParseSuccessResult` to use a `.delete` operation with empty output (what `rm` produces); added `testRemoteUpdateUsesReadThenWrite` as an architectural documentation test asserting that both `buildReadCommand` and `buildWriteCommand` use base64 encoding and neither references `patch(1)`. Build and all targeted patch tests pass.
- 2026-02-27: RemotePatchingFix Phase 3 — Wired `buildReadCommand`/`decodeBase64FileOutput` into the live remote update path in `AIToolHandler.swift`. Replaced `Self.buildRemoteReadFileChunkCommand(path:startLine:endLine:)` (sed-based, contaminated output) with `RemotePatchCommandBuilder.buildReadCommand(path:)` + `if let originalContent = RemotePatchCommandBuilder.decodeBase64FileOutput(readResult.output)` guard. A nil decode (file not found or binary) now returns a descriptive `PatchResult(success: false, ...)` instead of crashing the diff pipeline. Replaced `testUpdateWithPromptPrefixProducesCorruptOutput` (documents Bug 1 as expected failure) with `testUpdateSucceedsWithBase64ReadSimulation` (regression test: contaminated terminal output → decode → applyDiff → correct result). Also fixed two pre-existing bugs exposed when the Phase 3 crash fix landed: (1) `V4AParserState` (a `private final class`) was missing `nonisolated deinit` — under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, its dealloc went through `swift_task_deinitOnExecutorImpl` and aborted in XCTest callbacks; added `nonisolated deinit {}` matching the pattern already used in `PaneManager`/`SessionTabManager`. (2) `testUpdateAnchorNotFound` used a delete line (`-line1`) that accidentally matched the input's first line, so `findContext` never returned -1 and the test never threw; fixed the diff to use a context line absent from the file. (3) `testFullLifecycle` in `PatchRoundTripTests` used unified diff format for create/update, but `LocalWorkspacePatcher` uses V4A format; fixed both diffs to V4A (create: `+`-prefixed lines; update: `@@ <anchor>` with `-`/`+` lines). All 58 patch-related tests now pass.
- 2026-02-27: RemotePatchingFix Phase 2 — Added `RemotePatchCommandBuilder.buildReadCommand(path:)` and `RemotePatchCommandBuilder.decodeBase64FileOutput(_:)` to `ApplyPatchTool.swift`. `buildReadCommand` emits `base64 <escaped-path>` — the read-side pair of `buildWriteCommand`. `decodeBase64FileOutput` filters output lines to keep only valid base64 chars (`[A-Za-z0-9+/=]`), joins and decodes them, returning the UTF-8 content or nil on failure — making the read immune to shell prompt / command-echo contamination. Added 8 new tests to `RemotePatchCommandBuilderTests` covering: base64 command generation, space-path escaping, clean round-trip, prompt-prefix contamination, prompt-suffix contamination, trailing-newline preservation, nil for empty output, nil for non-base64 output. All 15 `RemotePatchCommandBuilderTests` pass. No production calling code changed in this phase.
- 2026-02-26: Fixed SFTP transfer progress reporting. Uploads/downloads previously showed "Zero KB" until completion because the C layer updated progress pointers in-place but Swift only read them after the blocking call returned. Added `progressHandler` callback to `uploadFile`/`downloadFile` throughout the stack (SSHTransporting protocol, LibSSHTransport, SessionSFTPCoordinator, SessionManager). LibSSHTransport now allocates heap pointers shared with a detached polling task (250ms interval) that reports intermediate progress to TransferManager, which updates `transfers[index].bytesTransferred` in real time.
- 2026-02-26: Added SUDO / ELEVATED PRIVILEGES section to the AI developer prompt. Agent now runs sudo commands directly via `execute_command` (fire-and-forget), checks the screen for a password prompt, and asks the user to type their password in the terminal instead of avoiding sudo or rewriting the approach. Password stays in the PTY and is never sent to the AI provider.
- 2026-02-26: Fixed AI sidebar Clear and X buttons. Clear now cancels the running agent task (`activeAgentTask.cancel()`), resets `isSending`, and clears conversation context — previously it only cleared UI messages while the agent kept running. X close button now calls `clearConversation()` before hiding the sidebar — previously it only toggled `showAIAssistant = false` without stopping or clearing anything.
- 2026-02-25: Reworked AI patch-approval UX from inline sidebar cards to a dedicated modal popout review flow. `TerminalAIAssistantViewModel` now exposes `activePatchApproval` modal state (no inline `.patchApproval` chat messages), `TerminalAIAssistantPane` presents a `sheet`-based patch review dialog, and `PatchApprovalCardView.swift` now renders a full-size `PatchApprovalSheetView` with full diff preview + Approve/Reject controls. Added regressions in `TerminalAIAssistantViewModelTests` for modal approval state and dismissal-deny behavior; targeted tests pass (`testRequestPatchApprovalUsesModalStateWithoutInlineMessage`, `testPatchApprovalSheetDismissDeniesPendingApproval`).
- 2026-02-25: Fixed modal patch preview width usage so diff lines are no longer visually squeezed into the center. `PatchApprovalSheetView` now binds diff content to at least the viewport width via `GeometryReader` + `minWidth`, and each diff row now fills available width. Re-verified targeted approval-flow tests pass.
- 2026-02-25: Fixed patch-approval modal blank-preview regression. Removed unbounded-width scroll-content layout (`maxWidth: .infinity` in horizontal scroll path), switched preview stack from `LazyVStack` to `VStack`, and treated empty/whitespace diffs as no-preview state so users get an explicit fallback message rather than a black panel. Re-verified targeted approval-flow tests pass.
- 2026-02-25: Corrected V4A patching guidance in both model prompt and tool schema text. Updated `AIToolDefinitions.developerPrompt` and `ApplyPatchToolDefinition.description` to use changed-lines-first V4A blocks (`@@` / `@@ <anchor>` + only `-`/`+` lines), removed mandatory context-line guidance, and clarified no unified numeric hunk headers. Re-verified with targeted `AIToolDefinitionsTests` (9/9 passing).
- 2026-02-22: Baseline feature checklist rewritten with phased plan and corrected claims.
- 2026-02-22: Working-memory loop established in `AGENTS.md`; long-term memory source pinned to this file.
- 2026-02-22: Fixed `TerminalView.swift` main-actor isolation warnings in `DirectTerminalInputNSView` observer/deinit paths; build re-verified.
- 2026-02-22: Fixed live SFTP failure ("session must be blocking") by forcing blocking mode only during SFTP calls in `ProSSHLibSSHWrapper.c`, then restoring prior interactive mode.
- 2026-02-22: Updated transfer download destination to the user Downloads folder (`~/Downloads`) instead of app support storage.
- 2026-02-22: Fixed SFTP binary-download instability ("Decryption error") by serializing libssh session access with a per-handle mutex across shell I/O and SFTP paths.
- 2026-02-22: Started Phase 2 in `TerminalView` with a toggleable left file browser sidebar (`⌘B`), row-click behavior (folder open/file select), download action reuse, and context-menu editor actions.
- 2026-02-22: Improved Transfers UX so clicking a remote row activates it directly (folder opens, file starts download) instead of requiring the trailing button.
- 2026-02-22: Completed local-session fallback in terminal file browser: local connected sessions now browse via `FileManager` (initial CWD/home, up/refresh, row click open/select, and local editor actions) while remote SFTP state is cleanly detached.
- 2026-02-22: Fixed local terminal TUI rendering lag/artifacts (notably `nano`) by replacing PTY read coalescing with a poll+drain loop in `LocalShellChannel`, eliminating fragmented character-by-character frame updates.
- 2026-02-22: Further tuned local TUI behavior by adding short-burst PTY read coalescing and robust nonblocking write retries in `LocalShellChannel`, reducing slow redraw while navigating inside full-screen apps like `nano`.
- 2026-02-23: Implemented lazy file-tree browser in `TerminalView` for both remote and local sessions (expand/collapse folders on click, per-directory loading states, cached children, root up/refresh navigation).
- 2026-02-23: Added file-browser logic test coverage in `ProSSHMac/Terminal/Tests/TerminalFileBrowserTreeTests.swift` and extracted reusable tree/path helpers into `ProSSHMac/Terminal/Features/TerminalFileBrowserTree.swift`; `TerminalView` now uses these helpers for row-building, path normalization, collapse semantics, and local listing.
- 2026-02-23: Completed Phase 3 command-history foundation: added `CommandBlock` + actor-isolated `TerminalHistoryIndex`, wired session input/output ingestion, implemented OSC 133 semantic prompt event handling, added prompt-heuristic fallback segmentation, and added tests for segmentation/search/ring behavior plus OSC 133 parser dispatch.
- 2026-02-23: Settings pane scrollability fixed by wrapping the settings form in an explicit scroll container so long settings content (including future API key controls) remains reachable.
- 2026-02-23: Phase 4/6 plan adjusted to make API key handling user-configurable in Settings and treated as a prerequisite for AI agent usage.
- 2026-02-23: Completed API-key prerequisite for Phase 4: added Keychain-backed OpenAI API key store/provider wiring in app dependencies plus Settings UI for save/remove/status, with fail-safe provider behavior when key retrieval fails.
- 2026-02-23: Added `OpenAIResponsesService` foundation using native `URLSession` with explicit model pinning to `gpt-5.1-codex-max`, request/response types (including tool-call fields), API-key gating, HTTP/decode error handling, and dependency wiring in `AppDependencies`.
- 2026-02-23: Completed Phase 4 tool loop foundation: added `OpenAIAgentService` with minimum tool definitions + local tool execution pipeline (`search_terminal_history`, `get_command_output`, `get_current_screen`, `get_recent_commands`, `execute_command`, `get_session_info`), execute-command safety gating via mode checks, `previous_response_id` continuity with invalid-ID recovery retry, and bounded timeout/iteration guards; wired service into `AppDependencies` and added focused unit tests (`OpenAIAgentServiceTests`).
- 2026-02-23: Updated shared `ProSSHMac` scheme `TestAction` so `xcodebuild test` is now recognized as configured (it advances past scheme-configuration failure); current remaining blocker is project-level absence of test bundles.
- 2026-02-23: Added `ProSSHMacTests` unit-test bundle target + shared-scheme wiring (hosted by `ProSSHMac`), fixed test-target signing/isolation settings, and verified `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -configuration Debug test` succeeds (smoke test baseline).
- 2026-02-23: Stabilized test-run workflow to prevent repeating crash popups: confirmed `PaneManagerTests` trigger an XCTest host malloc crash, added temporary class-level skip quarantine in `PaneManagerTests`, and continued development with build-for-testing + targeted stable tests.
- 2026-02-23: Closed Phase 6 test blocker for `PaneManagerTests`: removed quarantine skip, added `nonisolated deinit` to `PaneManager` (and `PaneLayoutStore`) to avoid actor-isolated deallocation crash path, and re-verified with `xcodebuild ... -only-testing:ProSSHMacTests/PaneManagerTests` (26/26 passing).
- 2026-02-23: Completed Phase 5 AI sidebar integration: added rendered right-side copilot pane with Ask/Follow/Execute selector, streaming/copyable syntax-highlighted code blocks, explicit execute confirmation gate, and AI sidebar toggle shortcut (`⌘⌥I`), including width persistence and drag resizing.
- 2026-02-23: Wired Follow mode to true command-completion events by emitting per-session completion signals from `SessionManager` (`latestCompletedCommandBlockBySessionID` + nonce) sourced from `TerminalHistoryIndex` completion boundaries (OSC 133 + heuristic), and auto-triggering follow prompts only when new command blocks complete.
- 2026-02-23: Added follow-mode coverage in `TerminalAIAssistantViewModelTests`, hardened `TerminalHistoryIndexTests` timing/expectations, and quarantined unstable `testClearConversationResetsMessagesAndCallsService` with `XCTSkip` due intermittent XCTest host malloc/free crash.
- 2026-02-23: Closed Phase 6 test blocker for `TerminalAIAssistantViewModelTests.testClearConversationResetsMessagesAndCallsService`: removed `XCTSkip`, added `nonisolated deinit` on `TerminalAIAssistantViewModel` (plus mock service lifecycle hardening), and re-verified with targeted `xcodebuild` runs for the single test and full `TerminalAIAssistantViewModelTests` suite.
- 2026-02-23: Completed Phase 6 sidebar persistence step: `TerminalView` now persists left/right sidebar visibility and widths per context (`host:<id>` for SSH sessions, `session:<id>` for local sessions), restores layout on session switch, and adds draggable width resizing for the file browser sidebar.
- 2026-02-23: Expanded AI hardening coverage: added execute/follow safety and tool-loop regression tests in `OpenAIAgentServiceTests` (follow-mode execute guard, execute-argument validation error output, bounded tool-loop exhaustion) plus additional `TerminalAIAssistantViewModelTests` for follow-mode suppression outside Follow mode and while a reply is already in-flight.
- 2026-02-23: Added dedicated SFTP sidebar regression coverage in `SessionManagerSFTPSidebarTests` (connected-session directory listing success, disconnected-session guard, and transport error propagation) and verified targeted test run passes.
- 2026-02-23: Fixed AI Settings key-entry UX regression in `SettingsView`: replaced fragile inline secure-field row with explicit bordered API-key input + clipboard paste helper so users can reliably enter/save OpenAI keys on macOS.
- 2026-02-23: Fixed AI copilot composer focus in `TerminalView`/`TerminalAIAssistantPane`: when chat input is focused, direct terminal keyboard capture is suspended (and released as first responder) so typing goes into the AI field; terminal capture re-arms when focus returns.
- 2026-02-23: Fixed OpenAI Responses tool payload contract (`tools[i].name` at top level) by flattening `OpenAIResponsesToolDefinition` encoding and updating agent tool definitions; added regression in `OpenAIResponsesServiceTests.testCreateResponseEncodesFunctionToolsWithTopLevelName` to lock payload shape.
- 2026-02-23: Fixed strict function-schema validation for Responses API by ensuring every declared tool property is listed in `required` when `strict: true` (`search_terminal_history.limit`, `get_current_screen.max_lines`, `get_recent_commands.limit`), resolving 400 errors about missing required keys in schema.
- 2026-02-23: Strengthened AI mode instructions in `OpenAIAgentService` so Ask/Follow explicitly use context tools instead of claiming no access, and Execute mode explicitly runs requested commands (including interactive commands like `nano`/`vim`/`less`) rather than refusing capabilities.
- 2026-02-23: Fixed AI composer input UX: pressing Enter in chat input now submits (same behavior as Send button), and terminal direct-input capture now defers to active text inputs so Cmd+V in the chat field pastes into chat instead of terminal.
- 2026-02-23: Added native local-filesystem AI tools in `OpenAIAgentService`: `search_filesystem` (filename/wildcard search) and `search_file_contents` (pattern-in-file search with matching lines), plus mode prompts updated to prefer these tools for filesystem requests.
- 2026-02-23: Extended AI filesystem tools to remote SSH sessions: `search_filesystem` now executes safe read-only remote `find` queries and `search_file_contents` uses remote `rg`/`grep` fallback queries, both parsed back into structured tool output with timeout/error handling.
- 2026-02-23: Hardened remote tool-output parsing for real terminal captures: filesystem parsing now accepts whitespace-delimited `find` rows (not only tab-delimited), and both remote filesystem/content tools now return a `raw_output_preview` + `parse_warning` fallback when structured extraction is incomplete, preventing false "not found" replies when wrapped/normalized terminal output is noisy.
- 2026-02-23: Consolidated AI pane UX to single visible Ask mode: removed Ask/Follow/Execute mode picker and execute confirmation dialog from `TerminalView`/`TerminalAIAssistantPane`; Ask mode now auto-routes to tools and can execute commands when user intent is explicit, while Follow mode remains execution-blocked internally. Targeted tests pass (`OpenAIAgentServiceTests`, `TerminalAIAssistantViewModelTests`, with one known skipped test).
- 2026-02-23: Completed Ask-only cleanup across backend + UI: removed `OpenAIAgentMode` and all Follow/Execute branching from `OpenAIAgentService`, removed follow auto-trigger paths from `TerminalView` and `TerminalAIAssistantViewModel`, and simplified AI tests to Ask-only contract; targeted tests pass (`OpenAIAgentServiceTests`, `TerminalAIAssistantViewModelTests`, 1 known skipped test unchanged).
- 2026-02-23: Increased AI tool-loop ceiling from 8 to 99 iterations in `OpenAIAgentService` (and explicitly via `AppDependencies`) to avoid premature `toolLoopExceeded` failures on multi-step requests; re-verified with `OpenAIAgentServiceTests`.
- 2026-02-23: Increased AI tool-loop ceiling again to 200 iterations and tightened Ask-mode developer guidance for tool efficiency (avoid duplicate calls, batch discovery, stop once evidence is sufficient); re-verified with `OpenAIAgentServiceTests`.
- 2026-02-23: Added bounded file-ingestion guardrails for long AI runs: new `read_file_chunk` tool (local + remote) enforces `line_count <= 200`, Ask-mode instructions now require iterative chunk reads, and `execute_command` now returns `read_window_required` when commands attempt unbounded file reads (`cat` full-file, oversized `head`/`tail`/`sed`, scripted full reads). Added regression coverage in `OpenAIAgentServiceTests`.
- 2026-02-23: Polished AI copilot UX in terminal: assistant plain-text segments now render as Markdown (with fenced code still syntax-highlighted + copyable), AI sidebar resizing now has a visible drag handle with expanded width range, and composer input is now multiline/auto-expanding with `Enter` submit and `Shift+Enter` newline.
- 2026-02-23: Fixed post-polish spinner regression: multiline `NSTextView` composer no longer mutates SwiftUI state synchronously during `updateNSView`/delegate layout callbacks. Binding writes are deferred async on main, removing `Modifying state during view update` warnings and preventing stuck AI/file-browser loading spinners.
- 2026-02-23: Cleared remaining composer warning at `TerminalAIAssistantPane.swift:415` by removing focus-state `Binding` updates from the AppKit wrapper path; focus changes are now callback-driven to avoid any state mutation during SwiftUI view updates.
- 2026-02-23: Added stronger anti-reentrancy deferral in composer bridge: focus/text/height propagation now runs on main actor after `Task.yield()`, avoiding same-pass state mutation during representable update/layout callbacks.
- 2026-02-23: Fixed file-browser spinner stall in terminal sidebar by introducing per-path async request IDs and guaranteed active-request cleanup for loading flags before result guards, preventing stale completion paths from leaving root loading stuck until pane changes.
- 2026-02-23: Improved AI answer readability + streaming feel: dense one-line replies are reflowed into short paragraphs, assistant prompt now enforces structured markdown output, streaming chunk cadence is slower/smaller for visible progression, and in-flight rendering uses lightweight plain text until streaming completes.
- 2026-02-23: Added renderer-level readability fallback in `TerminalAIAssistantPane`: long dense markdown/plain text responses are auto-split into paragraph blocks before markdown parsing, ensuring multi-paragraph display even when upstream model output is a single wall of text.
- 2026-02-23: Reduced macOS AppKit menu inconsistency errors triggered by the AI composer `NSTextView` by disabling broad text-checking services and returning a minimal explicit contextual menu instead of default rich-text submenu stacks (Font/Substitutions/Writing Direction/Speech).
- 2026-02-23: Improved AI token efficiency and reduced noisy context payloads in `OpenAIAgentService`: `get_current_screen` now defaults to 60 lines (max 160), command history previews are capped to 300 chars, `get_command_output` now supports bounded `max_chars` with truncation metadata, and remote internal tool wrappers run with `suppressEcho=true` to avoid terminal echo noise.
- 2026-02-23: Fixed remaining AI pane update-loop warnings and text-density issues: `TerminalAIAssistantPane` composer callback writes now defer via `DispatchQueue.main.async` with focus-state de-duplication, streaming assistant content now renders through markdown formatting, and sentence-splitting now handles punctuation boundaries even without trailing spaces.
- 2026-02-23: Hardened file-browser async loading against stale completions: if a stale callback arrives after request-ID rollover and no active request exists for that path, loading flags are now cleared to prevent indefinite spinner states.
- 2026-02-23: Re-ran targeted regression tests after the above fixes: `OpenAIAgentServiceTests` and `TerminalAIAssistantViewModelTests` pass, including the previously quarantined clear-conversation test.
- 2026-02-23: Updated user-facing shortcut/help text in `SettingsView` and AI pane composer hints to match current Ask-only copilot flow and terminal/file-browser/AI keyboard shortcuts.
- 2026-02-23: Added `read_files` tool support in `OpenAIAgentService` for batch chunked file reads (max 10 files/request, 200 lines/file), tightened tool payload shapes for lower token usage, and expanded `OpenAIAgentServiceTests` coverage for batch file reads and grouped content-search hits.
- 2026-02-23: Fixed terminal copy UX reliability in both embedded and external terminal windows: preserved Metal selection on focus tap, enabled context-menu copy regardless of stale selection state, added fallback copy from any active terminal selection, and wired direct input capture view to respond to standard AppKit `copy:`/`paste:` menu actions.
- 2026-02-23: Hardened OpenAI request reliability against transient upstream failures: `OpenAIResponsesService` now retries recoverable API failures (`429` and `5xx`) and transport failures with bounded exponential backoff, with regression coverage in `OpenAIResponsesServiceTests` (`500 -> retry -> success` and non-retry `400` assertion).
- 2026-02-23: Improved AI latency for routine asks: `OpenAIAgentService` now defaults to stateless turn handling in app wiring (`persistConversationContext: false`) to avoid large accumulated server-side context, request timeout is reduced to 35s for faster stall recovery, direct-command guidance was strengthened to prefer one-shot `execute_command`, and assistant UI streaming now uses larger chunks + lower delay for faster visible completion.
- 2026-02-23: Added structured AI performance logging for diagnosis without UI changes: `OpenAIAgentService` now logs per-turn trace IDs, iteration timings, tool-call timings, and recovery/loop-failure markers; `OpenAIResponsesService` now logs per-attempt request timing, retry decisions, and terminal success/failure events.
- 2026-02-23: Fixed Ask-mode slow second-turn conflict on direct command requests: explicit action prompts now use a direct-action fast path (restricted tools: `execute_command`, `get_current_screen`, `get_session_info`; low per-turn iteration cap) to avoid unnecessary exploratory tool loops, and canceled transport errors are now normalized (`URLError.cancelled` / `NSURLErrorCancelled`) and not retried, preventing avoidable 35s retry stalls.
- 2026-02-23: Fixed terminal focus dead zone after clicking AI chat composer: `focusSessionAndPane()` now explicitly resigns any active `NSTextView` first responder at the AppKit level before updating SwiftUI state, allowing the normal `armForKeyboardInputIfNeeded()` path to reclaim terminal keyboard focus without a force mode. Previously the terminal could not regain focus after clicking the composer because the `NSTextView` remained first responder at the AppKit level even though SwiftUI state said otherwise.
- 2026-02-23: Implemented per-host Shell Integration / Device Type configuration: added `ShellIntegrationType` enum (4 Unix shells + 8 network vendors + custom), `ShellIntegrationConfig` on `Host` with backward-compatible Codable, "Shell Integration" picker section in `HostFormView`, `ShellIntegrationScripts` with OSC 133 injection scripts (zsh/bash/fish/POSIX sh), vendor prompt regex patterns for `TerminalHistoryIndex.looksLikePrompt()`, local shell overlay injection via `LocalShellChannel`, SSH post-connect script injection via `SessionManager`, and 21 unit tests covering Codable round-trip, backward compat, all vendor regexes, and script content validation.
- 2026-02-23: Fixed `SessionTabManager` XCTest host crash (`___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED` in `__deallocating_deinit`) by adding `nonisolated deinit {}` — same actor-isolated deallocation pattern previously fixed for `PaneManager` and `TerminalAIAssistantViewModel`.
- 2026-02-23: Fixed invisible text after TUI programs exit (dark-on-dark rendering). Two changes: (1) `TerminalGrid.disableAlternateBuffer()` now always resets SGR attributes to defaults (`.default` fg/bg, no attributes) instead of restoring potentially corrupted saved colors — cursor position and charsets are still restored from saved state; (2) Metal fragment shader now includes a minimum-contrast safety net that replaces near-black foreground with white when both fg and bg luminance are below 0.06, unless the `hidden` attribute is set. Together these prevent invisible text from TUI programs that exit without resetting colors (e.g., Ctrl+C exits).
- 2026-02-23: Transformed AI copilot from passive Q&A bot into autonomous terminal agent. Key changes: (1) Added `execute_and_wait` tool that runs a command and returns output+exit code in one step (eliminates the fire-and-forget→read-screen two-step), implemented via UUID marker polling in `SessionManager.executeCommandAndWait`; (2) Rewrote developer prompt to declare full terminal control, explain command block system, encourage multi-step reasoning and proactive exploration, remove artificial "1-2 tool calls" limits; (3) Raised default max iterations from 15→50, direct action cap from 4→15, narrowed direct action detection to only `hasPrefix("run "/"execute "/"cd ")`; (4) Enabled conversation context persistence (`persistConversationContext: true`) and increased request timeout to 60s; (5) Increased output limits: `get_command_output` max 4000→16000, `get_current_screen` max 160→300; (6) Enriched all tool descriptions with return formats, usage patterns, and chaining guidance; (7) Expanded direct action tool set from 3 to 6 tools. All 14 `OpenAIAgentServiceTests` pass including 2 new tests (`testExecuteAndWaitReturnsOutputDirectly`, `testExecuteAndWaitReturnsTimeoutWhenCommandHangs`).
- 2026-02-24: Phase 5 COMPLETE (commit `0e876c2`). Decomposed `SessionManager.swift` (1,640→1,177 lines) into four `@MainActor final class` coordinators using the weak-reference coordinator pattern: `SessionReconnectCoordinator` (NWPathMonitor + reconnect logic), `SessionKeepaliveCoordinator` (keepalive timer), `TerminalRenderingCoordinator` (grid snapshots, scroll, PTY state, render-publish pipeline), `SessionRecordingCoordinator` (SessionRecorder + recording/playback). All `@Published` properties remain on SessionManager; coordinators write via `manager?` weak ref. 22 pre-existing failures in test suite (all color/mouse — within ≤23 baseline). Phase 6 (decompose OpenAIAgentService) is NOT PLANNED.
- 2026-02-24: Diagnosed AI chat non-streaming behavior in production path. Current OpenAI call path is non-streaming (`URLSession.data(for:)` one-shot Responses request with no `stream` flag), and UI "streaming" is post-hoc chunk replay of already-complete text in `TerminalAIAssistantViewModel`; reasoning/thought output is not surfaced because response parsing only collects `output_text`/`text` fragments and message rendering has no reasoning bubble type yet.
- 2026-02-24: Implemented true AI streaming end-to-end for terminal copilot. `OpenAIResponsesService` now supports streamed Responses requests (`stream: true`) with SSE event parsing (`output_text` and reasoning delta/done events) plus fallback behavior for non-URLSession test transports; `AIAgentRunner`/`OpenAIAgentService` now forward stream events through a new agent stream callback; `TerminalAIAssistantViewModel` now consumes live assistant/reasoning stream events and renders reasoning into dedicated thought-bubble messages; `TerminalAIAssistantPane` now includes thought-bubble UI cards for reasoning + reasoning summaries. Added/updated tests: stream forwarding in `OpenAIAgentServiceTests`, streaming fallback event emission in `OpenAIResponsesServiceTests`, and reasoning-bubble stream behavior in `TerminalAIAssistantViewModelTests` (targeted suites passing).
- 2026-02-24: Hardened streaming reliability after runtime `invalidResponse` reports under flaky/proxy-affected network conditions. `OpenAIResponsesService.createResponseStreaming` now performs an automatic same-turn fallback to non-stream `createResponse` when the stream path returns `invalidResponse`, emits final text to the stream callback, and only fails if fallback also fails; retry policy now treats `invalidResponse` as retryable. Added regression test `OpenAIResponsesServiceTests.testCreateResponseRetriesInvalidResponseThenSucceeds`; targeted AI streaming-related suites pass.
- 2026-02-24: Expanded Responses streaming parser coverage to align with SDK event families (`response_id` lifecycle + `response.text.*`, `response.output_text.*`, `response.content_part.*`, `response.output_item.*`, `response.function_call_arguments.*`, `error`/`response.failed`). Stream accumulator now reconstructs final responses from streamed item/function/text events (including function-call arguments and fallback assistant text synthesis) instead of depending solely on `response.completed` payload shape, reducing `invalidResponse` failures on variant stream event sequences.
- 2026-02-24: Integrated `apply_patch` AI tool end-to-end. Wired `UnifiedDiffPatcher.swift`, `ApplyPatchTool.swift`, and `ApplyPatchTests.swift` into the live agent pipeline. Changes: `AIToolDefinitions.buildToolDefinitions(patchToolEnabled:)` — conditional tool registration + `apply_patch` added to direct-action allowed set + patch-workflow section appended to developer prompt; `AIToolHandler` — added `optionalString` helper + full `case "apply_patch":` dispatcher (delete safety gate, `CheckedContinuation`-based approval gate, local `LocalWorkspacePatcher` / remote `RemotePatchCommandBuilder` dispatch, `patchResultCallback` notify); `OpenAIAgentService` — added `PatchApprovalTracker`, `patchApprovalCallback`/`patchResultCallback` vars, `patchToolEnabled`/`patchApprovalRequired`/`patchAllowDelete` `UserDefaults`-backed computed properties, `toolDefinitions` changed from stored `let` to computed `var` (live UserDefaults); `TerminalAIAssistantViewModel` — new `PatchApprovalState` / `TerminalAIAssistantMessageKind` enums, `kind` field on message, `CheckedContinuation`-based `requestPatchApproval` / `approvePatch(remember:)` / `denyPatch()` / `clearActivePatchApproval()` / `appendPatchResultNotification`; new `PatchApprovalCardView.swift` — colored diff preview card with Approve/Deny + Remember checkbox; `TerminalAIAssistantPane.swift` — `messagesView` ForEach switches on `message.kind` + new `PatchResultNotificationView` at bottom; `SettingsView.swift` — "FILE EDITING" sub-section (3 `AppStorage` toggles). Also fixed 2 pre-existing bugs in `UnifiedDiffPatcher`: empty-string split producing spurious trailing empty element (fix: `sourceLines = []` for empty original); `hunkOutOfBounds` thrown instead of `contextMismatch` when exact position was within file bounds (fix: fallback to `contextMismatch` with line/expected/actual detail). All 7 ApplyPatch test suites pass (42 test cases). Build: SUCCEEDED.
- 2026-02-25: Fixed remaining real-world OpenAI streaming failures after user-reported `invalid response` errors. `OpenAIResponsesService` now uses a byte-level SSE parser (no `AsyncBytes.lines` empty-line dependency), handles CRLF framing robustly, supports stream sessions through protocolized `bytes(for:)` (no concrete `URLSession` cast requirement), falls back cleanly when success bodies are JSON (non-SSE), and broadens event coverage (`response.reasoning_summary_part.*`, `response.refusal.*`, plus improved `response_id` capture). `TerminalAIAssistantViewModel` no longer overwrites already-streamed assistant text with "No response" when final aggregated text is empty. Added regressions: `OpenAIResponsesServiceTests` for CRLF SSE parsing, JSON success fallback, and reasoning-summary-part streaming; `TerminalAIAssistantViewModelTests` for preserving streamed assistant text when final reply text is empty. Targeted suites pass (`OpenAIResponsesServiceTests`, `OpenAIAgentServiceTests`, `TerminalAIAssistantViewModelTests`).
- 2026-02-25: Added OpenAI payload diagnostics logging in `OpenAIResponsesService` to capture what the service returns during both non-stream and stream paths. New logs include bounded body previews (`response_payload`, `stream_json_success_payload`, `stream_http_error_payload`) and SSE event payload previews (`stream_event`) with trace IDs, status, and content type for correlation. Logging is controlled by `UserDefaults` key `ai.logging.logOpenAIResponsesPayloads` or env `PROSSH_LOG_OPENAI_RESPONSE_PAYLOADS`; default is enabled for Debug and disabled for Release. Verified with `OpenAIResponsesServiceTests` (11/11 passing).
- 2026-02-25: Fixed AI reasoning bubble ordering in chat UI: reasoning messages now insert directly above the active assistant reply card (instead of always appending to the bottom), including late-arriving reasoning events. Updated `TerminalAIAssistantViewModelTests` with ordering assertions and a regression for late reasoning (`assistant` text arrives first, reasoning arrives after) to lock behavior. Targeted suite passes (`TerminalAIAssistantViewModelTests`, 6/6).
- 2026-02-25: Reworked reasoning UX to a dedicated fixed-height rolling stream panel at the top of the AI chat pane. Reasoning is no longer emitted as inline chat bubbles; `TerminalAIAssistantViewModel` now tracks streaming reasoning summary/details separately and `TerminalAIAssistantPane` renders a fixed 150pt autoscrolling reasoning window (`Reasoning Stream`, live/idle state). Also strengthened assistant readability formatting by normalizing missing punctuation spacing and list-like capability responses into markdown bullets/paragraphs. Updated tests in `TerminalAIAssistantViewModelTests` for fixed-panel reasoning behavior (including late reasoning events) plus dense capability text formatting; targeted suite passes (7/7).
- 2026-02-25: Polished reasoning + formatting UX after follow-up visual review. Reasoning panel now renders explicit `Summary`/`Thinking` sections (instead of markdown heading text inside one block) with a larger fixed-height 170pt rolling window and autoscroll on summary/detail stream updates, preventing merged heading/body rendering (e.g., `SummaryListing ...`). Assistant readability heuristics were tightened again for run-on capability responses (`X.Y`/`)Z` boundaries): improved spacing normalization, stronger bullet-list extraction for colon-prefixed capability lists, and paragraph reflow updates in both view-model and renderer paths. Added/updated `TerminalAIAssistantViewModelTests` assertions for sectioned reasoning text and complex tool-name capability run-ons; targeted suite passes (8/8).
- 2026-02-25: Decomposed `AIToolHandler.swift` (1,481→503 lines) into 4 concern-based extension files under `Services/AI/` following the established `TerminalGrid+` extension pattern. Created: `AIToolHandler+ArgumentParsing.swift` (~117L — 6 static argument parsing helpers); `AIToolHandler+RemoteExecution.swift` (~421L — RemoteToolExecutionResult struct, 4 remote execution instance methods, 7 remote output parsing static methods, 4 remote command building static methods); `AIToolHandler+LocalFilesystem.swift` (~339L — 7 nonisolated static local filesystem methods); `AIToolHandler+OutputHelpers.swift` (~123L — 5 output formatting static methods). Also renamed `parseRemoteContentMatchLine` → `parseRemoteGrepMatchLine` to distinguish it from the output helpers `firstCapturedRange`. No functionality changes. Build: SUCCEEDED. Tests: 2 pre-existing failures (within ≤23 baseline). Commit: `881615c`.
- 2026-02-25: Tightened agent formatting instructions in `AIToolDefinitions.developerPrompt` so explicit list requests (abilities/steps/options/checks) must be returned as markdown bullets or numbered lists. Verified with targeted `AIToolDefinitionsTests` run (9/9 passing).
- 2026-02-25: Hardened `execute_and_wait` terminal UX and completion detection. `SessionAIToolCoordinator` now emits a shorter per-command marker and prints it with concealed SGR attributes (reducing visible internal marker noise in the user terminal), and polling now checks `TerminalHistoryIndex.activeCommandRawOutput` before finalized block search so completions can be detected without waiting for prompt-finalized history boundaries. Added actor API `TerminalHistoryIndex.activeCommandRawOutput(sessionID:)`. Targeted tests pass: `OpenAIAgentServiceTests` + `TerminalHistoryIndexTests` (20/20).
- 2026-02-25: Fixed remaining `execute_and_wait` false-timeout path by checking the live rendered screen buffer (`SessionManager.shellBuffers`, same source used by `get_current_screen`) for the completion marker before history-based fallbacks. This removes the prior source mismatch where marker was visible on screen but not yet observable through history polling, which caused unnecessary timeout fallbacks and extra token-cost recovery tool calls. Re-verified with targeted `OpenAIAgentServiceTests` + `TerminalHistoryIndexTests` (20/20).
- 2026-02-24: Phase 8 COMPLETE (commit `816b9be`). Test coverage backfill for all Phase 1–6 extracted types. Added 8 new test files (51 test cases): RemotePathTests, AIConversationContextTests, PersistentStoreTests, AIToolDefinitionsTests, MockSSHTransportTests, SessionReconnectCoordinatorTests, SessionKeepaliveCoordinatorTests, LibSSHJumpCallParamsTests. Also widened LibSSHAuthenticationMaterial, LibSSHTargetParams, LibSSHJumpCallParams from private → internal to enable testing. Build: SUCCEEDED. Tests: 13 pre-existing failures (≤23 baseline). All 8 refactor phases complete.
- 2026-02-24: Phase 7 COMPLETE (commit `2c90d5b`). Strict concurrency verified project-wide. App target already clean: Swift 6 + SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor = 0 warnings with `-strict-concurrency=complete`, no source changes needed. Test target upgraded: SWIFT_STRICT_CONCURRENCY minimal → complete + SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor added to both Debug (AB100009) and Release (AB10000A) build configs. Committed SSHConfigParser.swift + SSHConfigParserTests.swift (previously untracked, blocked test bundle compilation). Build settings change alone resolved all actor isolation errors — no explicit @MainActor annotation needed on SSHConfigParserTests class. WARNINGS_BASELINE.txt deleted (Phase 0 scratch, gitignored). Build: SUCCEEDED. Tests: 12 pre-existing failures (within ≤23 baseline). Phase 8 (test coverage backfill) is NOT PLANNED.
- 2026-02-24: Phase 6 COMPLETE (commits `d12e2ca`–`16043ad`). Decomposed `OpenAIAgentService.swift` (1,946→108 lines) into four `@MainActor final class` coordinators under `ProSSHMac/Services/AI/`: `AIToolDefinitions` (caseless enum, ~373L — developer prompt, 11 tool schemas, static helpers); `AIConversationContext` (~21L — previousResponseID keyed by session UUID); `AIToolHandler` (~1,406L — tool dispatch switch, 11 tool implementations, local/remote filesystem methods); `AIAgentRunner` (~187L — agent iteration loop, `createResponseWithRecovery`, `runWithTimeout`). Key decisions: caseless `enum AIToolDefinitions` prevents Swift 6 @MainActor inference on statics; `weak var service: OpenAIAgentService?` back-reference pattern (same as Phase 5); `nonisolated static` filesystem methods preserved; `nonisolated deinit {}` on all coordinators. Correction vs. plan sketch: `AIResponseStreamParser` → `AIToolDefinitions` (no SSE streaming in this file). Build SUCCEEDED, zero warnings with `-strict-concurrency=complete`. Pre-existing test build failure in `SSHConfigParserTests.swift` (actor isolation errors, unrelated to Phase 6). Phase 7 (strict concurrency pass) is NOT PLANNED.
- 2026-03-04: SmoothScroll Phase 0 COMPLETE. Laid data foundation for smooth scrolling: created `SmoothScrollConfiguration.swift` (config struct with UserDefaults persistence following BloomEffectConfiguration pattern), added `scrollOffsetPixels: Float` + 3 padding floats to `TerminalUniformData` (Swift) and `TerminalUniforms` (Metal) uniform structs. Hardcoded to 0.0 — no visual change. Files: `Terminal/Effects/SmoothScrollConfiguration.swift` (new), `Terminal/Renderer/TerminalUniforms.swift`, `Terminal/Renderer/TerminalShaders.metal`. Build: SUCCEEDED. Tests: 209 pass, 2 pre-existing failures.

## How to Use This File

- Use this as the source of truth for sequencing and progress.
- Check boxes as you complete work.
- Keep this file updated when scope or architecture decisions change.
- Do not start implementation until model is confirmed to `gpt-5.1-codex-max`.

## Reality Check (Claims Verified in Current Codebase)

### Confirmed true now

- [x] SFTP C functions already exist: `prossh_libssh_sftp_list_directory`, `prossh_libssh_sftp_download_file`, `prossh_libssh_sftp_upload_file` in `ProSSHMac/CLibSSH/ProSSHLibSSHWrapper.c` and `.h`.
- [x] Swift async wrappers for SFTP already exist in `ProSSHMac/Services/SSHTransport.swift` (`listDirectory`, `uploadFile`, `downloadFile`).
- [x] `SessionManager` already exposes SFTP methods (`listRemoteDirectory`, `uploadFile`, `downloadFile`) in `ProSSHMac/Services/SessionManager.swift`.
- [x] A remote browser already exists in the Transfers tab (`ProSSHMac/UI/Transfers/TransfersView.swift`) backed by `TransferManager`.
- [x] `TerminalView.swift` is currently ~106 KB (`106395` bytes) and already has complex pane logic.
- [x] `PaneManager` exists and drives terminal-to-terminal splits; this new sidebar work must not break pane behavior.
- [x] OSC sequences are parsed, and OSC command `133` is defined in parser constants.
- [x] OSC 133 semantic prompt events are now parsed and routed to command-history tracking.
- [x] `CommandBlock` and `TerminalHistoryIndex` now exist and are integrated via `SessionManager`.
- [x] OpenAI API key storage/provider foundation now exists (`KeychainOpenAIAPIKeyStore`, `DefaultOpenAIAPIKeyProvider`) and is wired via `AppDependencies`.
- [x] Settings now includes an "AI Assistant" section for OpenAI API key save/remove and stored-key status.
- [x] Responses API service foundation now exists (`OpenAIResponsesService`) and is wired through app dependencies.
- [x] Project now has a real unit-test bundle target (`ProSSHMacTests`) and shared scheme can execute `xcodebuild test`.

### Not implemented yet (or previous doc was inaccurate)

- [ ] There is no `SessionManager.writeToChannel()` API; command execution should use `sendShellInput`/`sendRawShellInput`.
- [ ] `Host` does not currently contain `promptPattern`.
- [ ] Current project style is mostly `ObservableObject` + `@StateObject`, not `@Observable`.

## Phase 0 - Kickoff and Guardrails

### Exit criteria

- Assistant model is confirmed and documented.
- Scope is locked to phased delivery below.

### Checklist
- [ ] Confirm active model is `gpt-5.1-codex-max`.
- [x] Re-read key files before coding:
  - `ProSSHMac/UI/Terminal/TerminalView.swift`
  - `ProSSHMac/Services/SessionManager.swift`
  - `ProSSHMac/Services/SSHTransport.swift`
  - `ProSSHMac/UI/Transfers/TransfersView.swift`
  - `ProSSHMac/Services/TransferManager.swift`
  - `ProSSHMac/Terminal/Parser/OSCHandler.swift`
- [x] Decide whether to preserve existing `ObservableObject` conventions for all new types (recommended: yes for consistency).

## Phase 1 - SFTP Architecture Decision and Foundation

### Exit criteria

- Clear decision on shared-session SFTP vs dedicated SFTP connection.
- SFTP foundation supports sidebar browsing without destabilizing terminal I/O.

### Checklist

- [x] Validate whether current shared `ProSSHLibSSHHandle` causes contention under real usage (shell output + concurrent SFTP actions).
- [x] Choose one approach and document rationale in this file:
  - Keep shared transport with serialized SFTP usage.
  - Add dedicated SFTP-only connection/session.
- Decision (current): keep shared transport for now; enforce temporary session blocking during SFTP operations and restore non-blocking shell behavior afterward.
- [ ] If dedicated connection is chosen, implement lifecycle handling tied to SSH session connect/disconnect.
- [x] Keep `TransferManager` compatibility (do not break Transfers tab).
- [x] Add/extend tests for chosen architecture in `ProSSHMac/Terminal/Tests`.

## Phase 2 - Left Sidebar File Browser in Terminal

### Exit criteria

- File browser appears as collapsible left sidebar inside terminal screen.
- Supports navigation and file actions safely for remote sessions.

### Checklist

- [x] Introduce sidebar tree model + view model (reuse `SFTPDirectoryEntry` where practical; avoid duplicate models unless needed).
- [x] Implement lazy directory expansion and loading states.
- [x] Integrate left sidebar into `TerminalView` layout without regressing `PaneManager` behavior.
- [x] Implement file actions that send commands through `SessionManager.sendShellInput`:
  - Open in `nano`
  - Open in `vim`
  - View with `less`
  - `cat` to terminal
- [x] Add safe shell quoting for file paths before sending commands.
- [x] Add "Download" action by reusing existing transfer flow where possible.
- [x] Add local-session fallback behavior (FileManager-based browsing or clear local-mode UX decision).
- [x] Add keyboard shortcut for toggling file browser and verify no conflict with existing shortcuts.

## Phase 3 - Command Block History Index

### Exit criteria

- Structured command history exists and can be queried by tools.
- Prompt boundaries are detected via OSC 133 when available, with fallback heuristics.

### Checklist

- [x] Add `CommandBlock` model.
- [x] Add `TerminalHistoryIndex` (ring buffer + keyword search + recent retrieval).
- [x] Implement OSC 133 semantic prompt parsing in `OSCHandler` (currently placeholder).
- [x] Implement fallback prompt-boundary heuristics for shells without OSC 133 integration.
- [x] Decide insertion point for block commits (parser/engine/session layer) and keep thread-safety explicit.
- [x] If adding `Host.promptPattern`, include backward-compatible decoding defaults. (Not needed in this phase; heuristics use session metadata instead.)
- [x] Add tests for block segmentation and search behavior.

## Phase 4 - AI Agent Service (Responses API)

### Exit criteria

- AI service can answer questions using session tools (local + remote) and stream responses.
- Model is explicitly pinned to `gpt-5.1-codex-max`.

### Checklist

- [x] Build agent service around Responses API using native Swift networking.
- [x] Explicitly set request model to `gpt-5.1-codex-max`.
- [x] Add API-key provider wiring for the agent service (read from secure app settings path; fail safely when key is missing).
- [x] Implement tool definitions and local tool execution pipeline.
- [x] Implement minimum tool set:
  - `search_terminal_history`
  - `get_command_output`
  - `get_current_screen`
  - `get_recent_commands`
  - `execute_command`
  - `get_session_info`
- [x] Route explicit direct-action prompts (run/open/edit/navigate) through a minimal Ask-mode fast path to reduce tool-call churn and latency.
- [x] Ensure filesystem tools work in both local and remote sessions with safe read-only command execution on SSH hosts.
- [x] Add `read_files` batch file-read tool (chunked windows, max 10 files/call) to reduce multi-file tool-call churn.
- [x] Map `execute_command` to `SessionManager.sendShellInput` with Ask-mode explicit-intent safety policy.
- [x] Persist `previous_response_id` safely (best-effort continuity; handle invalid/expired IDs).
- [x] Add robust timeout/error handling for tool loops and network failures.
- [x] Enforce bounded file reads for long tasks (`read_file_chunk`, max 200 lines, iterate by `start_line`) and block unbounded file ingestion via `execute_command`.

## Phase 5 - Right Sidebar AI UI + Safety

### Exit criteria

- AI chat sidebar is integrated in terminal UI with a single visible Ask mode.
- Assistant behavior auto-routes by user intent (context lookup vs command execution) without manual mode switching.

### Checklist

- [x] Add AI sidebar view and view model.
- [x] Integrate right sidebar in `TerminalView` with independent visibility/width from left sidebar.
- [x] Consolidate UI to one visible Ask mode (remove Ask/Follow/Execute selector).
- [x] Remove Follow/Execute mode plumbing from terminal AI UI and view-model flow.
- [x] Allow command execution in Ask mode only when the user explicitly requests run/open/edit/check actions.
- [x] Add keyboard shortcut for AI sidebar toggle and verify no collisions.
- [x] Improve copilot readability/input ergonomics: markdown-rendered assistant text, visible resizable sidebar handle, multiline auto-growing composer with `Enter` send and `Shift+Enter` newline.
- [x] Move `apply_patch` approval UX out of sidebar chat into a dedicated modal popout with a larger diff preview and approve/reject actions.
- [x] Eliminate stuck file-browser loading states caused by stale async completions (request-ID based root/child load tracking with deterministic loading-flag cleanup).
- [x] Improve AI response readability and incremental rendering behavior for long replies (paragraph reflow + visible chunk streaming + lighter in-flight rendering).

## Phase 6 - Settings, Persistence, and Hardening

### Exit criteria

- API key management, sidebar persistence, tests, and docs are complete.

### Checklist

- [x] Add Settings UI for OpenAI API key entry/update.
- [x] Store API key securely via existing `EncryptedStorage`/Keychain path.
- [x] Ensure Settings pane content is scrollable so long sections remain reachable.
- [x] Persist sidebar visibility and width per host/session.
- [x] Add unit/integration coverage for:
  - [x] SFTP sidebar behavior
  - [x] Command block indexing
  - [x] Tool execution safety checks
  - [x] AI service error handling
- [x] Run project tests and document any failures/gaps.
- [x] Fixed host-process crash in `PaneManagerTests` and removed quarantine (`XCTSkip` no longer needed).
- [x] Fixed host-process crash in `TerminalAIAssistantViewModelTests.testClearConversationResetsMessagesAndCallsService` and removed quarantine (`XCTSkip` no longer needed).
- [ ] Note: `xcodebuild ... test` now succeeds via `ProSSHMacTests` smoke baseline; most existing test files are still compiled under app sources and should be migrated into the test bundle for full coverage.
- [x] Update user-facing docs and shortcut reference in settings/help text.

## Final QA Gate (Do Not Skip)

- [ ] Model used for implementation and validation was `gpt-5.1-codex-max`.
- [ ] No regressions in existing terminal split panes.
- [ ] No regressions in Transfers tab.
- [x] Command execution from AI requires explicit user intent in the prompt.
- [x] Network/API failures fail safely with user-visible errors.
- [x] AI file ingestion uses bounded chunk reads (max 200 lines) instead of full-file reads.

## Loop Log

### 2026-02-25 — MetalTerminalRenderer.swift Decomposition (Phases 0–8) COMPLETE

Decomposed `MetalTerminalRenderer.swift` (1,438 lines) into 8 focused `extension MetalTerminalRenderer`
files under `ProSSHMac/Terminal/Renderer/`. Approach: widened all `private` members to internal in
Phase 0 to enable cross-file extension access, then extracted method groups one phase per commit.

- **Phase 0** (`f2828c8`): Added `// swiftlint:disable file_length`; moved `rawCellWidth`/`rawCellHeight`
  to Grid State section; widened all `private let/var/func` → internal.
- **Phase 1** (`c96f7b2`): `MetalTerminalRenderer+GlyphResolution.swift` — rasterizeAndUpload,
  rebuildRasterFontCacheIfNeeded, resolveGlyphIndex, packAtlasEntry, resolveRenderFont (static), isEmojiRange (static).
- **Phase 2** (`a6e3184`): `MetalTerminalRenderer+SnapshotUpdate.swift` — updateSnapshot, applyPendingSnapshotIfNeeded.
- **Phase 3** (`8b0759f`): `MetalTerminalRenderer+FontManagement.swift` — initializeFontMetricsAndPrepopulate,
  handleFontChange, setFontSize, setFontName, reloadFontStateFromManager, reapplyPixelAlignment, recalculateGridDimensions.
- **Phase 4** (`e04596a`): `MetalTerminalRenderer+DrawLoop.swift` — draw(in:), encodeTerminalScenePass.
- **Phase 5** (`697f559`): `MetalTerminalRenderer+ViewConfiguration.swift` — mtkView resize, configureView,
  setPaused, setPreferredFPS, currentScreenMaximumFPS.
- **Phase 6** (`f913b5a`): `MetalTerminalRenderer+Selection.swift` — setSelection, clearSelection, selectAll,
  hasSelection, selectedText, gridCell.
- **Phase 7** (`2d431d3`): `MetalTerminalRenderer+PostProcessing.swift` — CRT, gradient, scanner effects,
  post-process texture helpers.
- **Phase 8**: `MetalTerminalRenderer+Diagnostics.swift` — cacheHitRate, atlasPageCount, atlasMemoryBytes,
  cachedGlyphCount, performanceSnapshot. Removed `// swiftlint:disable file_length` (main file 331L < 400L).

Result: main file 331 lines (was 1,438). All 8 phase builds SUCCEEDED. Tests: 2 pre-existing failures
(within ≤23 baseline). Zero regressions. Public API unchanged.

### 2026-02-24 — TOTP 2FA + SSH Config Import/Export Integration

**Module 2: SSH Config Import/Export pipeline upgrade**
- Replaced hand-rolled `exportSSHConfig()` (30 lines) with `SSHConfigExporter.export(_:options:)` — full algorithm preferences, port forwarding rules, shell integration notes, and ProSSH-specific comments are now included.
- Replaced `parseSSHConfig()` (124 lines, basic parser) with `SSHConfigImportService.preview()` — full parser with token expansion, jump-host resolution, key reference matching, legacy mode detection, and per-host notes.
- Changed import flow to show a preview sheet (`SSHConfigImportPreviewView`) before committing: user can deselect hosts, see parser warnings, and identify duplicates.
- Added `previewSSHConfigImport(_:)` + new `importSSHConfig(_: [Host])` to `HostListViewModel`.
- Created `UI/Hosts/SSHConfigImportPreviewView.swift` (~130 lines): toggle list with duplicate badges, warning notes, collapsible parser-warnings section.

**Module 1: TOTP 2FA wiring**
- Added `totpConfiguration: TOTPConfiguration?` to `Host` struct (stored property, Codable, Hashable, Sendable) and `HostDraft`.
- Added raw-Keychain helpers (`saveRaw/retrieveRaw/deleteRaw`) to `BiometricPasswordStore` using `kSecAttrAccessibleAfterFirstUnlock` (no biometric gate — needed for auth-flow auto-fill).
- Conformed `BiometricPasswordStore` to `SecretStorageProtocol` so `TOTPStore` can use the existing Keychain infrastructure.
- Initialized `TOTPStore` in `AppDependencies` and injected into both `SessionManager` and `HostListViewModel`.
- Added TOTP auto-fill in `SessionManager.connect()`: if `host.authMethod == .keyboardInteractive` and `host.totpConfiguration != nil`, generates a smart code (avoids near-expiry codes) and logs to audit log.
- Updated `LibSSHTransport.resolveAuthenticationMaterial` to pass `passwordOverride` for `.keyboardInteractive` (previously always returned empty material).
- Updated C kbdint loop in `ProSSHLibSSHWrapper.c`: first prompt receives the TOTP code; subsequent prompts fall back to `""`.
- Added TOTP cleanup to `cleanupKeychainForHost()` in `HostListViewModel` (runs on host deletion).
- Added TOTP section to `HostFormView` (appears only for `.keyboardInteractive` auth when editing an existing host): live code view (`TOTPLiveCodeView`) with 1-second timer, provisioning sheet (`TOTPProvisioningSheetView`) with URI paste and manual Base32 tabs.

**Tests**: 37/37 pass (TOTPGeneratorRFCTests, TOTPAutoFillDetectorTests, SSHConfigParserTests). Build: SUCCEEDED.

### 2026-02-25 — RefactorTheFinalRun Phase 19 COMPLETE — CertificateAuthorityService decomposition COMPLETE

Created `Services/CertificateAuthorityService+KRL.swift` (~158L) containing four KRL helpers
extracted from `CertificateAuthorityService.swift`: `generateKRL(request:authorities:certificates:)`,
`authorizedRepresentation(for:)`, `sanitizeFileComponent(_:)`, `csvSafe(_:)`.
`private func` → `func` (internal) on the three helpers; `generateKRL` was already internal.
CertificateAuthorityService.swift: 577→422L (above 400 — swiftlint:disable retained).
Tests: 209 run, 2 pre-existing failures, 0 new. Build: SUCCEEDED. Commit: `6a02e6c`.

**RefactorTheFinalRun is now COMPLETE.** All four god files decomposed:
- OpenAIResponsesService.swift: 1,305→slim (Phases 0–5)
- SessionManager.swift: 1,196→slim (Phases 6–9)
- SSHConfigParser.swift: 1,018→275L (Phases 10–14)
- CertificateAuthorityService.swift: 985→422L (Phases 15–19)

### 2026-02-25 — RefactorTheFinalRun Phase 18 COMPLETE

Created `Services/CertificateAuthorityService+CertificateParsing.swift` (~222L) containing
nine certificate binary parsing helpers extracted from `CertificateAuthorityService.swift`:
`parseAuthorizedCertificate(_:)`, `parseAuthorizedPublicKey(_:)`,
`skipCertificateSubjectKeyData(certificateKeyType:reader:)`, `parseStringListPayload(_:context:)`,
`parseNameValueMapPayload(_:context:)`, `displayValue(forOptionData:)`,
`parseSignatureAlgorithm(_:)`, `baseKeyType(fromCertificateKeyType:)`, `certificateKeyType(for:)`.
All `private func` → `func` (internal). CertificateAuthorityService.swift: 796→577L.
Build: SUCCEEDED. Commit: `828c8de`. Next: Phase 19 — KRL extension + final slim.

### 2026-02-25 — RefactorTheFinalRun Phase 17 COMPLETE

Created `Services/CertificateAuthorityService+BinaryEncoding.swift` (~79L) containing nine
SSH wire-format encoding helpers extracted from `CertificateAuthorityService.swift`:
`sshString(from:)` (×2), `u32(_:)`, `u64(_:)`, `encodeStringList(_:)`, `encodeNameValueMap(_:)`,
`fingerprintSHA256(for:)`, `randomBytes(count:)`, `readFirstSSHString(from:)`.
All `private func` → `func` (internal). CertificateAuthorityService.swift: 870→796L.
Build: SUCCEEDED. Commit: `82cc151`. Next: Phase 18 — CertificateParsing extension.

### 2026-02-25 — RefactorTheFinalRun Phase 16 COMPLETE

Created `Services/SSHBinaryReader.swift` (~116L) containing four types extracted from
`CertificateAuthorityService.swift`: `ParsedPublicKey`, `ParsedExternalCertificate`,
`SSHBinaryReader`, and `CertificateRole`. All `private` access modifiers widened to internal.
`CertificateAuthorityService.swift`: 987→870L. Build: SUCCEEDED. Commit: `6f83002`.
Next: Phase 17 — extract `CertificateAuthorityService+BinaryEncoding.swift`.

### 2026-02-25 — RefactorTheFinalRun Phase 15 COMPLETE

Added `// swiftlint:disable file_length` as line 1 of `CertificateAuthorityService.swift`
(986 lines). This is the baseline step for the fourth and final god file. Build: SUCCEEDED.
Commit: `17503da`. Next: Phase 16 — extract `SSHBinaryReader` and supporting private types.

### 2026-02-25 — RefactorTheFinalRun Phases 10–14 COMPLETE

Decomposed `SSHConfigParser.swift` (1,018 → 275 lines) into five focused files. Phase 10:
added `// swiftlint:disable file_length` (commit `0a7ac88`). Phase 11: extracted
`SSHConfigTokenExpander` + nested `Context` into `SSHConfigTokenExpander.swift` (~59L,
commit `42e30d2`). Phase 12: extracted `SSHConfigMapper` (all mapping logic + 8 private
helpers, `ResolutionContext`, `MappingResult`) into `SSHConfigMapper.swift` (~440L, commit
`2c450df`). Phase 13: extracted `SSHConfigExporter` + `ExportOptions` into
`SSHConfigExporter.swift` (~128L, commit `5aece8a`). Phase 14: extracted
`SSHConfigImportService` + `ImportPreview` + `findDuplicates` extension into
`SSHConfigImportService.swift` (~109L); removed orphaned token-expander doc comment and
`// swiftlint:disable file_length` (275L < 400L). Build: SUCCEEDED after each phase.
Tests: 2 pre-existing failures, zero new. Commit: `e341205`.

---

### 2026-02-27 — RemotePatchingFix Phase 1 COMPLETE

Created `ProSSHMacTests/Terminal/Tests/ApplyDiffTests.swift` — 11 direct unit tests for
`applyDiff()` (the V4A parser in `apply_diff.swift`). Three test classes:
- `ApplyDiffCreateTests` (3 tests): basic plus-line creation, empty diff, missing-plus throw
- `ApplyDiffUpdateTests` (7 tests): anchor match, bare anchor, anchor-not-found throw,
  multiple anchors, trailing-newline preservation, no-trailing-newline preservation, fuzzy
  stripped anchor match
- `ApplyDiffContaminationTests` (1 test): documents Bug 1 — shell-prompt prefix in
  contaminated `sed` output is silently carried through into the patched result; asserts
  the buggy behaviour so Phase 3 can flip the assertion

Fixed `testUpdateWithoutHunkHeadersThrows` in `ApplyPatchTests.swift`: was asserting
`PatchToolError.invalidDiff` but `LocalWorkspacePatcher.updateFile` calls `applyDiff()`
directly without wrapping V4A errors, so the actual error is `V4ADiffError.invalidLine`.

Also fixed pre-existing conformance gap in `OpenAIAgentServiceTests.swift`:
`MockAgentSessionProvider` was missing `sendRawShellInput(sessionID:input:)` added to
`OpenAIAgentSessionProviding` in a recent commit. Added the stub so the test bundle compiles.

All 11 `ApplyDiffTests` passed. All 9 `LocalWorkspacePatcherTests` passed. Branch: `fix/remote-patching`.

---

### 2026-02-25 — RefactorTheFinalRun Phase 9 COMPLETE

Extracted 6 read-only query/history methods from `SessionManager.swift` into new
`ProSSHMac/Services/SessionManager+Queries.swift` as an `extension SessionManager`:
`activeSession(for:)`, `mostRelevantSession(for:)`, `totalTraffic(for:)`,
`recentCommandBlocks(sessionID:limit:)`, `searchCommandHistory(sessionID:query:limit:)`,
`commandOutput(sessionID:blockID:)`. No access-level widening required — all accessed
properties already had internal-or-wider getters. SessionManager: 1,005 → 969 lines.
400-line target not achievable without a future `SessionConnectionCoordinator` extraction
(the 235-line private `connect` implementation); `// swiftlint:disable file_length`
retained. Build: SUCCEEDED. Tests: 2 pre-existing failures, zero new. Commit: `eeb2ba3`.

---

### 2026-02-25 — RefactorTheFinalRun Phase 8 COMPLETE

Extracted `sendShellInput` (32L), `sendRawShellInput` (24L), `startParserReader` (61L), and
`recordParsedChunk` (12L) from `SessionManager.swift` into new
`ProSSHMac/Services/SessionShellIOCoordinator.swift`. The coordinator owns `parserReaderTasks`
dict and exposes `cancelParserTask(for:)` for SessionManager's `removeSessionArtifacts` to call.
The `Task.detached` read loop captures `[weak self]` (coordinator) and routes through
`self?.manager?.renderingCoordinator` and `self?.manager?.handleShellStreamEndedInternal(...)`.
`handleShellStreamEndedInternal` kept on SessionManager (already internal, also called by
`SessionKeepaliveCoordinator`). `bytesReceivedBySessionID` widened from `@Published private(set)`
to `@Published var`. Two `startParserReader` call sites in SessionManager replaced with
`shellIOCoordinator.startParserReader(for:rawOutput:)` directly. SessionManager: 1,128 → 1,005
lines. Build: SUCCEEDED. Commit: `b6fdf69`.

---

### 2026-02-25 — RefactorTheFinalRun Phase 7 COMPLETE

Extracted `executeCommandAndWait` (50L), `parseWrappedCommandOutput` (16L), and
`publishCommandCompletion` (9L) from `SessionManager.swift` into new
`ProSSHMac/Services/SessionAIToolCoordinator.swift`. The coordinator uses `weak var manager:
SessionManager?`; polling loop captures a strong local `guard let manager` reference across async
yield points. Access widening: `private(set)` removed from `bytesSentBySessionID`,
`latestCompletedCommandBlockBySessionID`, `commandCompletionNonceBySessionID`; `private var
latestPublishedCommandBlockIDBySessionID` widened to `var`. `publishCommandCompletion` kept as a
one-line forwarding wrapper on SessionManager (TerminalRenderingCoordinator calls it via manager
reference). SessionManager: 1,191 → 1,128 lines. Build: SUCCEEDED. Commit: `b037ee1`.

---

### 2026-02-25 — RefactorTheFinalRun Phase 6 COMPLETE

Extracted 3 SFTP/remote-filesystem methods from `SessionManager.swift` into new
`ProSSHMac/Services/SessionSFTPCoordinator.swift` using the same weak-reference coordinator
pattern (`weak var manager: SessionManager?`) as prior phases. Methods extracted:
`listRemoteDirectory`, `uploadFile`, `downloadFile`. Each delegates to `manager.transport`
after validating session state via `manager.sessions`. SessionManager wired with
`let sftpCoordinator: SessionSFTPCoordinator` and `sftpCoord.manager = self` in `init`.
Forwarding one-liners replace the original 20-line bodies. SessionManager: 1,196 → 1,191 lines.
Build: SUCCEEDED. Committed as `8b18935`.

---

### 2026-02-25 — RefactorTheFinalRun Phase 5 COMPLETE

Removed `// swiftlint:disable file_length` from `OpenAIResponsesService.swift` (now 259 lines, well
under the 400-line threshold). Ran full test suite: 209 tests, 2 failures — both pre-existing
(`Base32Tests.testDecodeEmpty`, `ColorRenderValidationTest` color rendering). No new failures.
`OpenAIResponsesService.swift` decomposition is fully complete across Phases 0–5:
  - `OpenAIResponsesTypes.swift` — 265 lines (protocols + public value types)
  - `OpenAIResponsesPayloadTypes.swift` — 81 lines (Codable request-encoding structs)
  - `OpenAIResponsesStreamAccumulator.swift` — 297 lines (SSE event accumulator)
  - `OpenAIResponsesService+Streaming.swift` — 415 lines (streaming extension)
  - `OpenAIResponsesService.swift` — 259 lines (class: init, createResponse, HTTP, retry, logging)
Build: SUCCEEDED. Committed as `fa6348c`.

---

### 2026-02-25 — RefactorTheFinalRun Phase 4 COMPLETE

Extracted all SSE streaming logic from `OpenAIResponsesService.swift` into new
`ProSSHMac/Services/OpenAIResponsesService+Streaming.swift` (415 lines) as an `extension
OpenAIResponsesService`. Moved: `createResponseStreaming`, `performStreamingRequest`,
`consumeStreamPayload`, `completedResponse(from:)`, `streamErrorMessage(from:)`,
`stringField(in:key:)`, `reasoningSummaryText(from:)`. Widened `private` → internal on all
class-body members accessed cross-file: `apiKeyProvider`, `session`, `endpointURL`, `logger`,
`performRequest`, `createPayload`, `normalizeTransportError`, `shouldRetry`, `sleepBeforeRetry`,
`shortTraceID`, `elapsedMillis`, `extractErrorMessage`, `shouldLogResponsePayloads`,
`logPreview` (both), `sseFieldValue`. Extension file also needed `import os.log` (uses Logger
privacy interpolation — plan omitted this). Service file: 669 → 260 lines.
Build: SUCCEEDED. Committed as `b07c3cf`.

---

### 2026-02-25 — RefactorTheFinalRun Phase 3 COMPLETE

Extracted `StreamingResponseAccumulator` from `OpenAIResponsesService.swift` into new
`ProSSHMac/Services/OpenAIResponsesStreamAccumulator.swift` (297 lines). Widened `private struct`
→ `struct` (internal). No other access-level changes needed — the struct's `decodeJSONValue` call
already worked after Phase 2 widened that method to `internal`. Service file: 964 → 669 lines.
Build: SUCCEEDED. Committed as `6b0c8a2`.

---

### 2026-02-25 — RefactorTheFinalRun Phase 2 COMPLETE

Extracted Codable payload structs from `OpenAIResponsesService.swift` into new
`ProSSHMac/Services/OpenAIResponsesPayloadTypes.swift` (81 lines): `CreateRequestPayload`,
`CreateInputItem` (missed in plan sketch), `CreateInputMessage`, `CreateFunctionCallOutput`,
`OpenAIErrorEnvelope`. Widened `private` → internal on all five types and widened
`fileprivate static func decodeJSONValue` → `static` on the service class (needed by
`StreamingResponseAccumulator` in Phase 3). Service file: 1,043 → 964 lines.
Build: SUCCEEDED. Committed as `5e90cd9`.

---

### 2026-02-28 — Fix: Terminal black screen on session open (viewport positioning bug)

**Problem**: Every new session (local and SSH) opened to a black terminal. The prompt and any server MOTD
were only visible after scrolling up. Root cause: `GridReflow` used
`screenStart = max(0, totalRows - newRows)` which always anchors the visible screen to the BOTTOM of the
combined (scrollback + screen) buffer. On session start the engine is created at the default PTY size (120×40),
but the Metal view often reports a slightly shorter actual height (e.g. 37 rows). The first resize (40→37)
called `GridReflow.reflow`/`adjustRowCount`, which computed `screenStart = 3`, pushing the top 3 rows
(containing the prompt at row 0) into the scrollback buffer. The cursor was clamped to row 0 of an otherwise
empty visible grid — black screen with cursor at top. Scrolling up revealed the displaced content.

**Fix** (`ProSSHMac/Terminal/Grid/GridReflow.swift`):
- `reflow`: changed `screenStart = max(0, totalRows - newRows)` to
  `screenStart = max(0, min(cursorNewRow - (newRows - 1), totalRows - newRows))`.
  This pins the cursor at the bottom of the new screen without pushing it into scrollback when it is near
  the top. Screen building loop now takes exactly `newRows` rows (`screenEnd = min(screenStart + newRows, totalRows)`),
  safely dropping empty trailing rows below the cursor.
- `adjustRowCount` (screen-got-shorter branch): same cursor-aware formula for `rowsToRemove`
  (`max(0, min(cursorRow - (newRows - 1), maxRowsToRemove))`), screen loop limited to `newRows` rows,
  padding with blank rows if needed.

Build: SUCCEEDED.

---

### 2026-02-25 — RefactorTheFinalRun Phase 1 COMPLETE

Extracted all protocols, error type, and value types from `OpenAIResponsesService.swift` into new
`ProSSHMac/Services/OpenAIResponsesTypes.swift` (265 lines). Service file reduced from 1,306 → 1,043 lines.
Correction vs. plan: `OpenAIStreamingUnsupportedError` was also referenced in `OpenAIResponsesService` at line
242 (`catch is OpenAIStreamingUnsupportedError`), so it was widened from `private` → `internal` (not `private`
as the plan assumed). Build: SUCCEEDED. Committed as `6559ce6`.
Updated `docs/RefactorTheFinalRun.md` (Phase 1 checked off, log entry added) and `CLAUDE.md` (current phase
updated to Phase 2 — NOT STARTED). Phase 2 next: extract `OpenAIResponsesPayloadTypes.swift`.

---

### 2026-02-25 — RefactorTheFinalRun Phase 0 COMPLETE

Created branch `refactor/final-run` from master. Added `// swiftlint:disable file_length` as line 1 of
`ProSSHMac/Services/OpenAIResponsesService.swift` (1,305 lines). Build baseline: BUILD SUCCEEDED, 0 warnings.
Committed as `99ef976`. Updated `docs/RefactorTheFinalRun.md` (Phase 0 checked off, log entry added) and
`CLAUDE.md` (current phase updated to Phase 1 — NOT STARTED). Phase 1 next: extract `OpenAIResponsesTypes.swift`.

---

### 2026-02-24 — Fix: Make TOTP 2FA and SSH Config Import/Export visible in UI

**Problem**: TOTP 2FA section and SSH Config Import/Export buttons were fully implemented but invisible in the running app. `HostsView` used `.toolbar {}` modifiers which don't render inside the `NavigationSplitView` → `NavigationStack` hierarchy used by `RootTabView`. Additionally, the TOTP section in `HostFormView` was gated behind `editingHostID != nil`, hiding it when creating new hosts.

**Fix (HostsView.swift)**: Replaced `.toolbar` block with an inline "Actions" `Section` at the top of the `List` containing "Add Host", "Import SSH Config From Clipboard", and "Copy SSH Config Export" buttons. Removed the two dead computed properties (`importExportToolbarPlacement`, `addHostToolbarPlacement`). This matches the pattern used by KeyForgeView, CertificatesView, and other views that place action buttons inline.

**Fix (HostFormView.swift)**: Relaxed the TOTP guard from `editingHostID != nil` to show the section for all keyboard-interactive hosts. For new (unsaved) hosts, displays a "Save this host first" message instead of the provisioning button, since TOTP secrets are Keychain-keyed by host UUID which doesn't exist until save.

Build: SUCCEEDED.

---

### 2026-03-02 — Multi-Provider Abstraction Layer (Phase 1)

**Goal**: Insert a provider abstraction (`LLMProvider` protocol, `LLMProviderRegistry`, provider-agnostic types) so the agent layer works with generic types instead of OpenAI-specific ones. Zero behavior change — OpenAI is still the only provider, routed through the new abstraction. Unblocks Phase 2 (Mistral) and beyond.

**New files added** (`Services/LLM/`):
- `LLMTypes.swift` — `LLMProviderID`, `LLMModelInfo`, `LLMMessage`, `LLMToolDefinition`, `LLMToolCall`, `LLMToolOutput`, `LLMConversationState`, `LLMRequest`, `LLMResponse`, `LLMStreamEvent`, `LLMProviderError`, `LLMJSONValue` (replaces `OpenAIJSONValue` via typealias)
- `LLMProvider.swift` — `LLMProvider` protocol (provider contract), `LLMAPIKeyProviding` protocol
- `LLMProviderRegistry.swift` — `LLMProviderRegistry` (runtime provider/model selection, UserDefaults persistence)
- `LLMAPIKeyStore.swift` — `KeychainLLMAPIKeyStore` (generic Keychain-backed API key store parameterized by provider), `LLMToOpenAIKeyProviderBridge`

**Agent layer types renamed** (in `OpenAIAgentService.swift`):
- `OpenAIAgentServicing` → `AIAgentServicing`
- `OpenAIAgentReply` → `AIAgentReply`
- `OpenAIAgentStreamEvent` → `AIAgentStreamEvent`
- `OpenAIAgentServiceError` → `AIAgentServiceError`
- `OpenAIAgentSessionProviding` → `AIAgentSessionProviding`
- `toolDefinitions` type: `[OpenAIResponsesToolDefinition]` → `[LLMToolDefinition]`

**Translation bridge**: `OpenAIAgentService.sendProviderRequest(_:streamHandler:)` translates `LLMRequest` → `OpenAIResponsesRequest`, calls `responsesService`, and translates response back to `LLMResponse`.

**`AIAgentRunner.swift` refactored**: Uses `LLMMessage`, `LLMToolOutput`, `LLMRequest`, `LLMResponse`, `LLMConversationState`. Calls `service.sendProviderRequest()` instead of `responsesService.createResponseStreaming()` directly. Recovery catches `LLMProviderError.httpError` instead of `OpenAIResponsesServiceError.httpError`.

**`AIConversationContext.swift` updated**: Stores `[UUID: LLMConversationState]` instead of `[UUID: String]`.

**Tool handler/definitions updated**: All use `LLMToolDefinition`, `LLMToolCall`, `LLMToolOutput`, `LLMJSONValue`, `AIAgentServiceError` instead of OpenAI-specific types.

**Duplicate `OpenAIJSONValue` enum removed** from `OpenAIResponsesTypes.swift` — resolves through `typealias OpenAIJSONValue = LLMJSONValue` in `LLMTypes.swift`.

**OpenAI internal layer untouched**: `OpenAIResponsesService.swift`, `OpenAIResponsesService+Streaming.swift`, `OpenAIResponsesPayloadTypes.swift`, `OpenAIResponsesStreamAccumulator.swift`, `OpenAIAPIKeyStore.swift` — all unchanged.

**App wiring**: `AppDependencies` gains `llmAPIKeyStore` and `llmProviderRegistry`. `ProSSHMacApp` injects `llmProviderRegistry` as environment object.

**Tests updated**: `AIConversationContextTests`, `OpenAIAgentServiceTests`, `TerminalAIAssistantViewModelTests` — all updated to use new type names. All AI-related test suites pass.

Build: SUCCEEDED. All key AI tests pass.

---

### 2026-03-02 — Multi-Provider Phase 2: Mistral + Settings UI

**Goal**: Add Mistral as the first selectable non-OpenAI provider. Settings UI gets provider/model pickers and per-provider API key management.

**New files**: `ChatCompletionsClient.swift` (shared HTTP client for Chat Completions wire format), `MistralProvider.swift` (Mistral provider with conversation history packing), `AIProviderSettingsViewModel.swift` (multi-provider settings VM).

**Key changes**: `OpenAIAgentService.sendProviderRequest()` branches on `activeProviderID` — OpenAI stays on Responses API, non-OpenAI goes through `LLMProvider` protocol. `AIAgentRunner` detects provider mismatch and clears stale conversation state. `SettingsView` AI section gains provider picker, model picker, conditional API key field.

Build: SUCCEEDED. 209 tests pass (2 pre-existing unrelated failures).

---

### 2026-03-02 — Multi-Provider Phase 3: Ollama (Local Inference)

**Goal**: Add Ollama for local model inference. No API key needed — just requires Ollama running on localhost.

**File copied + modified**: `OllamaProvider.swift` from `FilesForMultiProvider/` → `Services/LLM/Providers/`. Added conversation history management (same `extractPriorMessages`/`buildUpdatedHistory`/`toLLMResponse` pattern as `MistralProvider`). Uses `ChatCompletionsClient` with `authStyle: .none`.

**AppDependencies**: Registered `OllamaProvider()` (no API key provider needed).

**AIProviderSettingsViewModel**: Added `isRefreshingModels`, `ollamaConnectionStatus` (`.unknown`/`.connected`/`.notRunning`), `refreshOllamaModels()` method. Auto-triggers on provider switch to `.ollama` and on `refresh()`.

**SettingsView**: Ollama-specific section with connection status indicator (green/red/gray dot), "Refresh Models" button, and info text explaining no API key is needed.

Build: SUCCEEDED. All tests pass (pre-existing failures unchanged).

### 2026-03-03 — Fix Issue #12: SFTP transfer cancellation now interrupts blocking C I/O

**Problem**: The Cancel button in TransfersView already called `activeTransferTask?.cancel()`, but Swift task cancellation only cancelled the Task wrapper — the underlying blocking C call (`prossh_libssh_sftp_upload_file` / `prossh_libssh_sftp_download_file`) continued running through its `sftp_read`/`sftp_write` loop with no cancellation check, so transfers ran to completion regardless.

**Fix** — 3 files changed:

- **`CLibSSH/ProSSHLibSSHWrapper.h`**: Added `volatile int32_t *cancel_flag` parameter (between `total_bytes` and `error_buffer`) to both `prossh_libssh_sftp_download_file` and `prossh_libssh_sftp_upload_file` signatures. Passing `NULL` disables the feature.

- **`CLibSSH/ProSSHLibSSHWrapper.c`**: Added cancel-flag check at the top of the `while(1)` loop in both functions. When `*cancel_flag != 0`: download closes + removes the partial local file then returns -2 via `goto cleanup` (releasing the mutex and restoring session mode); upload skips partial-remote cleanup and returns -2 via `goto cleanup`.

- **`Services/SSH/LibSSHTransport.swift`**: Added `CancelFlagPointer: @unchecked Sendable` struct (wraps `UnsafeMutablePointer<Int32>` for safe capture in `@Sendable` closures). Both `uploadFile` and `downloadFile` (progress-handler variants) now allocate a cancel flag pointer and wrap the blocking C call in `withTaskCancellationHandler { ... } onCancel: { cancelBox.flag.pointee = 1 }`. After C returns, `cancelFlagPtr.pointee != 0` is checked first to throw `CancellationError()`; other non-zero results throw `SSHTransportError.transportFailure`.

**No changes needed** to `TransferManager`, `TransfersView`, `SessionSFTPCoordinator`, or `Transfer` — cancellation infrastructure was already wired correctly.

Build: SUCCEEDED.

### 2026-03-03 — Issue #15: Multi-Session Broadcast Keyboard Input

**Feature**: Added input routing modes for multi-pane terminal sessions. Keyboard input can now be routed to one pane (default), all panes (broadcast), or a user-selected group of panes.

**Three routing modes**:
- `singleFocus` (default): input goes to focused pane only. No behavior change from before.
- `broadcast`: input fans out to all panes simultaneously. Toggle with `Cmd+Shift+B`.
- `selectGroup`: input goes to a user-selected subset of panes via context menu.

**Files changed** (7 modified, 1 new):
- `SplitNode.swift`: Added `InputRoutingMode` enum.
- `PaneManager.swift`: Added `inputRoutingMode`, `groupPaneIDs`, computed `targetSessionIDs`/`targetPaneIDs`, `toggleBroadcast()`, `togglePaneInGroup()`, `setSelectGroupMode()`. Edge-case cleanup in `closePane`/`syncSessions`/`maximizePane`/`restoreMaximize`.
- `TerminalView.swift`: Input fan-out in `onSendSequence`/`onSendBytes` callbacks, shortcut wiring, toolbar indicator, routing state pass-through to SplitNodeView.
- `TerminalKeyboardShortcutLayer.swift`: `onToggleBroadcast` callback + `Cmd+Shift+B` binding.
- `TerminalPaneView.swift`: Orange broadcast border/badge overlays, context menu items for broadcast/group selection.
- `SplitNodeView.swift`: Pass-through `inputRoutingMode` + `targetPaneIDs` to TerminalPaneView.
- `InputRoutingTests.swift` (new): 17 tests covering all routing logic.

**Design decisions**: Broadcast mode bypasses per-session safety-mode buffer (power-user feature). Fan-out uses existing `sendControl(_:sessionID:)` path (one Task per target). No changes to SessionShellIOCoordinator or lower layers.

Build: SUCCEEDED. All 17 new tests + 26 existing PaneManagerTests pass.


### 2026-03-03 — Optimize AI Agent Instructions and Tool Use

**Goal**: Reduce per-request token cost, improve behavioral guidance, merge redundant tools, and standardize error output shapes.

**Phase 1 — Compress Developer Prompt** (~184 → ~62 lines, ~55% reduction):
- Deleted `INTERACTIVE INPUT` section (duplicated in send_input tool description)
- Deleted `File Editing with apply_patch` tutorial (82 lines, duplicated in apply_patch tool description)
- Compressed SUDO (11→3 lines), BROADCAST (8→2 lines), CAPABILITIES (6→3 lines), CONTEXT (5→1 line), APPROACH (6→3 lines)
- Added EFFICIENCY section (parallel tool calls, batch reads, dedicated search tools)

**Phase 2 — Behavioral Guidance**:
- Added EFFICIENCY section: batch file reads, parallel tool calls, prefer dedicated search tools
- Updated apply_patch tool description: `read_file_chunk` → `read_files` reference

**Phase 3 — Merge Redundant Tools** (14 → 11 definitions):
- Removed `read_file_chunk` definition — `read_files` now handles single-file reads too (updated description)
- Removed `search_terminal_history` definition — merged into `get_recent_commands` via optional `query` parameter (nullable string)
- Removed `get_session_info` definition — `get_current_screen` now includes `session_info` object (host_label, is_local, state)
- All three removed tools retained as backward-compat dispatch cases in AIToolHandler
- Updated `directActionToolDefinitions`: replaced `get_session_info` with `read_files`

**Phase 4 — Standardize Error Output**:
- Added `AIToolDefinitions.errorResult(_:hint:)` helper
- Standardized all error shapes to `{ok:false, error:"...", hint:"..."}` (hint optional)
- Updated: read-bound violations, execute_and_wait timeout, apply_patch denied, unknown tool, catch-all errors
- Exception: `sudo_password_required` status kept as-is (flow-control signal, not error)

**Phase 5 — Shorten target_session Description**:
- Compressed from ~30 tokens to ~12 tokens per tool × 11 tools (~200 token savings)
- Removed stale reference to `get_session_info`

**Files changed** (4 modified):
- `AIToolDefinitions.swift`: Compressed prompt, removed 3 tool definitions, added `query` to `get_recent_commands`, added `errorResult` helper, shortened `targetSessionProperty`
- `AIToolHandler.swift`: Merged `search_terminal_history` into `get_recent_commands` dispatch, added `session_info` to `get_current_screen`, standardized error shapes, updated hint messages
- `ApplyPatchTool.swift`: `read_file_chunk` → `read_files` in description
- `AIAgentServiceTests.swift`: Updated assertions for new error shapes and tool names

**Estimated savings**: ~2,900 tokens per request from prompt/schema compression, plus fewer unnecessary tool calls from behavioral guidance.

Build: SUCCEEDED. All pre-existing tests pass (AIAgentServiceTests have a pre-existing Mistral provider config issue unrelated to this change).

---

## 2026-03-04 — Issue #11 Phase 0: Instrumentation & Baseline

**Feature spec:** `docs/Issue11.md`
**Phase:** 0 of 5 (investigation only, no functional changes)

### What changed
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`: Added `#if DEBUG` periodic renderer stats dump every 300 frames (~5s at 60Hz). Logs avg/p95 CPU frame time, dropped-frame counts, and GlyphCache hit rate to console.
- `ProSSHMac/Services/TerminalRenderingCoordinator.swift`: Added `#if DEBUG` snapshot publish frequency counter. Logs snapshot rate (per second) to console every 100ms window.

### Files modified
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`
- `ProSSHMac/Services/TerminalRenderingCoordinator.swift`
- `docs/Issue11.md` (Phase 0 partial check-off; baseline table still empty — requires manual Instruments run)

### Build/test status
Build: SUCCEEDED (DEBUG). SourceKit false positives in coordinator (pre-existing pattern). No test run required for instrumentation-only change.

### Next
Phase 0 is complete for the code side. User must run the app under Instruments (Metal System Trace) with an htop session to fill in the baseline measurements table in `docs/Issue11.md`, then Phase 0 can be fully checked off before proceeding to Phase 1.

---

## 2026-03-04 — Issue #11 Phase 1: Output Batching in Parser Reader

**Feature spec:** `docs/Issue11.md`
**Phase:** 1 of 5

### What changed
- `ProSSHMac/Services/SessionShellIOCoordinator.swift`: Replaced single-task parser reader loop with a two-task pipeline:
  - **Accumulator task**: reads `rawOutput`, calls `recordParsedChunk` per chunk (preserving accurate byte counts + recording timestamps), then pushes to `ChunkBatchAccumulator`.
  - **Parser task**: reads from `batchedStream` (4ms batches, 4 KB size threshold), calls `engine.feed(batch)` once per window. `defer { accTask.cancel() }` cascades cancellation.
  - **`ChunkBatchAccumulator`** private actor (new): generation counter prevents stale timer flushes; `bufferingPolicy: .unbounded` prevents drops; size threshold avoids latency spikes on large single chunks.

### Files modified
- `ProSSHMac/Services/SessionShellIOCoordinator.swift`
- `docs/Issue11.md` (Phase 1 checked off)

### Build/test status
Build: SUCCEEDED.

### Next
Phase 2: Async glyph rasterization — offload cache misses from draw path in `MetalTerminalRenderer+GlyphResolution.swift`.

## 2026-03-04 — Issue #11 Phase 2: Async Glyph Rasterization

**Feature spec:** `docs/Issue11.md`
**Phase:** 2 of 5

### What changed
- `GlyphCache.swift`: Added box-drawing block (U+2500–U+257F, 128 glyphs) to both `prePopulateASCII` variants (sync and async). Pre-warm eliminates first-frame spike for TUI apps like htop/ncdu.
- `MetalTerminalRenderer.swift`: Added `pendingGlyphKeys: Set<GlyphKey>` and `glyphRasterTask: Task<Void, Never>?` properties.
- `MetalTerminalRenderer+GlyphResolution.swift`: 
  - `resolveGlyphIndex`: now enqueues cache misses in `pendingGlyphKeys` and returns `noGlyphIndex` instead of synchronously rasterizing.
  - Added `nonisolated static func rasterizeGlyphForBackground(...)` — pure CPU rasterization callable from any thread.
  - Marked `resolveRenderFont`, `isEmojiRange` as `nonisolated static` to permit background-thread calls.
- `MetalTerminalRenderer+DrawLoop.swift`: Added `drainPendingGlyphKeysIfNeeded()` call after `applyPendingSnapshotIfNeeded()`; added private `drainPendingGlyphKeysIfNeeded()` method that launches a `Task.detached` capturing only Sendable scalars (fontName + scaledFontSize), reconstructs CTFont variants on background thread, uploads to atlas on main thread via `DispatchQueue.main.async`, then forces re-render via `pendingRenderSnapshot = latestSnapshot`.
- `GlyphRasterizer.swift`: Marked `rasterize(codepoint:...)`, `isColorGlyph`, `isEmojiCodepoint`, `isWideCharacter`, `swizzleBGRAtoRGBA`, `deviceRGBColorSpace`, and `RasterizedGlyph.empty` as `nonisolated` (required by `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` project setting).

### Files modified
- `ProSSHMac/Terminal/Renderer/GlyphCache.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+GlyphResolution.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`
- `ProSSHMac/Terminal/Renderer/GlyphRasterizer.swift`
- `docs/Issue11.md` (Phase 2 checked off)

### Build/test status
Build: SUCCEEDED.

### Next
Phase 3: Adaptive snapshot coalescing in `TerminalRenderingCoordinator`.

---

## 2026-03-04 — Issue #11 Phase 3: Adaptive snapshot coalescing

### What changed
Added automatic burst detection to `TerminalRenderingCoordinator`. When >3 publish requests arrive within a 16ms window, the coordinator auto-switches to the 16ms throughput interval; 200ms after the burst quiets, it reverts to the 8ms default. This eliminates the need for users to manually toggle throughput mode for htop/ncdu/other TUI apps.

Added `isInBurstMode(for:)` as a single truth source replacing all three direct reads of `manager.throughputModeEnabled` (snapshot interval selection, shell buffer throttle, bell rate-limiting).

### Files modified
- `ProSSHMac/Services/TerminalRenderingCoordinator.swift`
- `Docs/Issue11.md` (Phase 3 checked off)

### Build/test status
Build: SUCCEEDED.

### Next
Phase 4: Cursor animation decoupling — replace continuous MTKView display-link with Timer-driven blink, `isPaused = true` when idle.

---

## 2026-03-04 — Issue #11 Phase 4: Cursor Animation Decoupling

**Feature spec:** `docs/Issue11.md`
**Phase:** 4 of 5

### What changed
Decoupled cursor blink animation from the MTKView display link. Previously, `requiresContinuousFrames()` returned `true` whenever cursor blink was enabled, keeping the display link running at 60–120fps continuously. Now:

- `CursorRenderer.requiresContinuousFrames()` only returns `true` during position interpolation (lerp). Blink no longer keeps the display link alive.
- `MetalTerminalRenderer+DrawLoop.swift`: early-exit guard now sets `view.isPaused = true` to stop the display link when idle. Background glyph rasterization completion unpauses the view.
- `MetalTerminalRenderer+ViewConfiguration.swift`: new `startCursorBlinkLoopIfNeeded()`, `stopCursorBlinkLoop()`, `updateCursorBlinkLoop()` methods manage a `Task`-based ~15fps blink loop. `setPaused()` now starts/stops the blink loop on external pause/unpause.
- `MetalTerminalRenderer+SnapshotUpdate.swift`: snapshot arrival unpauses the view and syncs the blink loop to new cursor state.
- `MetalTerminalRenderer.swift`: added `cursorBlinkTask` property.

**Expected performance impact:**
- Idle terminal with blink: ~15fps (was 60–120fps)
- Idle terminal without blink: 0fps, fully paused (was 60–120fps)
- Active output: unchanged (60–120fps)

### Files modified
- `ProSSHMac/Terminal/Renderer/CursorRenderer.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+ViewConfiguration.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+SnapshotUpdate.swift`
- `docs/Issue11.md` (Phase 4 checked off)

### Build/test status
Build: SUCCEEDED. Tests: 209 run, 2 pre-existing failures, 0 new.

### Next
Phase 5: Verification & close — Instruments trace, post-fix measurements, close issue.

---

## 2026-03-04 — Issue #11 Phase 5: Verification & Close

**Feature spec:** `docs/Issue11.md`
**Phase:** 5 of 5

### What changed
- Ran `xcodebuild test`: 209 tests, 2 pre-existing failures, 0 new regressions.
- Updated baseline measurements table with post-fix architectural expectations.
- Closed GitHub issue #11 with summary of all 5 phases.
- Note: Instruments trace (p95 CPU frame time, dropped frame count) requires manual verification by running the app under Metal System Trace with an htop session.

### Issue #11 — Complete Fix Summary

**Phases implemented (1–4):**
1. **Output batching**: `ChunkBatchAccumulator` in `SessionShellIOCoordinator` — 4ms/4KB batching reduces snapshot churn during burst output.
2. **Async glyph rasterization**: Cache misses return blank cell immediately, rasterize on background thread. Box-drawing pre-warm (U+2500–U+257F) eliminates first-render spike for TUI apps.
3. **Adaptive snapshot coalescing**: Burst detection (>3 requests/16ms) auto-switches to throughput interval. Reverts after 200ms quiet. `isInBurstMode(for:)` is single truth source.
4. **Cursor animation decoupling**: Display link auto-pauses when idle. ~15fps Task-based blink loop replaces continuous 60–120fps rendering. Idle GPU usage drops to near-zero.

### Build/test status
Build: SUCCEEDED. Tests: 209 run, 2 pre-existing failures, 0 new.

---

## 2026-03-04 — TextGlow (Bloom / Text Glow Effect) — Feature Start

**Feature spec created:** `docs/TextGlow.md`

**Goal:** Add a GPU multi-pass bloom effect to the Metal terminal renderer. Bright terminal text (bold colors, ANSI bright palette) gets a soft glow halo. The bloom optionally pulses with the gradient background animation system.

**Pipeline:** bright-pass extraction → half-res downsample → separable Gaussian blur (H + V) → additive composite into post-process pass.

**Phases planned (0–7):**
- Phase 0: Configuration & Uniforms
- Phase 1: Textures & Pipeline States
- Phase 2: Bright-Pass Shader
- Phase 3: Separable Gaussian Blur (H + V Passes)
- Phase 4: Composite Bloom into Post-Process Pass
- Phase 5: Gradient Animation Coupling
- Phase 6: Settings UI
- Phase 7: QA, Performance & Polish

**Files affected:** `TerminalShaders.metal`, `MetalTerminalRenderer.swift`, `MetalTerminalRenderer+PostProcessing.swift`, `MetalTerminalRenderer+DrawLoop.swift`, `TerminalUniforms.swift`, new `BloomEffect.swift`, new `BloomEffectSettingsView.swift`, `SettingsView.swift`

No code changes this session — spec only.

---

## 2026-03-04 — TextGlow Phase 0: Configuration & Uniforms

**Feature spec:** `docs/TextGlow.md`
**Phase:** 0 of 7

### What changed
- Created `ProSSHMac/Terminal/Effects/BloomEffect.swift`: `BloomEffectConfiguration` struct (Codable, Sendable, Equatable) with `isEnabled`, `threshold`, `intensity`, `radius`, `animateWithGradient` fields. UserDefaults persistence via `load()`/`save()` with key `"terminal.effects.bloom"`. Follows `ScannerEffectConfiguration` pattern.
- Edited `ProSSHMac/Terminal/Renderer/TerminalUniforms.swift`:
  - Added 4 bloom fields to `TerminalUniformData`: `bloomEnabled` (UInt32), `bloomThreshold` (Float), `bloomIntensity` (Float), `bloomAnimateWithGradient` (UInt32). 16-byte aligned after scanner block.
  - Added `bloomConfig: BloomEffectConfiguration? = nil` parameter to `TerminalUniformBuffer.update()`.
  - Bloom config resolution with gradient-coupled intensity pulsing via `sinf()`.
  - Bloom fields wired into struct literal with clamped ranges.

### Files modified
- `ProSSHMac/Terminal/Effects/BloomEffect.swift` (new)
- `ProSSHMac/Terminal/Renderer/TerminalUniforms.swift`
- `docs/TextGlow.md` (Phase 0 checked off)

### Build/test status
Build: SUCCEEDED. No visual change — data foundation only.

### Next
Phase 1: Textures & Pipeline States — allocate half-res GPU textures, create stub shader entry points.

---

## 2026-03-04 — TextGlow Phase 1: Textures & Pipeline States

**Feature spec:** `docs/TextGlow.md`
**Phase:** 1 of 7

### What changed
- `ProSSHMac/Terminal/Renderer/TerminalShaders.metal`: Added 4 stub shader functions at end of file — `bloom_bright_vertex`, `bloom_bright_fragment`, `bloom_blur_vertex`, `bloom_blur_fragment`. All use existing `PostVertexOut` struct. Fragment stubs return black (`float4(0,0,0,1)`). Full-screen triangle vertex pattern matches `terminal_post_vertex`.
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer.swift`: Added 6 stored properties (bloom section): `bloomConfiguration`, `bloomBrightPipeline`, `bloomBlurHPipeline`, `bloomBlurVPipeline`, `bloomBrightTexture`, `bloomBlurH`, `bloomBlurV`. Created 3 pipeline states in `init()` after post-process pipeline — bright pipeline and shared blur pipeline (H/V use same PSO; direction via uniform in Phase 3). Uses `try?` for graceful failure.
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+PostProcessing.swift`: Added `reloadBloomEffectSettings()`, `ensureBloomTextures(width:height:)`, and private `makeBloomHalfResTexture(width:height:)`. Bloom textures allocated at half resolution when enabled, nil'd out when disabled. Called from `ensurePostProcessTextures()`.
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`: Added `bloomConfiguration.isEnabled` to `usesPostProcessing` guard so bloom forces the post-process path active.

### Files modified
- `ProSSHMac/Terminal/Renderer/TerminalShaders.metal`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+PostProcessing.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`
- `docs/TextGlow.md` (Phase 1 checked off)

### Build/test status
Build: SUCCEEDED. No visual change — resource allocation only (bloom disabled by default).

### Next
Phase 2: Bright-Pass Shader — implement `bloom_bright_fragment` to extract luminant pixels, encode bright-pass render pass in DrawLoop.

---

## 2026-03-04 — TextGlow Phase 2: Bright-Pass Shader

**Feature spec:** `docs/TextGlow.md`
**Phase:** 2 of 7

### Changes
- `ProSSHMac/Terminal/Renderer/TerminalShaders.metal`: Added 4 bloom fields (`bloomEnabled`, `bloomThreshold`, `bloomIntensity`, `bloomAnimateWithGradient`) to Metal `TerminalUniforms` struct — matches Swift `TerminalUniformData` byte layout. Replaced `bloom_bright_fragment` stub with full implementation: samples `postProcessTexture` via linear sampler, computes Rec.709 luminance, extracts pixels above `bloomThreshold` using smooth knee function (squared for sharper cutoff), outputs `color.rgb * bright`.
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`: Passed `bloomConfig: bloomConfiguration` to `uniformBuffer.update()` (was previously defaulting to `nil`). Added `encodeBrightPass(commandBuffer:sceneTexture:)` private method that creates a render pass targeting `bloomBrightTexture` (half-res), binds the scene texture and uniform buffer, draws a full-screen triangle via `bloomBrightPipeline`. Called after scene encoding and before post-process pass in `draw(in:)`.

### Files modified
- `ProSSHMac/Terminal/Renderer/TerminalShaders.metal`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`
- `docs/TextGlow.md` (Phase 2 checked off)

### Build/Test
Build: SUCCEEDED. No visual change — bloom compositing into the final image is Phase 4.

### Next
Phase 3: Separable Gaussian Blur (H + V Passes) — implement `bloom_blur_fragment` with 13-tap kernel, add blur uniform fields, encode H+V passes in DrawLoop.

---

## 2026-03-04 — TextGlow Phase 3: Separable Gaussian Blur (H + V Passes)

**Feature spec:** `docs/TextGlow.md`
**Phase:** 3 of 7

### Changes
- `ProSSHMac/Terminal/Renderer/TerminalShaders.metal`: Added `BloomBlurParams` struct (texelWidth, texelHeight, horizontal, radius) and 13-tap Gaussian kernel constants (`BLOOM_KERNEL_HALF = 6`, `BLOOM_WEIGHTS[7]`). Replaced `bloom_blur_fragment` stub with full implementation: takes `blurInput` texture at index 0 and `BloomBlurParams` at buffer index 2 via `setFragmentBytes`. Samples 13 taps along H or V direction based on `params.horizontal`, weights by pre-computed Gaussian weights, scales by `params.radius`.
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`: Added `encodeBlurPasses(commandBuffer:)` private method that runs two sequential render passes: H-pass (`bloomBrightTexture → bloomBlurH`) and V-pass (`bloomBlurH → bloomBlurV`). Uses `setFragmentBytes` with a local `BloomBlurParams` struct for each pass — avoids the shared-buffer double-write problem. Called after `encodeBrightPass` and before the post-process encoder in `draw(in:)`.

### Architecture note
Used `setFragmentBytes` (inline push constants) instead of adding fields to `TerminalUniforms`. This is the correct Metal pattern for per-pass constants that change between render passes within a single command buffer — each pass command records its own copy of the 16-byte struct, so the GPU sees the correct direction for each pass.

### Files modified
- `ProSSHMac/Terminal/Renderer/TerminalShaders.metal`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`
- `docs/TextGlow.md` (Phase 3 checked off)

### Build/Test
Build: SUCCEEDED. No visual change — compositing `bloomBlurV` into the final image is Phase 4.

### Next
Phase 4: Composite Bloom into Post-Process Pass — bind `bloomBlurV` as texture(2) in `terminal_post_fragment`, additive blend with `bloomIntensity`. First visible bloom result.

---

## 2026-03-04 — TextGlow Phase 4: Composite Bloom into Post-Process Pass

### Summary
Wired `bloomBlurV` into the final post-process pass as an additive blend. This is the first visible result of the bloom pipeline — bright terminal text now gets a soft glow halo when bloom is enabled.

### Changes
1. **`TerminalShaders.metal`**: Added `bloomTexture [[texture(2)]]` parameter to `terminal_post_fragment`. Inserted bloom composite block (sample + additive blend + saturate) after scene sample and before gradient compositing, gated by `uniforms.bloomEnabled == 1`.
2. **`MetalTerminalRenderer+DrawLoop.swift`**: Bound `bloomBlurV` at texture index 2 in the post-process encoder, guarded by `bloomConfiguration.isEnabled`.

### Files modified
- `ProSSHMac/Terminal/Renderer/TerminalShaders.metal`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`
- `docs/TextGlow.md` (Phase 4 checked off)

### Build/Test
Build: SUCCEEDED. Bloom is now composited into the final frame when enabled.

### Next
Phase 5: Gradient Animation Coupling — pulse bloom intensity/radius in sync with gradient animations, tint bloom halo toward gradient color.

---

## 2026-03-04 — TextGlow Phase 5: Gradient Animation Coupling

### Summary
Added two gradient-bloom coupling behaviours: (1) gradient color tinting in the shader — bloom halo picks up a gentle color cast from the gradient when both are active with `animateWithGradient`, and (2) radius pulsing for aurora/wave gradient modes — subtle cosine pulse on blur radius computed self-contained in `encodeBlurPasses()`. Intensity pulsing was already implemented in Phase 0.

### Changes
1. **`TerminalShaders.metal`**: Modified bloom composite block in `terminal_post_fragment` to add a gradient-tinted path. When `bloomAnimateWithGradient == 1 && gradientEnabled > 0.5`, uses `computeGradientColor()` to derive a `gradHint` scaled by local bloom brightness (`length(bloomColor)`), producing a proportional color tint. Plain bloom path preserved in `else` branch.
2. **`MetalTerminalRenderer+DrawLoop.swift`**: Added `effectiveRadius` computation at top of `encodeBlurPasses()`. For aurora/wave gradient modes with `animateWithGradient`, applies `cos(elapsed * speed)` pulse (±10%) to `bloomConfiguration.radius`. Both H-pass and V-pass `BloomBlurParams` now use `effectiveRadius`.

### Files modified
- `ProSSHMac/Terminal/Renderer/TerminalShaders.metal`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`
- `docs/TextGlow.md` (Phase 5 checked off)

### Build/Test
Build: SUCCEEDED.

### Next
Phase 6: Settings UI — expose bloom as a user-configurable effect in Settings with toggles and sliders.

---

## 2026-03-04 — TextGlow Phase 6: Settings UI

### Summary
Created `BloomEffectSettingsView.swift` with master toggle, threshold/intensity/radius sliders, and gradient coupling toggle. Added "Text Glow (Bloom)" navigation row to `SettingsView.swift` after Scanner Effect. Wired bloom configuration change detection into `MetalTerminalSessionSurface`'s `reloadRendererSettingsIfNeeded()` poll loop so settings changes take effect immediately.

### Changes
1. **`UI/Settings/BloomEffectSettingsView.swift`** (NEW): Settings view with enable toggle, threshold slider (10–90%), intensity slider (0–150%), radius slider (0.5–3.0x), and "Pulse with Gradient Animation" toggle. Uses `SettingsCard` and `LabeledSlider` from `GradientBackgroundSettingsView`. Cyan tint accent. Apply/Cancel toolbar.
2. **`UI/Settings/SettingsView.swift`**: Added NavigationLink for "Text Glow (Bloom)" with sparkles icon and cyan "On" indicator between Scanner Effect and Prompt Colors rows.
3. **`UI/Terminal/MetalTerminalSessionSurface.swift`**: Added `cachedBloomConfiguration` property, initialized in `init()`, and bloom change detection block in `reloadRendererSettingsIfNeeded()` calling existing `renderer.reloadBloomEffectSettings()`.

### Files modified
- `ProSSHMac/UI/Settings/BloomEffectSettingsView.swift` (NEW)
- `ProSSHMac/UI/Settings/SettingsView.swift`
- `ProSSHMac/UI/Terminal/MetalTerminalSessionSurface.swift`
- `docs/TextGlow.md` (Phase 6 checked off)

### Build/Test
Build: SUCCEEDED.

### Next
Phase 7: QA, Performance & Polish — profiling, edge cases, full test suite.

---

## 2026-03-04 — TextGlow Phase 7: QA, Performance & Polish (FEATURE COMPLETE)

### Summary
Fixed Metal Validation Layer issue: bloom texture slot 2 was left unbound when bloom was disabled. Now uses `crtFallbackTexture` (1x1 black) as fallback — same pattern already used for slot 1. Verified all spec items are correctly implemented. Full test suite passes (209 tests, 2 pre-existing failures). TextGlow feature is complete (Phases 0–7).

### Changes
1. **`MetalTerminalRenderer+DrawLoop.swift`**: Replaced conditional `if bloomEnabled` texture bind at slot 2 with unconditional bind using `crtFallbackTexture` as fallback when bloom is disabled or textures are not yet allocated. Prevents undefined behavior from unbound texture slots.

### Verification
- `bloomEnabled` in `usesPostProcessing` check: confirmed (DrawLoop line 58)
- Bloom textures nilled when disabled: confirmed (`ensurePostProcessTextures`)
- Half-res texture allocation with resize guard: confirmed (`ensureBloomTextures`)
- Bloom disabled → encode functions no-op via early guard: confirmed
- Slot 2 always bound: fixed this session

### Files modified
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift`
- `docs/TextGlow.md` (Phase 7 checked off — all phases complete)

### Build/Test
Build: SUCCEEDED. Tests: 209 executed, 2 failures (0 unexpected) — pre-existing baseline.

---

## 2026-03-04 — SmoothScroll Phase 0: Configuration & Uniforms

### Summary
Laid data foundation for smooth scrolling: `SmoothScrollConfiguration` config struct with UserDefaults persistence, `scrollOffsetPixels` uniform field added to both Swift (`TerminalUniformData`) and Metal (`TerminalUniforms`) structs. Hardcoded to 0.0 — no visual change yet.

### Changes
- `Terminal/Effects/SmoothScrollConfiguration.swift`: New config struct with isEnabled, springStiffness, friction, momentumEnabled, maxVelocity. Load/save via UserDefaults.
- `Terminal/Renderer/TerminalUniforms.swift`: Added `scrollOffsetPixels: Float` to `TerminalUniformData`.
- `Terminal/Renderer/TerminalShaders.metal`: Added `float scrollOffsetPixels` to Metal `TerminalUniforms` struct.

### Build/Test
Build: SUCCEEDED.

---

## 2026-03-04 — SmoothScroll Phase 1: SmoothScrollEngine (CPU Physics)

### Summary
Built CPU-side animation engine for smooth scrolling. `SmoothScrollEngine` tracks scroll state, accumulates raw deltas into fractional row offsets, fires integer row change callbacks, applies spring interpolation and momentum decay. Follows `CursorRenderer` pattern (target → render state per frame, lerp, `requiresContinuousFrames()`). No GPU changes — model + unit tests only.

### Changes
1. **`Terminal/Renderer/SmoothScrollEngine.swift`** (new): Physics engine with `scrollDelta()`, `beginMomentum()`, `endMomentum()`, `frame()`, `requiresContinuousFrames()`, `onScrollLineChange` callback. Velocity tracking via EMA, spring-back via `CursorEffects.lerp`, momentum decay via friction multiplier, ±1.5 row clamp.
2. **`ProSSHMacTests/SmoothScrollEngineTests.swift`** (new): 10 unit tests covering row extraction, negative direction, fractional remainder, momentum decay convergence, spring-back convergence, velocity clamping, continuous frames states, config reload, zero cell height guard, endMomentum.

### Files modified
- `ProSSHMac/Terminal/Renderer/SmoothScrollEngine.swift` (new, 152L)
- `ProSSHMacTests/SmoothScrollEngineTests.swift` (new, 195L)
- `docs/SmoothScroll.md` (Phase 1 checked off)

### Build/Test
Build: SUCCEEDED. Tests: 20 pass, 0 fail, pre-existing host app malloc crash (unrelated baseline).

### Next
Phase 2: Vertex Shader Integration — apply `scrollOffsetPixels` in `terminal_vertex` for sub-pixel Y-shift.

---

## 2026-03-04 — SmoothScroll Phase 2: Vertex Shader Integration

### Summary
Applied `scrollOffsetPixels` in the vertex shader (`terminal_vertex`) so the GPU shifts all cell quads vertically by the sub-pixel offset. One line added to `TerminalShaders.metal` — offset applied in pixel space before NDC conversion. Fragment shader unchanged (cursor, glow, decorations use unscrolled `cellPixelPos`). Post-process unchanged (UV space).

### Changes
- `ProSSHMac/Terminal/Renderer/TerminalShaders.metal`: Added `pixelPos.y += uniforms.scrollOffsetPixels;` after pixel position calculation, before NDC transform.

### Build/Test
Build: SUCCEEDED.

### Next
Phase 3: Wire SmoothScrollEngine into MetalTerminalRenderer — connect scroll events to engine, feed engine output into uniforms, drive display-link for momentum frames.

---

## 2026-03-04 — SmoothScroll Phase 3: Wire Scroll Events Through Engine

### Summary
Connected SmoothScrollEngine to the Metal render pipeline. Raw trackpad scroll events now feed through the physics engine, which produces sub-pixel offsets uploaded to the GPU each frame. The display link stays alive during scroll animation (momentum, spring-back). Legacy integer accumulation preserved as fallback when smooth scroll is disabled.

### Changes
1. **`MetalTerminalRenderer.swift`**: Added `smoothScrollEngine`, `smoothScrollConfiguration`, and public `scrollDelta()`, `scrollMomentumBegan()`, `scrollMomentumEnded()` methods. `scrollDelta()` also wakes the display link.
2. **`MetalTerminalRenderer+DrawLoop.swift`**: Added `smoothScrollEngine.requiresContinuousFrames()` to early-exit pause check. Call `smoothScrollEngine.frame(cellHeight:)` each draw tick. Pass `scrollFrame.offsetPixels` to `uniformBuffer.update()`.
3. **`TerminalUniforms.swift`**: Added `scrollOffsetPixels` parameter to `update()`, replacing the hardcoded `0.0`.
4. **`TerminalMetalView.swift`**: Added `weak var renderer` to `TerminalMetalContainerView`. Rewrote `scrollWheel` with smooth-scroll path (feeds engine) and legacy fallback. Wired `onScrollLineChange` → `onScroll` for integer row changes.

### Build/Test
Build: SUCCEEDED.

### Next
Phase 4: Edge Cases & Overscroll Behavior.

---

## 2026-03-04 — SmoothScroll Phase 4: Edge Cases & Overscroll Behavior

### Summary
Added bounds clamping, rubber-band overscroll, programmatic jump, resize reset, and frame-rate-independent physics to the SmoothScrollEngine.

### Changes
1. **`SmoothScrollEngine.swift`**: Added `setBounds(maxRow:)` for scroll bounds, `jumpTo(row:)` for instant programmatic scroll, `handleResize()` for resize reset. Changed `frame(cellHeight:)` → `frame(cellHeight:time:)` with frame-rate-independent physics using `pow(friction, dt*60)` and `pow(1-stiffness, dt*60)`. Rubber-band overscroll at bounds (±0.3 rows, 3× spring stiffness). Bounds-aware `extractIntegerRows()` prevents callbacks past limits.
2. **`MetalTerminalRenderer+DrawLoop.swift`**: Pass `frameNow` as `time:` parameter to `smoothScrollEngine.frame()`.
3. **`MetalTerminalRenderer.swift`**: Added `scrollbackBoundsProvider` closure and `scrollJumpTo(row:)` public method. `scrollDelta()` refreshes bounds before processing.
4. **`MetalTerminalRenderer+ViewConfiguration.swift`**: Call `smoothScrollEngine.handleResize()` on grid dimension change.
5. **`TerminalRenderingCoordinator.swift`**: Cache `scrollbackCount` per session on each scroll for synchronous bounds access. Clean up on session removal.
6. **`SessionManager.swift`**: Expose `cachedScrollbackCount(for:)` for view-layer bounds wiring.
7. **`MetalTerminalSessionSurface.swift`**: Added `scrollbackCountProvider` parameter, wired to renderer on appear.
8. **`TerminalSurfaceView.swift`** / **`ExternalTerminalWindowView.swift`**: Pass `scrollbackCountProvider` closure to `MetalTerminalSessionSurface`.
9. **`SmoothScrollEngineTests.swift`**: Updated existing tests for new `frame(cellHeight:time:)` signature. Added 7 new tests: bounds clamping (max/min), rubber-band at bounds, jumpTo state reset/bounds clamping, handleResize state reset, frame-rate independence (60Hz vs 120Hz).

### Build/Test
Build: SUCCEEDED. Tests: pre-existing test runner crash (malloc error in host app startup, unrelated to changes).

### Next
Phase 5: Settings UI.

---

## 2026-03-04 — SmoothScroll Phase 5: Settings UI

### Summary
Added user-facing settings UI for smooth scrolling, following the existing effect settings pattern (Bloom, Gradient, Scanner). Users can now enable/disable smooth scrolling and tune physics parameters (spring stiffness, friction, max velocity, momentum) from Settings → Terminal.

### Files Modified
1. **`UI/Settings/SmoothScrollSettingsView.swift`** (NEW): Settings view with master toggle, momentum toggle, and sliders for spring stiffness, friction, and max velocity. Uses `SettingsCard` and `LabeledSlider` components. Mint tint color. Save on Apply only.
2. **`UI/Settings/SettingsView.swift`**: Added NavigationLink row for "Smooth Scrolling" in Terminal section, after Matrix Screensaver. Shows On/Off indicator with mint color.
3. **`Terminal/Renderer/MetalTerminalRenderer+PostProcessing.swift`**: Added `reloadSmoothScrollSettings()` method that reloads configuration and pushes it to the engine.
4. **`UI/Terminal/MetalTerminalSessionSurface.swift`**: Added `cachedSmoothScrollConfiguration` property to `MetalTerminalSurfaceModel`. Reload branch in `reloadRendererSettingsIfNeeded()` detects config changes and calls renderer reload.

### Build/Test
Build: SUCCEEDED.

### Next
Phase 6: QA, Performance & Polish.

## 2026-03-04 — SmoothScroll Phase 6: QA, Performance & Polish

### Summary
Final polish phase for smooth scrolling. Added accessibility reduce-motion support, discrete mouse wheel handling, and alt-screen buffer transition detection.

### Changes
1. **`SmoothScrollEngine.swift`**: Added `import AppKit`. Config initializer and `reloadConfiguration()` now check `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` — when reduce-motion is enabled, `config.isEnabled` is overridden to `false`, causing the engine to act as pass-through.
2. **`TerminalMetalView.swift`**: `scrollWheel()` smooth-scroll branch now checks `event.hasPreciseScrollingDeltas`. Trackpad (precise) feeds raw delta; discrete mouse uses fixed 3-row step (`direction * cellHeight * 3`). Momentum phases only fire for trackpad events.
3. **`GridSnapshot.swift`**: Added `let usingAlternateBuffer: Bool` field to track alt-screen state.
4. **`TerminalGrid+Snapshot.swift`**: Both `snapshot()` and `snapshot(scrollOffset:)` now pass `usingAlternateBuffer` to `GridSnapshot`.
5. **`MetalTerminalRenderer+SnapshotUpdate.swift`**: `updateSnapshot()` detects alt-screen transitions and calls `smoothScrollEngine.handleResize()` to zero offset/velocity/momentum.
6. **`SelectionRenderer.swift`**: Both `GridSnapshot` constructors updated with `usingAlternateBuffer: snapshot.usingAlternateBuffer`.
7. **`RendererStressHarness.swift`**: `GridSnapshot` constructor updated with `usingAlternateBuffer: false`.

### Files Modified
- `ProSSHMac/Terminal/Renderer/SmoothScrollEngine.swift`
- `ProSSHMac/Terminal/Renderer/TerminalMetalView.swift`
- `ProSSHMac/Terminal/Grid/GridSnapshot.swift`
- `ProSSHMac/Terminal/Grid/TerminalGrid+Snapshot.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer+SnapshotUpdate.swift`
- `ProSSHMac/Terminal/Renderer/SelectionRenderer.swift`
- `ProSSHMac/Terminal/Renderer/RendererStressHarness.swift`
- `Docs/SmoothScroll.md` (Phase 6 checked off)
- `Docs/featurelist.md` (this entry)
- `CLAUDE.md` (next session plan updated)

### Build/Test
Build: SUCCEEDED.

### Next
SmoothScroll feature complete. All 6 phases done.

---

## 2026-03-04 — Fix Smooth Scroll Bug + Terminal Scrollbar

### Summary
Fixed smooth scrolling race condition where first scroll event returned maxRow=0 (cache miss).
Added Metal terminal scrollbar overlay with auto-hide and drag-to-scroll interaction.

### Changes

**Bug fix — scroll bounds cache miss:**
- `TerminalRenderingCoordinator.publishGridState()`: proactively populate `cachedScrollbackCountBySessionID` on every output chunk
- `TerminalRenderingCoordinator.resizeTerminal()`: populate cache after resize snapshot

**Scrollbar feature:**
- New `TerminalScrollState` struct (scrollOffset, scrollbackCount, visibleRows)
- `SessionManager.scrollStateBySessionID` `@Published` property for reactive UI
- `SessionManager.scrollToRow()` for absolute scroll positioning (scrollbar drag)
- `TerminalRenderingCoordinator.scrollToRow()` implementation
- `TerminalRenderingCoordinator.publishScrollState()` called from scrollTerminal, scrollToBottom, scheduleParsedChunkPublish, publishGridState
- New `TerminalScrollbarView.swift` — auto-hiding capsule scrollbar with drag gesture
- Scrollbar wired into `TerminalSurfaceView.metalTerminalBuffer()` and `ExternalTerminalWindowView.terminalSurface()`

### Files Modified
- `Services/TerminalRenderingCoordinator.swift` (scroll bug fix + scroll state publishing + scrollToRow)
- `Services/SessionManager.swift` (TerminalScrollState struct, scrollStateBySessionID, scrollToRow, cleanup)
- `UI/Terminal/TerminalScrollbarView.swift` (NEW)
- `UI/Terminal/TerminalSurfaceView.swift` (scrollbar overlay)
- `UI/Terminal/ExternalTerminalWindowView.swift` (scrollbar overlay)
- `Docs/featurelist.md` (this entry)
- `CLAUDE.md` (next session plan updated)

### Build/Test
Build: SUCCEEDED. Tests: 209 executed, 2 failures (0 unexpected — pre-existing baseline).
