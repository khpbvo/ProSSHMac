# FasterThenYouWillEverLiveToBe — Closing the Terminal Throughput Gap

Profiling plan for the unexplained throughput gap between ProSSHMac and its stated target.

**Status:** Phases 0, 1, 3 and 5 complete (2026-09-03). H1 confirmed; H2 and H3 killed; H4
confirmed and the target restated. PTY-local throughput went **1.74 MB/s (Debug) → 6.81 (Release)
→ 17.97 MB/s** (bounding the zsh startup-warning scan). Phase 2 was absorbed into Phase 1, whose
stage timers answered it directly. **Phase 4 is the only work left**, and it is optional — see
"Where this stands" at the end.

---

## Overview

### Goal

Explain, and then close, the gap between current terminal throughput (~1.7 MB/s) and the
target in `docs/Optimization.md` (~89 MB/s — `dd if=/dev/urandom bs=1024 count=100000 | base64`
in under 1.5s). Host baseline for the same command is **0.373s (~357 MB/s)**, so the ceiling
is not the data source.

### Why this needs a plan rather than a checklist

`docs/FutureFeatures.md` Priority 2 lists seven "documented bottlenecks". Spot-checking on
2026-09-03 found the remaining unchecked ones are already done:

- *"Eliminate Data → Array copy"* — `TerminalEngine.feed(_ data: Data)`
  (`Terminal/Parser/TerminalEngine.swift:154`) already iterates `Data` directly via a feed queue.
- *"Reduce actor boundary overhead"* — `TerminalGrid` is a `nonisolated final class`
  (`Terminal/Grid/TerminalGrid.swift:17`) held directly by the engine
  (`Terminal/Parser/TerminalEngine.swift:33`). There is no parser↔grid actor hop left to remove.

**The documented explanations are exhausted and the gap is still ~50x.** That makes this a
measurement problem first. Every phase below is gated on evidence, not on a guess about which
code is slow.

### Preconditions (already satisfied)

- The benchmark harness is trustworthy as of 2026-08-27 — `BenchmarkSentinelMatcher` fixed the
  echoed-sentinel bug that produced the invalid 0.03 MB/s PTY figure.
- The full test suite is green (870 tests, 0 failures, 2026-09-03), so hot-path changes have a
  regression signal. **Do not start Phase 3+ against a red suite.**
- The Time Profiler method is proven on this codebase: it located the partial-scroll hotspot and
  took sampled `scrollUp` inclusive time from ~4.89s to ~1.23s.

### Pipeline under measurement

```
PTY read (LocalShellChannel) → AsyncStream<Data> → TerminalEngine actor
  → parser (sync loop, per-byte async executeAction off the fast path)
  → grid (sync, nonisolated) → GridSnapshot → SessionManager (MainActor)
  → CellBuffer → Metal GPU
```

### Affected files

Measurement and tooling:
- `scripts/benchmark-throughput.sh` — build configuration is currently hardcoded
- `ProSSHMac/App/ThroughputBenchmarkRunner.swift` — scenario driver, `BenchmarkSentinelMatcher`
- `ProSSHMac/Terminal/Parser/TerminalEngine.swift` — `ParserChunk` signpost (`#if DEBUG`)
- `ProSSHMac/Terminal/Grid/TerminalGrid+Snapshot.swift` — `GridSnapshot` signposts
- `ProSSHMac/Terminal/Renderer/CellBuffer.swift` — `CellBufferUpdate` signpost
- `ProSSHMac/Terminal/Renderer/RendererPerformanceMonitor.swift` — `TerminalFrame` signpost

Likely subjects (only if evidence points at them):
- `ProSSHMac/Terminal/Parser/TerminalEngine.swift` — per-byte dispatch
- `ProSSHMac/Terminal/Grid/TerminalGrid+Printing.swift` — cell write path
- `ProSSHMac/Terminal/Grid/TerminalGrid+Snapshot.swift` — snapshot build
- `ProSSHMac/Services/TerminalRenderingCoordinator.swift` — publish cadence

---

## Ranked Hypotheses

Each carries its current evidence. Phases 0–2 exist to confirm or kill them, in this order.

### H1 — The numbers are measuring an unoptimized build (highest prior, cheapest test)

`scripts/benchmark-throughput.sh:50` and `:59` hardcode `-configuration Debug`, and the Machine
Profile table in `docs/Optimization.md` records **"Build config: Debug (no optimizations)"**.
Every figure in that document — the 1.68 MB/s, the 400x and 50x gap framings — comes from a
build with no inlining, no generic specialisation, full retain/release traffic, and bounds
checks live.

