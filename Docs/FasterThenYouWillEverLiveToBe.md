# FasterThenYouWillEverLiveToBe — Closing the Terminal Throughput Gap

Profiling plan for the unexplained throughput gap between ProSSHMac and its stated target.

**Status:** Not started. Created 2026-09-03.

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

- [ ] **Phase 0: Release-vs-Debug baseline**

  **Goal:** Establish what the throughput actually is in a shipping build. Tests H1.

  **Method:** Add a `--configuration <Debug|Release>` flag to `scripts/benchmark-throughput.sh`
  (default stays `Debug` so historical numbers remain reproducible). Run the standard 2 MB
  parser/grid, sustained 32 MB, and PTY-local scenarios under both configurations, three runs
  each, per the Measurement Protocol below.

  **Exit criteria:** A Release-vs-Debug table for all three scenarios in `docs/Optimization.md`,
  with the Machine Profile updated to record both. The headline "Current:" figures are restated
  against Release, and the gap is re-expressed against it. If Release closes most of the gap,
  **stop and re-scope the rest of this plan** — Phases 3+ may be unnecessary.

- [ ] **Phase 1: Make Release traceable**

  **Goal:** Be able to profile the build that the numbers now come from.

  **Method:** The `ParserChunk` signpost is inside `#if DEBUG`
  (`Terminal/Parser/TerminalEngine.swift:169-187`); audit the other four for the same gating.
  Move Points-of-Interest signposts behind a runtime flag (e.g. a `terminal.perf.signposts`
  default, or a `PROFILE` build setting) so a Release build can emit them, keeping them off by
  default so normal Release users pay nothing.

  **Exit criteria:** A Time Profiler + Points of Interest trace captured against a Release build
  showing all five intervals — `ParserChunk`, `GridSnapshot`, `GridSnapshotScrollback`,
  `PublishGridState`, `CellBufferUpdate`. Confirm signpost overhead itself is not material by
  re-running Phase 0's benchmark with them enabled and disabled.

- [ ] **Phase 2: Stage attribution**

  **Goal:** A per-stage budget. Answer "where does the wall time actually go" with numbers,
  before touching any implementation. Tests H2 and H3.

  **Method:** From the Phase 1 traces, attribute wall-clock time across PTY read → parse →
  grid write → snapshot build → publish → CellBuffer upload → GPU. Do this for at least three
  workload shapes, because they stress different stages:
  1. base64 fullscreen (plain text, fast path dominant)
  2. partial scroll region (grid rotation dominant)
  3. an escape-dense TUI capture (tests H2 — record a real `htop`/Claude Code session with
     `SessionRecorder` and replay it)

  **Exit criteria:** A stage-budget table in `docs/Optimization.md` — stage, absolute ms, % of
  wall time, per workload. One stage is identified as dominant, **or** the profile is
  demonstrably flat (no stage >25%), which would promote H4.

- [ ] **Phase 3: Attack the dominant stage**

  **Goal:** Close the largest identified cost. Scope is deliberately undefined here — it is set
  by Phase 2's evidence.

  **Method:** Same loop that worked on `scrollUp`: capture a before trace, form one hypothesis,
  change one thing, capture an after trace, keep it only if the benchmark moves outside run-to-run
  noise. One optimisation per commit, each with its trace evidence recorded.

  **Exit criteria:** A measured improvement on the dominant stage, full suite still green, and
  before/after traces plus numbers appended to `docs/Optimization.md`.

- [ ] **Phase 4: Second-order costs**

  **Goal:** Repeat Phase 3 against the next stage down, if the remaining gap justifies it.

  **Exit criteria:** Either a further measured improvement, or a written finding that the
  remaining stages are within a few percent of each other and further micro-optimisation is not
  the highest-value work.

- [ ] **Phase 5: Re-baseline, retarget, and document**

  **Goal:** Leave the project with honest numbers and a defensible target.

  **Method:** Full re-run of all scenarios under both configurations. Measure a peer emulator
  (Ghostty or Alacritty) on the same machine and the same workload to calibrate what a good
  native terminal actually achieves here. Restate the target in `docs/Optimization.md` and
  `docs/FutureFeatures.md` Priority 2 against that peer number rather than the pipe baseline.

  **Exit criteria:** `docs/Optimization.md` headline figures, Machine Profile, and target all
  current; `docs/FutureFeatures.md` Priority 2 checkboxes reconciled with reality (several are
  already done but unticked — see Overview); `CLAUDE.md` throughput line updated.

---

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
