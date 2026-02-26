# ProSSHMac AI + File Browser Expansion Checklist

Last verified against repo: 2026-02-25
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

## Loop Log

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
