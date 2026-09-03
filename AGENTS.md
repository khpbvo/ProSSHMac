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

- Latest status refresh (2026-03-05): this file should be read as a high-signal snapshot only; `Docs/featurelist.md` remains the authoritative long-term record and still requires `gpt-5.1-codex-max` for long-running implementation tasks.
- Latest terminal scroll stabilization (2026-03-05): live-output scrolling now preserves/clamps the current scrollback offset during publish cycles, compensates for scrollback growth, and avoids stale-offset races in `scrollTerminal`, so users can stay scrolled up while commands such as `ping` continue printing.
- Latest scrollbar regression fix (2026-03-05): `TerminalScrollbarView` interaction is constrained to a narrow trailing strip (`interactionWidth = 18`), restoring wheel scrolling in Metal terminal panes while keeping drag-to-scroll available.
- Latest smooth-scroll jitter fix (2026-03-05): `SmoothScrollEngine.jumpTo(row:)` is now a no-op when asked to jump to the current target row, preserving fractional motion and momentum during active gestures instead of snapping each time a snapshot publish re-syncs the same row.
- Renderer optimization (2026-03-05, since committed; the "uncommitted" note below is historical): `GlyphRasterizer` now uses a reusable scratch buffer and cached `CGContext`, `MetalTerminalRenderer` owns a long-lived rasterizer for main-thread misses/prepopulation, and background glyph batches reuse a per-batch rasterizer instance. This working-tree state matches the new `Docs/featurelist.md` entry and built successfully with `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build`.
- Current foreground track: smooth-scroll polish has landed; renderer/throughput optimization is the active in-progress stream, with planning and phase checklists in `docs/Optimization.md`, `docs/OptimizeP2.md`, and `docs/OptimizeP3.md`.
- Throughput profiling (2026-09-03, `docs/FasterThenYouWillEverLiveToBe.md`): Phases 0, 1, 2, 3 and 5 complete; only optional Phase 4 remains. Three findings, in descending size:
  1. **Every throughput number before this date came from a Debug (`-Onone`) build** — `scripts/benchmark-throughput.sh` hardcoded `-configuration Debug`. It now takes `--configuration <Debug|Release>` (default Debug, so old numbers stay reproducible). Release is ~20x faster on parser/grid. **Never compare a Debug figure to a Release one, and always state which you measured.**
  2. `LocalPTYProcess.yieldSanitized` scanned every chunk for zsh's one-off startup warning for the whole session, because its stop flag was only set if the warning was actually found — 92.6% of local-shell wall time. Extracted to `ZshStartupWarningFilter` and bounded to 32 KB. PTY-local 6.81 → 17.97 MB/s.
  3. The 89 MB/s target came from a pipe that does no terminal emulation and is unreachable. Restated against the fastest peer measured here (Terminal.app, ~26 MB/s with rendering, via `scripts/benchmark-peer-emulator.sh`).
- Current Release throughput: **36.38 MB/s** parser/grid fullscreen, **17.97 MB/s** PTY-local.
- Perf instrumentation: `Terminal/Diagnostics/TerminalPerf.swift` gates the five signposts and in-process stage timers behind `--perf-signposts` / `PROSSH_PERF_SIGNPOSTS=1` / the `terminal.perf.signposts` default. Off by default and verified free. Pass `--perf-signposts` to `benchmark-throughput.sh` to print a stage budget.
- Test baseline: **883 tests, 1 failure.** The failure is `SessionManagerRenderingPathTests.testLocalSessionStreamsProgressiveCommandOutput`, which spawns a real `/bin/zsh` and times out under full-suite load. It is pre-existing — it fails the same way before these changes and passes in isolation. The older "870 tests, 0 failures" claim does not reproduce.
