# RenderCost — measuring what rendering actually costs

**Status:** Phases R0, R1 and R2a complete (2026-09-04). R2b open.

`FasterThenYouWillEverLiveToBe` ended by retargeting throughput at Terminal.app's **26.5 MB/s**.
That peer figure was measured **with rendering**; ProSSHMac's **17.97 MB/s** was measured **without**
it, through a benchmark that also bypassed the real reader. This spec closes that gap: it measures
the shipping path, in a real window, and attributes the cost.

The headline result is that **rendering is not the expensive part**. See "Results" below.

---

## Overview

### Why the old numbers were not comparable

`--benchmark-pty-local` spawns a bare `LocalShellChannel` and calls `engine.feed(chunk)` per chunk.
The real path does considerably more:

- `SessionShellIOCoordinator.startParserReader` batches chunks into 4 ms windows via
  `ChunkBatchAccumulator`, and hops to the **MainActor** once per raw chunk for `recordParsedChunk`
  (activity, byte counts, `terminalHistoryIndex`, recording).
- `TerminalRenderingCoordinator.publishGridState` builds and publishes a snapshot per batch.
- SwiftUI reacts to the snapshot nonce; `MetalTerminalSessionSurface` forwards it to the renderer.
- `MetalTerminalRenderer.draw(in:)` resolves glyphs, uploads the cell buffer, encodes and presents.

None of that was measured by any existing benchmark.

### Affected files

| File | Role |
|---|---|
| `Terminal/Diagnostics/TerminalPerf.swift` | Stage enum, `record(_:since:)`, new `add(_:nanoseconds:)` |
| `Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift` | Draw-loop stage timers, GPU timing |
| `Terminal/Renderer/RendererPerformanceMonitor.swift` | `recordGPUFrame(seconds:)` |
| `Terminal/Renderer/MetalTerminalRenderer.swift` | `benchmarkInstance` registry |
| `App/ThroughputBenchmarkRunner+Render.swift` | `--benchmark-render` / `--benchmark-render-detached` |
| `Services/SessionShellIOCoordinator.swift` | Benchmark-gated sentinel tap |
| `App/AppDependencies.swift` | Launches the rendered benchmark once the UI is up |
| `scripts/benchmark-throughput.sh` | `--render`, `--render-detached` |

---

## Phases

- [x] **Phase R0: Instrument the draw loop**

  Five stages added to `TerminalPerf`: `drawableWait`, `snapshotApply`, `frameEncode`,
  `gpuExecute`, `drawFrame`. `add(_:nanoseconds:)` accepts a duration rather than a start stamp,
  because Metal reports GPU time only in the command buffer's completion handler — where the real
  `gpuEndTime - gpuStartTime` is now recorded and fed to `RendererPerformanceMonitor.recordGPUFrame`.
  Before this, `averageGPUFrameMs` was always nil: `endFrame` was called with `gpuFrameSeconds: nil`.

  Everything stays behind the existing `TerminalPerf.isEnabled` gate.

- [x] **Phase R1: `--benchmark-render` end-to-end mode**

  Opens a real local session through `SessionManager.openLocalSession`, floods it with the same
  `dd | base64` payload and split sentinel as the PTY-local mode, and times it. Two modes:

  - `--render` — terminal tab visible, Metal surface attached.
  - `--render-detached` — identical path, parked on `.hosts`, so nothing renders.

  Two times are recorded per run: **to sentinel** (parser consumed everything) and **to settled**
  (renderer drained too). Stopping at the sentinel would make rendering look free.

  Three things had to be solved to get a trustworthy number, each of which silently produced a
  wrong one first:

  1. **Launching the binary directly yields a process with zero windows.** Rendered runs must go
     through LaunchServices (`open -n`), which detaches stdout — hence `--benchmark-out`, polled by
     the script. `benchmark-peer-emulator.sh` already had this problem and solves it the same way.
  2. **Restored window state can be degenerate.** On this machine it came back as 149×129 at
     x=-234, entirely off-screen: no surface to render into, no key window. `prepareWindow` forces
     a 1280×800 on-screen frame and makes it key. This matters enormously — see Results.
  3. **Reopening the session per run** left the surface bound only for run 1, so runs 2+ drew zero
     frames while looking identical in the output. One session is now shared across runs.

  A key window is not cosmetic: `MetalTerminalSessionSurface.updateFPS` drops an unfocused surface
  to 30 FPS.