For Swift code shaped like this (tight per-byte loops, generics, `struct` cells, `ContiguousArray`
access) Debug-to-Release commonly lands somewhere between 5x and 50x. **This hypothesis alone
could account for most of the gap, and no one has measured it.** It must be tested before any
code is optimised, or the project risks micro-optimising against a phantom.

### H2 — Per-byte async dispatch off the fast path

`processByte(_:)` and `executeAction(_:byte:)` are both `async`
(`Terminal/Parser/TerminalEngine.swift:237`, `:311`), so every byte that misses
`shouldFastPathGroundTextByte` takes an `await` inside the actor. Plain text is bulk-handled by
`grid.processGroundTextBytes`, so this should *not* dominate the base64 workload — but it will
dominate escape-heavy output (TUIs, SGR-dense colour). Expect this to show up in the partial /
TUI-shaped scenarios rather than fullscreen.

### H3 — Snapshot and publish cadence, not parsing

Throughput mode already halves publish frequency (8ms → 16ms) and drops `visibleText()`
extraction 30Hz → 5Hz, which implies these were once significant. If Phase 2 attribution shows
parse time is small relative to wall time, the cost is downstream in
`GridSnapshot` → `PublishGridState` → `CellBufferUpdate`.

### H4 — The target itself is miscalibrated

89 MB/s is derived from the host `base64` pipe baseline, which does no terminal emulation:
no grid writes, no reflow, no snapshotting, no GPU upload. A terminal emulator that parses,
stores, and renders every cell cannot reach a pipe's throughput. If Phases 0–2 land at, say,
40 MB/s with a flat profile, the correct outcome is to **restate the target against a peer
emulator** (Ghostty/Alacritty measured on the same machine and workload) rather than chase an
unreachable number. Ending this work with an honest target is a valid success condition.

---

## Phases

Each phase is one session. Do not start a phase before its predecessor's exit criteria are met.

- [x] **Phase 0: Release-vs-Debug baseline**

  **Goal:** Establish what the throughput actually is in a shipping build. Tests H1.

  **Method:** Add a `--configuration <Debug|Release>` flag to `scripts/benchmark-throughput.sh`
  (default stays `Debug` so historical numbers remain reproducible). Run the standard 2 MB
  parser/grid, sustained 32 MB, and PTY-local scenarios under both configurations, three runs
  each, per the Measurement Protocol below.

  **Exit criteria:** A Release-vs-Debug table for all three scenarios in `docs/Optimization.md`,
  with the Machine Profile updated to record both. The headline "Current:" figures are restated
  against Release, and the gap is re-expressed against it. If Release closes most of the gap,
  **stop and re-scope the rest of this plan** — Phases 3+ may be unnecessary.

  **Result (2026-09-03) — H1 CONFIRMED.** Release builds clean on the first attempt (no
  compilation fixes were needed). Full table in `docs/Optimization.md` §"Release vs Debug".

  | Scenario | Debug | Release | Speedup |
  |---|---|---|---|
  | 2 MB parser/grid fullscreen | 1.84 MB/s | **36.40 MB/s** | 19.8x |
  | 2 MB parser/grid partial | 1.82 MB/s | **35.85 MB/s** | 19.7x |
  | 32 MB sustained fullscreen | 0.39 MB/s* | **36.08 MB/s** | 91.8x* |
  | 32 MB sustained partial | 0.35 MB/s* | **35.62 MB/s** | 101.8x* |
  | 2 MB PTY local end-to-end | 1.74 MB/s | **6.81 MB/s** | 3.9x |

  \* Debug 32 MB degrades within one process run (1.89 → 0.40 → 0.41 → 0.37 MB/s). Release is
  flat. The previously documented "Sustained 32 MB: 1.69–1.81 MB/s" was that artifact.

  Three consequences:

  1. **The ~50x gap was mostly `-Onone`.** Remaining gap to the 89 MB/s target is **2.4x** on
     parser/grid. **H4 is now the live question, not H2 or H3** — 36 MB/s of full VT emulation
     against a 385 MB/s pipe that does none of it is close to the useful floor.
  2. **The bottleneck moved to the PTY read path.** Release parser/grid does 36 MB/s but the full
     PTY path delivers 6.81 MB/s — 5.3x slower than the parser it feeds. Debug hid this by making
     both ~1.8 MB/s. This was not in the ranked hypotheses at all.
  3. **It is not the kernel tty.** The same 2 MB payload pushed through a real PTY with
     `script -q /dev/null` reaches 92–138 MB/s on this machine. The ceiling is in
     `LocalShellChannel` → `AsyncStream<Data>` → `TerminalEngine.feed`.

  **Re-scope recommendation:** replace Phases 1–4 as written. Phase 1's Release-traceability work
  is still needed, but Phase 2's stage attribution should target the **PTY delivery path** rather
  than parse/grid/snapshot, and Phase 5's retarget is now the highest-value remaining step.

