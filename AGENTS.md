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
- Rendering cost (2026-09-06/07, `Docs/RenderCost.md`): R0, R1 and R2a complete; **R2b implementation is complete, but throughput variability investigation remains open**.
  1. **Rendering is not the bottleneck.** Per frame the Metal renderer costs ~4-6 ms CPU and ~1 ms GPU at a 100% glyph cache hit rate, and runs where the surface was unbound drew zero frames while measuring the same speed. The cost is upstream of `draw(in:)`.
  2. **R1's ranking was wrong.** It put `publish` at 23-25% of wall; instrumented properly it measured **0.3%**. The unattributed ~18 s was `TerminalHistoryIndex.recordOutputChunk`, which ran once per raw PTY chunk (~1290/MB) and, past its 120,000-character cap, paid four O(n) passes over the whole buffer per call — **89% of wall**. Raw output is now a bounded UTF-8 byte buffer with an amortized trim and a read-time character cap, and `recordParsedChunk` runs once per 4 ms batch. Interleaved A/B on a quiet machine: **4.3x** (medians 0.92 -> 3.95 MB/s, non-overlapping ranges).
  3. R2a attributed 46.7% of wall to four post-feed engine round-trips. R2b now uses `feedAndCollectOutcome` and one MainActor handoff. Ordinary publishing uses two engine calls with MainActor scroll policy between them; the drain loop collects housekeeping once at the end. Bell consumption, sync overrides and input-mode refresh are covered by focused regressions.
  4. **Do not claim a repeatable R2b throughput win yet.** Three interleaved, instrumented Release pairs produced median to-sentinel ratios of 5.01x, 0.33x and 1.02x. Both binaries still have fast/slow runs; even parse/grid time varies within one unchanged launch. Direct launches with instrumentation off also vary; all three control pair medians favor baseline, so a performance regression cannot be ruled out. Investigate thread CPU time versus wall time and burst transitions before tuning debounce constants. See `Docs/R2bBenchmarkResults.md` for commands and raw evidence.
- Historical pre-R2b Release throughput: **36.4-37.3 MB/s** parser/grid, **19.20 MB/s** PTY-local, **3.8-5.0 MB/s** through the real app path (8 MB, no window, post-R2a); not a current comparison baseline.
- R2b verification (2026-09-06): Debug and Release builds succeeded; focused suites ran **167 tests, 0 failures, 2 instrumentation-only skips**, including all 21 rendering-path tests and 125 parser tests. No full-suite claim was made. Baseline is freshly built `af933f4`; comparison bundles and build/test logs are under `/tmp/prossh-r2b-*`.
- Perf instrumentation: `Terminal/Diagnostics/TerminalPerf.swift` gates five signposts and **19 in-process stage timers** behind `--perf-signposts` / `PROSSH_PERF_SIGNPOSTS=1` / the `terminal.perf.signposts` default. Off by default and verified free. Pass `--perf-signposts` to `benchmark-throughput.sh` to print a stage budget, which reports span and busy% per stage as well as time — a stage spanning the whole run at low busy% is blocked, not slow.
- **Benchmark measurement caveats — read `Docs/RenderCost.md` "Measurement caveats" before recording any rendered number.** `open -n App.app --args <anything>` yields a process with zero windows, so `--benchmark-render` silently measures the detached path (it warns now). The recorded "`--perf-signposts` costs ~19x" did not reproduce. Background load and thermal drift swing results 7x-100x, and the same binary measured 2.86 MB/s early in a session and 0.92 hours later — only within-pair ratios from interleaved A/B runs of two binaries are trustworthy.
- Test baseline: **883 tests, 1 failure.** The failure is load-sensitive, not a regression: on an unchanged tree it passes alone in 0.689s and runs 21/21 green in its own suite, but times out at 8.094s when four suites share one `xcodebuild test` invocation. The failure is `SessionManagerRenderingPathTests.testLocalSessionStreamsProgressiveCommandOutput`, which spawns a real `/bin/zsh` and times out under full-suite load. It is pre-existing — it fails the same way before these changes and passes in isolation. The older "870 tests, 0 failures" claim does not reproduce.