- [x] **Phase R2 (superseded by R2a below): Attack the dominant stage**

  The ranking written here from R1's data — `publish` first, window-size scaling second, the
  per-chunk MainActor hop third — was measured in a configuration R2a could not reproduce, and
  every item in it was wrong about magnitude. Kept for the record; act on R2a/R2b instead.

- [x] **Phase R2a: Attribute the missing wall time, and remove the per-chunk cost**

  R2's ranking above was wrong on every count, and R2a's instrumentation says why. Ranked item 1
  (`publish` at 23-25%) measured **0.3%** here; ranked item 3 (the per-chunk MainActor hop) turned
  out to matter enormously, but for the work it carried rather than the hop itself.

  **What was added**

  Seven stages — `chunkRecord`, `historyIndex`, `feedCall`, `batchFollowUp`, `publishEngineWait`,
  `publishHousekeeping`, `visibleTextScan` — several deliberately paired with an existing
  callee-side stage, so that `feedCall` minus `parse` and `publish` minus `publishEngineWait` are
  the actor hop and queue wait rather than the work.

  `TerminalPerf` also tracks a **span** (first start to last end) and **busy%** (time / span) per
  stage. Summed durations alone cannot separate a stage that is blocked from one that never ran,
  which is exactly why ~18 s of R1's 31.6 s run was unattributable. `--benchmark-window WxH` forces
  the frame, because R1's own lesson was that window size moves the result by more than 10x and so
  must be an input rather than whatever the app restored.

  **Where the time actually goes** (Release, 8 MB payload, idle machine, no window — see the
  measurement caveat below; wall 3968 ms)

  | Stage | Time | % wall | Busy | Calls |
  |---|---|---|---|---|
  | chunk record | 3704.87 ms | **93.4%** | 98.6% | 10595 |
  | history index | 3541.18 ms | **89.2%** | 94.3% | 10595 |
  | feed call | 263.54 ms | 6.6% | 7.0% | 2718 |
  | parse + grid | 256.41 ms | 6.5% | 6.8% | 2718 |
  | publish | 12.68 ms | 0.3% | 0.3% | 254 |
  | pty read | 29.76 ms | 0.7% | 29.0% | 10595 |

  Two things fall out of the span column immediately:

  1. **`pty read` spans 103 ms of a 3968 ms run.** All 10.67 MB is read off the PTY in the first
     tenth of a second and then sits in the unbounded `AsyncStream`. Every rendered "MB/s" figure in
     this spec measures how fast the app *digests* a backlog, not how fast it reads.
  2. **`history index` is 96% of `chunk record`.** `TerminalHistoryIndex.recordOutputChunk` ran once
     per raw chunk (~1290/MB) and, past its 120,000-character cap, paid four O(n) passes over the
     whole buffer every time: a copy-on-write of the string (the `var state = sessionStates[id]`
     copy left it doubly referenced), two grapheme-cluster `count`s, and an O(n) `removeFirst`.

  **What was fixed**

  - `ActiveCommandContext` keeps raw output as UTF-8 bytes. Length is O(1), the trim is amortized
    (run to 2x the cap, drop back to it, realign to a UTF-8 lead byte), and the character cap is
    applied at read time — once per command completion, where `finalizeActiveCommand` already
    applied it. The retained window is unchanged; `hasOutput` becomes a byte-level test, so non-ASCII
    whitespace such as U+00A0 now counts as output.
  - `recordParsedChunk` moved from per raw chunk to per 4 ms batch: ~1290 MainActor hops per MB
    become ~30. Everything it does concatenates, and batching also fixes a latent defect, since a raw
    chunk can split a UTF-8 sequence that the history index decodes.

  `history index` fell from **3541 ms (89.2% of wall) to 510 ms (12.2%)**.

  **Throughput improved, but the bottleneck simply moved.** Single runs taken minutes apart said the
  fix changed nothing; they were confounded by background load. An interleaved A/B of the two
  binaries — HEAD vs fixed, alternating launches so both saw the same load, 8 MB, 3 runs each,
  signposts off — favours the fixed build in **every** pair:

  | Pair | Load avg | HEAD (MB/s) | Fixed (MB/s) |
  |---|---|---|---|
  | 1 | 10.1 / 11.6 | 0.13, 0.07, 0.11 | 1.60, 18.94, 0.20 |
  | 2 | 9.3 / 7.4 | 0.27, 0.27, 0.11 | 0.45, 0.35, 3.15 |
  | 3 | 4.8 / 4.7 | 1.20, 1.04, 1.08 | 3.81, 3.13, 1.23 |

  Per-launch medians: **0.11 / 0.27 / 1.08 against 1.60 / 0.45 / 3.13** — roughly 3x at the lowest
  load and more as contention rises, which is what removing ~1250 MainActor hops per MB should look
  like. Absolute values are not comparable across pairs; only within one.

  With the per-chunk cost gone, stages that had been invisible now dominate (Release, 8 MB, load ~4,
  no window, wall 4252 ms — the most stable run of the session at 2.70/2.67/2.64 MB/s):

  | Stage | Time | % wall | Busy | Calls |
  |---|---|---|---|---|
  | batch follow-up | 1984.54 ms | **46.7%** | 49.3% | 1251 |
  | publish housekeep | 1378.66 ms | 32.4% | 34.3% | 713 |
  | publish | 1130.90 ms | 26.6% | 28.1% | 720 |
  | publish engine wait | 1124.82 ms | 26.5% | 28.0% | 1440 |
  | feed call | 1063.36 ms | 25.0% | 26.4% | 1251 |
  | parse + grid | 1033.15 ms | 24.3% | 25.7% | 1251 |
  | chunk record | 946.61 ms | 22.3% | 23.5% | 1251 |
  | history index | 494.58 ms | 11.6% | 12.3% | 1251 |
  | pty read | 237.43 ms | 5.6% | 50.9% | 4013 |

  `batchFollowUp` is the four cross-actor round-trips `startParserReader` makes after every
  `engine.feed` — `refreshInputModeSnapshot`, `consumeSyncExitSnapshots`, `synchronizedOutput` and
  `scheduleParsedChunkPublish` (which awaits `usingAlternateBuffer` again). `publish` is 99%
  `publishEngineWait`: not working, queueing. (`publish housekeep` exceeds `publish` because the
  publish drain loop calls `publishHousekeeping` directly, outside `publishGridState`'s own timer —
  which is why that timer lives inside the function rather than at the call site.)

  **The real bottleneck is cross-actor round-trip count, not the work at either end.** That is R2b.

