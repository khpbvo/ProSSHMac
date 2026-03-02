# Local Input V2 - Phase B Checklist

Last updated: 2026-03-02
Owner: Terminal input subsystem
Related Phase A implementation: `terminal.input.local.v2.enabled` byte-first local input path

## Purpose

Phase B completes Local Input V2 by making it the only local-input path after a controlled soak period, with explicit guardrails for regression detection and rollback.

## Scope

- In scope:
  - Default Local Input V2 ON in production builds.
  - Remove legacy local-input fallback paths and duplicate routing logic.
  - Expand regression coverage for focus/input conflicts and editing-key behavior.
  - Add operational observability for local input failures.
  - Document rollback and incident handling.
- Out of scope:
  - SSH input pipeline redesign.
  - Terminal rendering changes unrelated to input.

## Starting Point

- Phase A is implemented and behind feature flag `terminal.input.local.v2.enabled` (default true).
- Local input capture supports dual paths:
  - Local sessions with flag ON: app-level key capture -> byte encoding -> raw byte send.
  - Non-local/flag OFF: existing string path.
- New integration tests exist for local `Tab` completion and local `Ctrl+C` interruption.

## End Point (Definition of Done)

- Local sessions use a single authoritative Local Input V2 path with no legacy local fallback code.
- Required regression suite passes (including new focus and editing-key tests).
- Rollback switch behavior is validated and documented.
- Production diagnostics are sufficient to triage local input failures without reproducing manually.

## Phase B Execution Checklist

## 1. Preflight and Baseline

- [x] Confirm Phase A baseline still green:
  - [x] `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build`
  - [x] `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' test -only-testing:ProSSHMacTests/ShellIntegrationTests/testLocalShellTabCompletionCompletesPartialToken -only-testing:ProSSHMacTests/ShellIntegrationTests/testLocalShellCtrlCInterruptsForegroundCommand`
- [x] Capture current known warnings/failures unrelated to Local Input V2 to avoid false attribution.
- [x] Record current behavior snapshot (short note in `docs/featurelist.md` loop log).

## 2. Code Consolidation (Remove Legacy Local Path)

- [x] In `TerminalInputCaptureView`:
  - [x] Remove local-session legacy path branching once rollback criteria are satisfied.
  - [x] Keep one local event monitor path for local sessions.
  - [x] Preserve command-shortcut behavior (`Cmd+C`, `Cmd+V`, zoom, clear scrollback).
- [x] In terminal hosts (`TerminalView`, `ExternalTerminalWindowView`):
  - [x] Remove duplicate local-input callback wiring not used by V2.
  - [x] Keep SSH path behavior unchanged.
- [x] In `SessionShellIOCoordinator` / `SessionManager`:
  - [x] Keep byte APIs as canonical for local hardware input.
  - [x] Ensure history/recording bookkeeping remains correct for byte sends.
- [x] Verify no dead code remains for removed local path (`rg` search and compile check).

## 3. Feature Flag Strategy

- [x] Decide final flag policy:
  - [ ] Option A (recommended): keep flag for one release as emergency rollback only.
  - [x] Option B: remove flag entirely in Phase B.
- [ ] If Option A:
  - [ ] Make rollback semantics explicit and tested.
  - [ ] Ensure flag read path does not reintroduce dual local input routing complexity.
- [x] If Option B:
  - [x] Remove `terminal.input.local.v2.enabled` references from UI and code.
  - [x] Remove obsolete docs/settings references.

## 4. Regression Test Expansion

- [x] Add focus-conflict integration tests:
  - [x] Terminal input is not consumed while AI composer is focused.
  - [x] Terminal input is not consumed while search bar is focused.
  - [x] Input capture resumes correctly when terminal regains focus.
- [x] Add editing-key behavior tests (local PTY):
  - [x] Backspace modifies input line as expected.
  - [x] Left/right arrow edits command in-place correctly.
  - [x] Enter dispatches current line and returns prompt.
- [x] Add control/special key tests:
  - [x] Escape is delivered correctly.
  - [x] Tab remains completion (not literal insertion).
  - [x] Ctrl+C interrupts foreground command promptly.
- [x] Update test doubles for any protocol/API changes introduced during cleanup.

## 5. Observability and Diagnostics

- [x] Add lightweight structured logs for local input failures only (no sensitive content):
  - [x] Session ID + local/remote marker.
  - [x] Input event type and encoded byte-count (not payload content).
  - [x] Send result (success/error) and error code.
- [x] Add log throttling/de-duplication to avoid noisy output loops.
- [x] Validate logs are present in debug builds and minimal in release builds.

## 6. Rollout Readiness and Rollback

- [x] Define explicit rollback triggers, for example:
  - [x] Reproducible local `Tab` failure in default shells.
  - [x] Reproducible local `Ctrl+C` non-interruption for foreground jobs.
  - [x] Critical focus-capture regression blocking terminal typing.
- [x] Validate rollback path end-to-end once (if rollback flag retained).
- [x] Document operational response:
  - [x] Immediate mitigation steps.
  - [x] Required diagnostics to collect.
  - [x] Owner/escalation path.

## 7. Documentation and Handoff

- [x] Update `docs/featurelist.md`:
  - [x] What changed in Phase B.
  - [x] What remains (if any).
  - [x] Dated loop-log milestone.
- [x] Update this file (`docs/PhaseB.md`) status checkboxes and notes.
- [ ] If rollout/ops policy changed, update `AGENTS.md` guidance.

## 8. Final Acceptance Gates

- [x] Build passes on macOS target.
- [x] Required targeted local-input tests pass.
- [ ] No new local-input regressions in manual smoke checklist:
  - [ ] Tab completion in local zsh/bash.
  - [ ] Ctrl+C on long-running foreground command (`sleep`/`ping`).
  - [ ] AI composer focus does not leak keystrokes to terminal.
  - [ ] Search field focus does not leak keystrokes to terminal.
- [x] Codebase has one local-input routing path (no legacy duplicate path).
- [x] Featurelist and loop log updated.

## Manual Smoke Checklist (Release Candidate)

- [ ] Open local terminal and run partial command, press Tab, verify completion.
- [ ] Start `sleep 30`, press Ctrl+C, verify prompt returns immediately.
- [ ] Type command, use arrows/backspace to edit, submit with Enter.
- [ ] Focus AI composer, type text, verify terminal does not receive keystrokes.
- [ ] Return focus to terminal, verify input capture resumes without extra clicks.
- [ ] Repeat in external terminal window.

## Notes

- Keep the implementation byte-first from capture to transport for local sessions.
- Avoid reintroducing multiple local fallback layers that obscure root-cause debugging.
- Any change that touches input capture must preserve Command shortcuts and text-input focus guards.
- Phase B selected Option B: remove `terminal.input.local.v2.enabled` and keep one local routing path.
- Rollback for Option B is operational (revert/cherry-pick), not runtime toggle-based.
