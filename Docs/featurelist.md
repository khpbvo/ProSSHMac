# ProSSHMac AI + File Browser Expansion Checklist

Last verified against repo: 2026-02-22
Required assistant model for this work: `gpt-5.1-codex`

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
- AI uses Responses API with model pinned to `gpt-5.1-codex`.
- Command-block index supports reliable context retrieval for AI tools.
- Execution safety is enforced (explicit confirmation before AI command execution).
- Regression checks pass for existing pane splitting and Transfers behavior.
- This file and `AGENTS.md` remain current at task completion.

### Current Focus

- Active phase: Phase 1 (SFTP architecture decision + foundation).
- Immediate objective: decide and validate shared-session vs dedicated-SFTP strategy with tests.

## Loop Log

- 2026-02-22: Baseline feature checklist rewritten with phased plan and corrected claims.
- 2026-02-22: Working-memory loop established in `AGENTS.md`; long-term memory source pinned to this file.
- 2026-02-22: Fixed `TerminalView.swift` main-actor isolation warnings in `DirectTerminalInputNSView` observer/deinit paths; build re-verified.

## How to Use This File

- Use this as the source of truth for sequencing and progress.
- Check boxes as you complete work.
- Keep this file updated when scope or architecture decisions change.
- Do not start implementation until model is confirmed to `gpt-5.1-codex`.

## Reality Check (Claims Verified in Current Codebase)

### Confirmed true now

- [x] SFTP C functions already exist: `prossh_libssh_sftp_list_directory`, `prossh_libssh_sftp_download_file`, `prossh_libssh_sftp_upload_file` in `ProSSHMac/CLibSSH/ProSSHLibSSHWrapper.c` and `.h`.
- [x] Swift async wrappers for SFTP already exist in `ProSSHMac/Services/SSHTransport.swift` (`listDirectory`, `uploadFile`, `downloadFile`).
- [x] `SessionManager` already exposes SFTP methods (`listRemoteDirectory`, `uploadFile`, `downloadFile`) in `ProSSHMac/Services/SessionManager.swift`.
- [x] A remote browser already exists in the Transfers tab (`ProSSHMac/UI/Transfers/TransfersView.swift`) backed by `TransferManager`.
- [x] `TerminalView.swift` is currently ~106 KB (`106395` bytes) and already has complex pane logic.
- [x] `PaneManager` exists and drives terminal-to-terminal splits; this new sidebar work must not break pane behavior.
- [x] OSC sequences are parsed, and OSC command `133` is defined in parser constants.

### Not implemented yet (or previous doc was inaccurate)

- [ ] `TerminalView` does not yet have left/right sidebars for file browser + AI.
- [ ] OSC 133 semantic prompt handling is currently a placeholder in `ProSSHMac/Terminal/Parser/OSCHandler.swift`.
- [ ] There is no `TerminalHistoryIndex` or `CommandBlock` implementation yet.
- [ ] There is no AI agent service, tool executor, agent sidebar, or follow mode in the app yet.
- [ ] There is no `SessionManager.writeToChannel()` API; command execution should use `sendShellInput`/`sendRawShellInput`.
- [ ] `Host` does not currently contain `promptPattern`.
- [ ] Current project style is mostly `ObservableObject` + `@StateObject`, not `@Observable`.

## Phase 0 - Kickoff and Guardrails

### Exit criteria

- Assistant model is confirmed and documented.
- Scope is locked to phased delivery below.

### Checklist

- [ ] Confirm active model is `gpt-5.1-codex`.
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

- [ ] Validate whether current shared `ProSSHLibSSHHandle` causes contention under real usage (shell output + concurrent SFTP actions).
- [ ] Choose one approach and document rationale in this file:
  - Keep shared transport with serialized SFTP usage.
  - Add dedicated SFTP-only connection/session.
- [ ] If dedicated connection is chosen, implement lifecycle handling tied to SSH session connect/disconnect.
- [ ] Keep `TransferManager` compatibility (do not break Transfers tab).
- [ ] Add/extend tests for chosen architecture in `ProSSHMac/Terminal/Tests`.

## Phase 2 - Left Sidebar File Browser in Terminal

### Exit criteria