- [x] **Phase 1: Make Release traceable** *(absorbed Phase 2)*

  **Done.** `Terminal/Diagnostics/TerminalPerf.swift` gates the five signposts **and** a set of
  in-process stage timers behind one runtime switch (`--perf-signposts`, `PROSSH_PERF_SIGNPOSTS=1`,
  or the `terminal.perf.signposts` default). Off by default: the shared `OSLog` is `.disabled` and
  the timers return after one static `Bool` check.

  Instruments could not be driven end-to-end from a script — no stock template combines Time
  Profiler with Points of Interest, and `xctrace record` takes only a template *name* — so the
  in-process timers became the primary attribution path rather than a supplement. They record at
  chunk granularity, never per byte, and `ThroughputBenchmarkRunner` prints the budget.

  Three defects found while un-gating: the subsystem was split between `com.prossh` and
  `nl.budgetsoft.ProSSHV2`; the category was `TerminalPerf`/`TerminalRenderer`, so these appeared
  under the *os_signpost* instrument and **never** under Points of Interest as this doc claimed;
  and the coordinator's `#if DEBUG` block mixed a signpost with an up-to-10×/s `print` that had to
  stay Debug-only.

  **Verified free:** instrumentation off measures 35.69 MB/s parser/grid and 6.78 MB/s PTY-local
  against Phase 0's 36.40 and 6.81 — inside run-to-run spread.

- [x] **Phase 2: Stage attribution** — *answered by Phase 1's timers on first run.*

  2 MB pty-local, Release:

  ```
  pty read          7.61 ms    1.9%
  pty sanitize    364.08 ms   92.6%
  pty handoff     365.31 ms   92.9%
  parse + grid     72.79 ms   18.5%
  snapshot build    0.04 ms    0.0%
  wall            393.27 ms
  ```

  **H2 and H3 are both killed.** Parse is 18.5% and does the full 2.67 MB in 72.8 ms — 36.7 MB/s,
  identical to the standalone parser/grid benchmark, so per-byte async dispatch (H2) is not
  costing anything measurable on this workload. Snapshot build is 0.04 ms, so H3 is not it either.
  One stage held 92.6%.

