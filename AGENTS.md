# AGENTS Working Memory

This file is the project working memory for future assistants in this repository.

## Long-Term Memory Source

- The long-term memory document for this project is: `Docs/featurelist.md`.
- Always read `Docs/featurelist.md` before starting substantial work.
- Use `Docs/featurelist.md` as the authoritative checklist, phase plan, and project status record.
- At the start of each task, explicitly align on:
  - Starting Point (current reality)
  - End Point (definition of done)
  and ensure both are represented in `Docs/featurelist.md`.

## Persistence Loop (Required)

- After completing any task, always update `Docs/featurelist.md` to reflect:
  - What was done
  - What is still pending
  - Any scope, architecture, or sequencing changes
- If process/instruction-level guidance changed, also update `AGENTS.md`.
- Add a short dated entry to the loop log in `Docs/featurelist.md` whenever a meaningful milestone is completed.

## Context-Loss Safeguard

- Keep both `AGENTS.md` and `Docs/featurelist.md` current at all times.
- This is mandatory to preserve continuity across assistant handoffs and in cases of context loss, overflow, or truncated history.

## Current Status Snapshot

- Latest docs/help sync (2026-02-23): user-facing shortcut/help text is now aligned with current Ask-only copilot flow and keyboard shortcuts in both `SettingsView` and the AI pane composer hint.
- Latest AI token-efficiency + UX hardening (2026-02-23): reduced default screen/context payload sizes (`get_current_screen` default 60/max 160, command `output_preview` 300 chars), capped `get_command_output` via `max_chars` with truncation metadata, and suppressed remote internal tool-command echo to reduce noisy terminal/context loops.
- Latest test-stability fix (2026-02-23): resolved the `PaneManagerTests` host-process malloc/free crash by avoiding actor-isolated deallocation for pane-layout lifecycle objects (`nonisolated deinit` in `PaneManager` and `PaneLayoutStore`); `PaneManagerTests` quarantine was removed and targeted suite now passes.
- Latest test-stability fix (2026-02-23): resolved the `TerminalAIAssistantViewModelTests.testClearConversationResetsMessagesAndCallsService` host-process malloc/free crash by making the AI view-model deallocation path nonisolated (`nonisolated deinit`) and removing the temporary `XCTSkip` quarantine; targeted suite now passes.
- Latest AI pane stability + readability fix (2026-02-23): composer bridge now defers focus/text/height binding writes through `DispatchQueue.main.async` (with focus de-duplication), removing remaining `Modifying state during view update` paths; streaming assistant text now renders through markdown parser and sentence-splitting was hardened to detect boundaries even when spaces are missing after punctuation.
- Latest file-browser reliability fix (2026-02-23): stale async directory-load completions now clear root/path loading flags when no active request remains, preventing persistent spinner states until pane switching.
- Latest AI composer stability fix (2026-02-23): eliminated AppKit “Internal inconsistency in menus” spam from the embedded composer text view by replacing default rich-text contextual menus with a minimal explicit menu (`Cut/Copy/Paste/Select All`) and disabling extra text-checking services on that control.
- Latest terminal UX fix (2026-02-23): file-browser root loading no longer stalls on stale async completions. Each directory fetch now tracks a per-path request ID and always clears loading flags for the active request before applying guard checks, preventing persistent spinner states that previously required pane switching to recover.
- Latest AI reply UX fix (2026-02-23): assistant output readability and perceived streaming improved by reflowing dense single-line replies into short paragraphs, reducing chunk size/increasing stream cadence visibility, rendering streaming messages as lightweight plain text until completion, and tightening assistant prompt instructions to prefer structured markdown (short paragraphs + bullets).
- Latest AI readability hardening (2026-02-23): added renderer-level fallback paragraphization in `TerminalAIAssistantPane` (`makeReadableMarkdown`) so long dense assistant prose is split into multi-paragraph markdown even when model formatting is weak.
- Latest AI stability fix (2026-02-23): resolved SwiftUI update-loop regression in the multiline AI composer that could leave AI/file-browser loading spinners stuck. Binding updates from `NSTextView` delegate/layout callbacks are now async on main and no longer mutate state synchronously during `updateNSView`.
- Latest AI stability fix (2026-02-23): removed remaining `Modifying state during view update` warning at `TerminalAIAssistantPane.swift:415` by eliminating focus `Binding` mutations inside the NSView bridge; focus changes now flow through callback routing only.
- Latest AI stability fix (2026-02-23): hardened NSView bridge callbacks with `Task { @MainActor; await Task.yield() }` deferral before propagating focus/text/height updates, preventing same-turn state writes during SwiftUI view updates.
- Latest AI UX polish (2026-02-23): assistant text now renders as parsed Markdown (while fenced code remains syntax-highlighted/copyable), AI pane resizing is now visually discoverable via a dedicated drag handle and wider width range, and the chat composer is multiline/auto-expanding with `Enter` to send plus `Shift+Enter` for newline.
- Latest AI stability guard (2026-02-23): file ingestion is now chunk-bound to `<=200` lines. New `read_file_chunk` tool was added for local/remote sessions, and unbounded reads through `execute_command` are blocked with a `read_window_required` response so long tasks iterate by line windows.
- Latest tuning (2026-02-23): AI tool-loop cap is now `200` iterations (was `99`) via `OpenAIAgentService` default plus explicit `AppDependencies` wiring; Ask-mode instructions were also tightened to reduce redundant tool calls and stop earlier when enough evidence is gathered.
- Latest UX change (2026-02-23): AI copilot is now fully Ask-only in both UI and backend. Ask/Follow/Execute switcher and mode-specific backend branches were removed; command execution is routed from Ask when user intent is explicit.
- Latest milestone (2026-02-23): Phase 6 hardening now includes SFTP sidebar regression coverage. `SessionManagerSFTPSidebarTests` validates connected-session remote listing success, disconnected-session guard behavior, and transport error propagation, and targeted test runs are green.
- Latest API fix (2026-02-23): OpenAI Responses tool definitions now encode with top-level `name`/`description`/`parameters` (no nested `function` object), resolving runtime 400 errors like `Missing required parameter: 'tools[0].name'`.
- Latest API fix (2026-02-23): strict tool schemas now list all declared properties in `required` for `strict: true`, resolving runtime 400 errors like `Invalid schema ... Missing 'limit'`.
- Latest AI behavior fix (2026-02-23): Ask-mode developer instructions are now the sole behavior contract: use terminal context tools by default and run user-requested commands (including interactive editors) via `execute_command` only on explicit intent.
- Latest AI capability (2026-02-23): agent filesystem tools now work across local and remote sessions; in SSH sessions `search_filesystem` and `search_file_contents` execute safe read-only remote `find`/`rg`/`grep` queries with timeout/error handling and structured results.
- Latest AI parsing fix (2026-02-23): remote filesystem/content tool parsing now tolerates whitespace-normalized `find` output and emits `raw_output_preview` fallback when structured parsing is incomplete, avoiding false negatives in wrapped terminal output.
- Latest UX fix (2026-02-23): AI composer now submits on Enter, and terminal key-capture no longer steals Cmd+V/Cmd+C when a text input (like the AI chat field) is focused.
- Latest UX fix (2026-02-23): AI copilot composer now reliably captures keyboard input; while the chat field is focused, direct terminal key capture is paused and restored when focus returns to terminal.
- Latest UX fix (2026-02-23): `SettingsView` AI section now shows a reliable bordered API-key input and clipboard paste button; key entry/save is no longer blocked by form-row rendering quirks.
- Settings pane scrolling has been fixed; long settings content is now reachable.
- Shared `ProSSHMac` scheme now has a working test pipeline: `ProSSHMacTests` bundle target is wired and `xcodebuild ... test` passes with a smoke baseline.
- Next implementation phase is tracked in `Docs/featurelist.md` under remaining Phase 6 work (broader test-bundle migration coverage).