- [ ] **Phase R2b: Coalesce the per-batch and per-publish engine round-trips**

  Sized by R2a, in order:

  1. `startParserReader`'s four post-feed round-trips (`batchFollowUp`, 47% of wall) fold into what
     `engine.feed` returns: input-mode snapshot, sync-exit snapshots, synchronized-output flag and
     alternate-buffer flag in one `FeedOutcome`.
  2. `publishGridState`'s engine awaits (`publishEngineWait`, ~99% of `publish`) coalesce into one
     composite call: scrollback count, alternate-buffer flag, snapshot, bell count, input mode,
     title and working directory. Covered by 21 `SessionManagerRenderingPathTests`.
  3. `publishHousekeeping` (32% of wall) makes five more engine round-trips of its own — bell count,
     input mode, window title, working directory, and `visibleText` — and is called both from
     `publishGridState` and directly from the publish drain loop. It coalesces into the same
     composite call as item 2.
  4. Also open: throughput is **bimodal** under load. One run in the A/B reached 18.94 MB/s while its
     neighbours in the same launch managed 0.20 — a 90x spread with no code change. The burst-mode
     and debounce logic in `scheduleCoalescedGridPublish` is the obvious suspect for a feedback loop
     and should be examined once the round-trip count is down.

---

## Results (Release, 2026-09-03, 1 MB payload, `/bin/sh`)

All rendered figures use a 1100×750 active key window. **State the window size with any rendered
number** — it changes the result by more than 10x.

| Path | Rendering | MB/s |
|---|---|---|
| Parser/grid only (`--benchmark-base64`) | none | **36.44** |
| PTY → `engine.feed` (`--pty-local`) | none | **19.20** |
| Real app path, hosts tab (`--render-detached`) | none | **0.14** |
| Real app path, terminal tab (`--render`) | full | **0.03–0.05** |
| Terminal.app (peer, its own window) | full | **26.5** |

Per-frame renderer cost, from the same runs: ~3000 frames per run at 74–83 fps, **CPU avg
3.76–5.91 ms**, **GPU avg 1.02–1.11 ms**, glyph cache hit rate **100%**.

### The Metal draw loop is not the bottleneck

