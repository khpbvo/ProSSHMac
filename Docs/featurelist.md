# ProSSHMac AI + File Browser Expansion Checklist

Last verified against repo: 2026-02-23
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

## Loop Log

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