- File browser appears as collapsible left sidebar inside terminal screen.
- Supports navigation and file actions safely for remote sessions.

### Checklist

- [ ] Introduce sidebar tree model + view model (reuse `SFTPDirectoryEntry` where practical; avoid duplicate models unless needed).
- [ ] Implement lazy directory expansion and loading states.
- [ ] Integrate left sidebar into `TerminalView` layout without regressing `PaneManager` behavior.
- [ ] Implement file actions that send commands through `SessionManager.sendShellInput`:
  - Open in `nano`
  - Open in `vim`
  - View with `less`
  - `cat` to terminal
- [ ] Add safe shell quoting for file paths before sending commands.
- [ ] Add "Download" action by reusing existing transfer flow where possible.
- [ ] Add local-session fallback behavior (FileManager-based browsing or clear local-mode UX decision).
- [ ] Add keyboard shortcut for toggling file browser and verify no conflict with existing shortcuts.

## Phase 3 - Command Block History Index

### Exit criteria

- Structured command history exists and can be queried by tools.
- Prompt boundaries are detected via OSC 133 when available, with fallback heuristics.

### Checklist

- [ ] Add `CommandBlock` model.
- [ ] Add `TerminalHistoryIndex` (ring buffer + keyword search + recent retrieval).
- [ ] Implement OSC 133 semantic prompt parsing in `OSCHandler` (currently placeholder).
- [ ] Implement fallback prompt-boundary heuristics for shells without OSC 133 integration.
- [ ] Decide insertion point for block commits (parser/engine/session layer) and keep thread-safety explicit.
- [ ] If adding `Host.promptPattern`, include backward-compatible decoding defaults.
- [ ] Add tests for block segmentation and search behavior.

## Phase 4 - AI Agent Service (Responses API)

### Exit criteria

- AI service can answer questions using local tools and stream responses.
- Model is explicitly pinned to `gpt-5.1-codex`.

### Checklist

- [ ] Build agent service around Responses API using native Swift networking.
- [ ] Explicitly set request model to `gpt-5.1-codex`.
- [ ] Implement tool definitions and local tool execution pipeline.
- [ ] Implement minimum tool set:
  - `search_terminal_history`
  - `get_command_output`
  - `get_current_screen`
  - `get_recent_commands`
  - `execute_command`
  - `get_session_info`
- [ ] Map `execute_command` to `SessionManager.sendShellInput` with confirmation flow support.
- [ ] Persist `previous_response_id` safely (best-effort continuity; handle invalid/expired IDs).
- [ ] Add robust timeout/error handling for tool loops and network failures.

## Phase 5 - Right Sidebar AI UI + Safety

### Exit criteria

- AI chat sidebar is integrated in terminal UI and supports ask/follow/execute modes.
- Execute mode includes explicit user confirmation.

### Checklist

- [ ] Add AI sidebar view and view model.
- [ ] Integrate right sidebar in `TerminalView` with independent visibility/width from left sidebar.
- [ ] Add mode selector: Ask, Follow, Execute.
- [ ] In Follow mode, trigger from command-block completion events (not per-frame grid updates).
- [ ] In Execute mode, require explicit confirmation before sending any command.
- [ ] Add keyboard shortcut for AI sidebar toggle and verify no collisions.

## Phase 6 - Settings, Persistence, and Hardening

### Exit criteria

- API key management, sidebar persistence, tests, and docs are complete.

### Checklist

- [ ] Add Settings UI for OpenAI API key entry/update.
- [ ] Store API key securely via existing `EncryptedStorage`/Keychain path.
- [ ] Persist sidebar visibility and width per host/session.
- [ ] Add unit/integration coverage for:
  - SFTP sidebar behavior
  - Command block indexing
  - Tool execution safety checks
  - AI service error handling
- [ ] Run project tests and document any failures/gaps.
- [ ] Update user-facing docs and shortcut reference in settings/help text.

## Final QA Gate (Do Not Skip)

- [ ] Model used for implementation and validation was `gpt-5.1-codex`.
- [ ] No regressions in existing terminal split panes.
- [ ] No regressions in Transfers tab.
- [ ] Command execution from AI cannot happen silently.
- [ ] Network/API failures fail safely with user-visible errors.