- [x] **Phase 3: Attack the dominant stage**

  **`LocalPTYProcess.yieldSanitized` strips zsh's one-off `can't set tty pgrp` startup warning, and
  its "stop scanning" flag was only ever set if the warning was actually found.** Under any shell
  that never emits it — `sh`, `bash`, and the benchmark's own `/bin/sh` — the filter ran forever,
  paying per chunk a UTF-8 decode, a concatenation, a case-insensitive `range(of:)`, a
  `lowercased()` copy, up to 23 `String` slice comparisons, and a re-encode back to `Data`.

  Extracted to `Services/ZshStartupWarningFilter.swift` (a testable value type, following the
  `BenchmarkSentinelMatcher` precedent) and bounded to the first 32 KB of a session. The warning
  lands within the first ~100 bytes. Also fixed: a chunk boundary splitting a multi-byte character
  made the old code emit bytes out of order.

  | PTY-local 2 MB, Release | Before | After |
  |---|---|---|
  | Throughput | 6.81 MB/s | **17.97 MB/s** (2.6x) |
  | `pty sanitize` | 364.08 ms / 92.6% | 4.49 ms / 2.7% |
  | wall | 393.27 ms | 155.66 ms |

  Parser/grid unchanged at 36.38 MB/s. 13 new tests cover a filter that had none. Full suite:
  883 tests, 1 failure — a pre-existing flaky local-shell test that fails identically at the
  previous commit under full-suite load and passes in isolation.

- [ ] **Phase 4: Second-order costs** — *optional; the only work left.*

  The dominant stage is now `parse + grid` at 44% of a 156 ms wall. The other ~84 ms is the reader
  loop and `AsyncStream` delivery: **2592 chunks for 2.67 MB is ~1 KB per chunk**, so the path pays
  ~2600 actor hops for 2.67 MB. The `poll()`-then-drain loop returns as soon as the tty has
  anything, rather than accumulating toward its 64 KB buffer.

  Worth trying, in order: coalesce reads before handing off (a short accumulation window, or drain
  until EAGAIN *and* a minimum size); check whether `AsyncStream`'s default unbounded buffering is
  adding a hop per element that a batched hand-off would remove.

  Judge against the retargeted number below, not against 89 MB/s.

- [x] **Phase 5: Re-baseline, retarget, and document**

  **H4 confirmed.** Measured on this machine, 6 MB of base64 into a real terminal window:

  | | Throughput |
  |---|---|
  | Host pipe to `/dev/null` (no emulation, no PTY) | ~276 MB/s |
  | Host through a PTY (`script -q /dev/null`) | 92–138 MB/s |
  | **Terminal.app** (with rendering) | **22.2 MB/s** |
  | **iTerm2** (with rendering) | **2.44 MB/s** |
  | **ProSSHMac PTY-local** (no rendering) | **17.97 MB/s** |

  Ghostty and Alacritty are not installed here. The comparison is **not like-for-like** — peers
  include rendering and ProSSHMac's number does not, so ProSSHMac is flattered; Terminal.app also
  coalesces and drops output rather than emulating every cell.

  **No real emulator on this machine approaches 89 MB/s.** The target in `docs/Optimization.md` is
  restated as **match or beat Terminal.app end-to-end with rendering on (~22 MB/s here)**.

---

## Where this stands

Started as "explain a 50x gap". The gap was three things, in descending order:

1. **A Debug build** (~20x). Phase 0.
2. **A startup filter that never switched off** (2.6x on the PTY path). Phase 3.
3. **A target derived from a pipe that does no emulation** (the rest). Phase 5.

None of the four ranked hypotheses named the actual bottleneck — H1 was right about the
measurement, but the code defect was found only because Phase 1's timers were pointed at a stage
nobody had suspected. H2 and H3 were both measured and killed.

**The remaining honest gap is small.** ProSSHMac does 17.97 MB/s through a real PTY without
rendering against a fastest-peer 22.2 MB/s with rendering. The unknown is what rendering costs,
which none of these benchmarks measure — that, not further parser micro-optimisation, is the
highest-value thing left to find out.

## Measurement Protocol

Every number recorded under this plan must state all of the following, or it is not comparable
to any other number in `docs/Optimization.md`:

- Build configuration (**Debug or Release**) — previously implicit and the source of H1
- Scenario and size (`--benchmark-bytes`, `--benchmark-chunk`, `--benchmark-runs`)
- Fullscreen vs partial scroll region
- Grid dimensions (historically 80×24)
- Whether throughput mode is enabled
- Whether signposts are enabled (post-Phase 1)
- Parser state after the run (must be `ground` — a non-ground state means the run was invalid)
- Run-to-run spread, not just the mean

Rules:

- **Discard the first run.** The 2026-08-27 sample shows a repeatable cold-start penalty — the
  first fullscreen run averaged 1.68 MB/s while later runs reached 1.85–1.87 MB/s.
- **Three runs minimum**, and report the spread. Several past "improvements" in this document are
  within the noise band of the runs around them.
- **Change one variable at a time.** Configuration and code changes in the same measurement are
  uninterpretable.
- **Re-run the full suite before recording any code-change result.** Baseline as of 2026-09-03 is
  870 tests, 0 failures.

---

## Risks

- **Optimising a Debug artifact.** The main risk this plan exists to prevent. Phase 0 is
  non-negotiable and comes first.
- **Chasing an unreachable target.** 89 MB/s comes from a pipe that does no emulation. H4 and
  Phase 5 exist so the work can end with a corrected target rather than an open-ended chase.
- **Regressing correctness for speed.** The parser and grid hot paths are exactly where the
  recently-fixed SGR-coordinate and OSC UTF-8 bugs lived. Targeted suites for any hot-path
  change: `VTParserTests`, `TerminalGridTests`, `PerformanceValidationTests`,
  `ApplicationCompatibilityTests`.
- **Noise-driven conclusions.** Run-to-run spread on this benchmark is roughly ±0.1 MB/s at
  2 MB; treat anything smaller as no change.
- **Signpost overhead skewing Release numbers.** Phase 1 must verify this explicitly rather than
  assume it is free.