Before the shared-session fix, runs 2 and 3 drew **zero frames** — the surface was unbound — and
still measured 0.06–0.07 MB/s, statistically indistinguishable from run 1's 0.03 MB/s with 2987
frames drawn. Whatever costs ~40x between the hosts tab and the terminal tab is **upstream of
`draw(in:)`**, in the publish → SwiftUI → surface path.

The stage budget agrees. From a rendered run (wall 31.6 s):

| Stage | Time | % wall | Calls |
|---|---|---|---|
| publish | 7290.46 ms | 23.1% | 880 |
| gpu execute | 3684.14 ms | 11.7% | 2902 |
| draw frame | 1670.52 ms | 5.3% | 2903 |
| drawable wait | 1087.14 ms | 3.4% | 2903 |
| frame encode | 467.26 ms | 1.5% | 2903 |
| snapshot apply | 82.88 ms | 0.3% | 2903 |
| cell buffer | 79.45 ms | 0.3% | 596 |
| **parse + grid** | **40.93 ms** | **0.1%** | 971 |
| snapshot build | 8.63 ms | 0.0% | 880 |
| pty read / handoff / sanitize | 13.69 ms | 0.0% | — |

`parse + grid` — the stage `FasterThenYouWillEverLiveToBe` Phase 4 proposed optimising next — is
**0.1% of wall** on the real path. Phase 4 would have been a rounding error.

Note the stages sum to well under the wall time: the remaining ~18 s is time the pipeline spends
waiting, not working. That gap is itself the R2 target.

---

## Measurement caveats found in R2a (2026-09-04)

**The rendered benchmark could not obtain a window at all on this machine.** Every R2a figure was
measured in a process with **zero windows** (`NSApp.windows.count == 0`), so the grid kept its
default geometry and nothing rendered — `--benchmark-render` degraded to `--benchmark-render-detached`
and said so. The cause is LaunchServices, not the app: `open -n ProSSHMac.app` restores a window,
while `open -n ProSSHMac.app --args <anything at all>` produces a process that never materializes
one. A harmless unused flag reproduces it. `applicationShouldHandleReopen` does not recover it.
The runner now emits an explicit warning when a run has no windows, since a windowless number looks
exactly like a windowed one in the output.

Consequences:

- R1's rendered figures (0.14 detached / 0.03-0.05 rendered at 1100x750) **could not be reproduced**
  and R2a's are not comparable to them. R2a's own numbers are internally consistent.
- The window-size scaling claim and the rendered-vs-detached delta could not be tested this session.
  Whoever restores window acquisition should retest both.

**The `--perf-signposts` "~19x" gotcha did not reproduce.** Detached, same binary, back to back:
**2.78 MB/s with signposts on, 2.86 MB/s off** — within noise. Note that the previously recorded
"signposts off" figure of 2.81 MB/s is almost exactly R2a's windowless measurement, which suggests
that pair differed by window state rather than by signposts. Treat the 19x as unfounded.

**Background load dominates everything.** A `mediaanalysisd` pass (300% CPU, load average 6-17)
made the identical binary measure 7x slower — 4.2 s vs 30.5 s wall for the same 8 MB — and produced
run-to-run spreads of 100x within one launch. Check `sysctl -n vm.loadavg` and the top CPU consumers
before trusting any rendered number, record the load with the result, and prefer interleaved A/B
runs of two binaries over comparing numbers taken minutes apart.

**Rendered MB/s is a digest rate, not an I/O rate.** `pty read` spans ~100-400 ms of a multi-second
run: the payload is read off the PTY almost immediately and buffered in an unbounded `AsyncStream`.
The figure measures how fast the app drains that backlog.

---

## Gotchas

- ~~**`--perf-signposts` is not free on this path.**~~ Recorded here as ~19x (2.81 MB/s off vs 0.15
  on). **R2a could not reproduce it** — 2.78 on vs 2.86 off, back to back on one binary. See
  "Measurement caveats found in R2a". Signposts are free when off either way, which is the property
  that matters for shipping.
- **Window size dominates.** Always record it — and record whether there was a window at all
  (R2a's runs had none; see the caveats section). `--benchmark-window WxH` forces the frame.
- **`MetalTerminalRenderer.benchmarkInstance` is a strong reference on purpose.** A weak one cannot
  distinguish "surface torn down" from "SwiftUI rebuilt the view", and that distinction is what
  revealed the zero-frame runs above.
- The rendered benchmark takes ~30 s per 1 MB run. Budget accordingly; 2 MB × 3 runs is ~3 minutes.
