# RenderCost — measuring what rendering actually costs

**Status:** R0, R1, R2a and R2b complete. R2b was validated on 2026-10-23: **1.09-1.12x**
in every interleaved pair (instrumentation off, active app, no window). The "bimodal"
variability was App Nap on inactive benchmark processes plus CPU oversubscription. See
"Measurement caveats found in R2b". R3a (render benchmarks prevent App Nap) is done. R3b
(2026-10-23) found that window acquisition works from an unsandboxed shell, and that **a
window makes the real app path about 10x slower even when nothing is drawn** (~2 MB/s
detached against ~20 windowless). **R3c (2026-10-23) found why:** with a window, SwiftUI
view-graph updates take ~79% of a saturated main thread, because every output batch and publish
writes `@Published` state on `SessionManager`; Metal drawing is 2.2%. Windowed baseline at
1280x800: detached 1.75-2.08, render 0.14-0.16 MB/s, independent of window size; Terminal.app
30.8-34.8. **R4 (stop high-frequency state from invalidating views) is next**; R3d follows.

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

  **Throughput improved by ~4.3x, but the bottleneck simply moved.** Single runs taken minutes apart
  said the fix changed nothing; they were confounded by background load. The trustworthy measurement
  is an interleaved A/B of the two binaries — HEAD~1 vs R2a, alternating launches so both see the
  same conditions, 8 MB, 3 runs each, signposts off, no window. On a quiet machine:

  | Pair | Load avg | HEAD~1 (MB/s) | R2a (MB/s) |
  |---|---|---|---|
  | 1 | 2.45 / 2.04 | 1.05, 0.92, 0.79 | 3.95, 3.80, 4.23 |
  | 2 | 2.03 / 2.15 | 1.10, 0.79, 0.96 | 5.01, 3.94, 3.80 |
  | 3 | 2.48 / 2.36 | 0.88, 0.93, 0.76 | 4.29, 3.97, 3.86 |

  The two ranges do not overlap: every baseline run falls in **0.76-1.10**, every fixed run in
  **3.80-5.01**. Medians **0.92 vs 3.95 — 4.3x**, and the slowest fixed run beats the fastest
  baseline run by 3.4x.

  The same experiment run earlier under heavy load (load 7-12) gave the same direction with far more
  scatter — per-launch medians 0.11/0.27/1.08 against 1.60/0.45/3.13 — so contention widens the gap
  but also destroys precision.

  **Only within-pair ratios are trustworthy.** The identical baseline binary measured 2.86 MB/s early
  in the session and 0.92 MB/s hours later at a comparable load average, so absolute figures drift
  across a long benchmarking session (thermal state is the likely cause). Never compare a number to
  one taken at a different time; interleave.

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

- [x] **Phase R2b: Coalesce the per-batch and per-publish engine round-trips**

  **Implementation update (2026-09-06/07; validated 2026-10-23):**

  - [x] Coalesce parser follow-up reads and MainActor handoff.
  - [x] Coalesce publish reads, preserving MainActor scroll policy and drain semantics.
  - [x] Re-examine visible-text work: still small; no further optimization warranted.
  - [x] Debug/Release builds and focused regressions.
  - [x] Explain or bound variability and establish a repeatable performance result.

  **Validation (2026-10-23).** `af933f4` vs `c685d73` (the R2b commit), four interleaved
  pairs, Release, instrumentation off, active app, no window: median ratios **1.11x, 1.11x,
  1.09x, 1.12x**, with no overlap between the ranges (18.11-18.69 vs 19.88-20.76 MB/s). Under
  App Nap, R2b still wins 1.24x / 1.23x. On a quiet machine, 18 instrumented HEAD runs across
  six launches fell within 20.07-20.91 MB/s. The September evidence below mixed two causes of
  slowness and recorded neither:

  - **App Nap.** A windowless, inactive process (any direct binary launch, or an `open -n`
    launch after the user switches apps) runs at ~5 MB/s. Same QoS and still mostly running,
    but about 3x the CPU time per byte. `-NSAppSleepDisabled YES` alone restores ~20 MB/s.
  - **Oversubscription.** With 16 busy loops on 10 cores, one run fell to 0.65 MB/s at 4.5%
    CPU/elapsed: the thread was preempted mid-work. Burst transitions and large batches
    follow from that; they don't cause it, and the publish cadence needs no tuning.

  Full tables: [R2bBenchmarkResults.md](R2bBenchmarkResults.md), "2026-10-23 follow-up".

  The September record follows unchanged.

  Three interleaved Release pairs with timers on gave median to-sentinel ratios
  **5.01x, 0.33x, 1.02x**. Three direct-launch pairs with timers off gave **0.88x,
  0.29x, 0.87x**. All launches had zero windows, so no rendered claim is supported.
  The direct controls also favor the baseline; **a performance regression cannot be
  ruled out**. Do not call R2b a proven optimization or close it yet. Complete commands,
  all pair medians, host load and raw reports are in [R2bBenchmarkResults.md](R2bBenchmarkResults.md).

  Within one unchanged candidate launch, parse/grid elapsed time rose from 268.69 ms
  to 780.42 ms while throughput fell from 19.74 to 5.88 MB/s. Next diagnostic: compare
  thread CPU with wall time around synchronous ground-text/grid work (never across an
  async suspension), correlated with burst transitions, batch sizes and process/host
  activity. The cause is not established; avoid speculative debounce tuning.

  **Architecture implemented:**
  `feedAndCollectOutcome(Data)` wraps the existing Bool-returning `feed`, preserving
  its queueing contract and leaving other callers non-consuming. The streaming reader
  receives modes, sync-exit frames, alternate-buffer state and an optional live sync
  fallback frame together, then applies them in one MainActor handoff.

  Publishing uses `publishViewportState` followed by `publishSnapshot`: scroll policy
  remains between those calls on MainActor. Ordinary publishes include housekeeping
  in the second result. The drain loop skips housekeeping for intermediate frames and
  collects it in one separate engine call after the final snapshot, preserving bell
  delivery and visible-text throttling. Captured metadata is applied before awaiting
  history observation, so that await cannot let old modes overwrite a newer feed.

  `visibleTextScan` now sums two separately timed operations: engine text extraction
  and MainActor/history observation. Its call count can therefore be twice the number
  of text refreshes; it no longer includes the old standalone visible-text actor wait.
  `feedCall` now includes outcome collection; ordinary-publish housekeeping collection
  is included in `publishEngineWait`. Drain housekeeping retains its own outer timer.

  Debug build and focused tests pass: 167 tests, 0 failures, 2 instrumentation-only
  skips (21 rendering, 125 parser, 8 history, 7 perf, 6 benchmark).

  Every figure below is from the final R2a run (Release, 8 MB, load ~4, no window, wall 4252 ms).

  **1. `startParserReader`'s post-`feed` round-trips — `batchFollowUp`, 46.7% of wall, ~1.6 ms/batch.**
  `Services/SessionShellIOCoordinator.swift`, in the parser task loop after `await engine.feed(batch)`:

  | Call | Hop |
  |---|---|
  | `renderingCoordinator.refreshInputModeSnapshot` | MainActor, then `engine.inputModeSnapshot()` |
  | `engine.consumeSyncExitSnapshots()` | engine |
  | `engine.synchronizedOutput` | engine |
  | `renderingCoordinator.scheduleParsedChunkPublish` | MainActor, then `engine.usingAlternateBuffer` |

  Fold them into what `feed` already returns. `TerminalEngine.feed(_ data: Data)` has a `-> Bool`
  overload precedent; return a `FeedOutcome` carrying `inputModeSnapshot`, `syncExitSnapshots`,
  `synchronizedOutput` and `usingAlternateBuffer` instead. Four round-trips become zero.

  **2. `publishGridState` / `publishHousekeeping` — `publishEngineWait` is 99% of `publish`;
  housekeeping alone is 32.4% of wall.** `Services/TerminalRenderingCoordinator.swift`, seven engine
  awaits per publish: `scrollbackCount`, `usingAlternateBuffer`, `snapshot(...)`, then in
  housekeeping `visibleText()`, `consumeBellCount()`, `inputModeSnapshot()`, `windowTitle`,
  `workingDirectory`. Coalesce into one composite actor call returning all of it.

  Two things constrain the shape. The scroll-anchor arithmetic between the first two reads and the
  snapshot is MainActor policy over MainActor state, so either split into two calls (read state →
  resolve offset → snapshot + housekeeping) or pass the prior offset in and return the resolved one;
  do not move scroll policy into the engine. And `publishHousekeeping` is called both from
  `publishGridState` and directly from the publish drain loop — that is why its timer lives inside
  the function, and why a naive caller-side coalesce would miss the path that runs under load.

  Covered by 21 `SessionManagerRenderingPathTests`; all 21 were green on 2026-09-04.

  **3. Then re-examine `visibleTextScan`** (1.9%, 19 calls, throttled to 30/s) — likely fine.

  **4. ~~Open question: throughput is bimodal under load.~~** Answered 2026-10-23: App Nap and
  CPU oversubscription, not the debounce logic (see Validation above). One A/B run reached 18.94 MB/s while its
  neighbours in the same launch managed 0.20 — a 90x spread, no code change. The burst-mode and
  debounce logic in `scheduleCoalescedGridPublish` (8/16/24/40 ms intervals, `burstThreshold` 3 in a
  16 ms window, 200 ms revert) is the obvious candidate for a feedback loop. Investigate after the
  round-trip count is down, since that changes the timing that drives it.

  **How to verify.** Do not compare against any number in this document taken on another day — see
  "Measurement caveats". Build the current `HEAD` and your branch into two `.app` bundles, then
  alternate launches:

  ```bash
  ./scripts/benchmark-throughput.sh --configuration Release --no-build --render-detached \
      --benchmark-window 1280x800 --benchmark-bytes 8388608 --benchmark-runs 3 --perf-signposts
  ```

  Expect `batchFollowUp` and `publishEngineWait` to collapse, and check what takes their place before
  claiming a win — R2a's lesson is that removing the top stage moves the bottleneck rather than
  eliminating it. Targeted suites: `SessionManagerRenderingPathTests`, `TerminalPerfTests`,
  `TerminalHistoryIndexTests`, `ThroughputBenchmarkRunnerTests`.

- [x] **Phase R3a: Render benchmarks are immune to App Nap and always report activation**

  **Done 2026-10-23.** Release, windowless, 8 MiB, 3 runs per launch, load 2.2-2.9,
  alternating launches over two rounds:

  | Launch | active | MB/s to sentinel |
  |---|---|---|
  | Direct binary, default (activity held) | false | 20.02-21.34 |
  | Direct binary, `--benchmark-allow-app-nap` | false | 2.20-5.81, WARNING on every run |
  | `open -n`, default | true | 20.40-20.88 |

  A default direct launch with `--perf-scheduling` used 217.7-226.3 ms of ground CPU
  (98.6-98.8% of elapsed), the same as an active app. `.userInitiated` was enough, so
  `.latencyCritical` was not needed. `ThroughputBenchmarkRunnerTests` 8/8.

  An inactive windowless render run is napped and measures ~5 MB/s instead of ~20, with no
  sign in the report unless `--perf-scheduling` is on. The parser (`--benchmark-base64`) and
  PTY-local modes are **not** affected: measured with App Nap on and off on 2026-10-23, they
  gave 35.0-35.6 / 18.1-18.5 MB/s either way, since they exit before the UI starts.
  `ThroughputBenchmarkRunner+Render` holds a `ProcessInfo` activity for the whole benchmark
  (opt out with `--benchmark-allow-app-nap` to measure the napped regime on purpose). It
  prints the activity state in the header and `active=` on every run, whatever the
  instrumentation. Verify: a direct binary launch (always inactive) measures what an
  `open -n` launch does, and the opt-out reproduces ~5 MB/s.

- [x] **Phase R3b: Root-cause and fix window acquisition under `open -n --args`**

  **Closed 2026-10-23: not reproducible, no code fix needed.** From an unsandboxed Claude Code
  shell, every launch got one active key window (`window: active=true count=1`): Debug and
  Release; `open -n` with no arguments, an unused `--foo`, and the real benchmark flags;
  `--benchmark-render` and `--benchmark-render-detached`; with and without
  `--benchmark-window` and `--perf-signposts`; a direct binary launch (which R3a recorded as
  always inactive and windowless); and with a second ProSSHMac instance already running. The
  bundle has no Saved Application State folder. `--benchmark-window 1280x800` was applied
  (`frame=1280x800@120,120 (forced)`).

  So R2a, R2b and R3a got zero windows because of how those sessions launched the app, not
  because of the arguments or the code. **(R3c refuted this lead: a launch from the sandboxed
  shell got a window too. The cause of the earlier zero-window runs is unknown.)** Lead at the time: those sessions ran inside Claude
  Code's Bash sandbox (R2b's notes record sandboxed signing failing). A `sandbox-exec` profile
  that only denies file writes outside the temp folders still produced a window on a direct
  launch, so if the sandbox is the cause it is another of its restrictions (Mach lookups are
  the likely one). Confirming needs a run with the sandbox on. **Rule:** run render
  benchmarks from an unsandboxed shell and check `window: count=` in every report. The
  runner's windowless WARNING stays.

  **What a window costs (first look, not a baseline).** Release, 8 MiB, 3 runs,
  `--render-detached` (parked on Hosts), 1280x800, App Nap held, load 2.0-2.6:
  **1.53 / 2.08 / 2.01 MB/s**, against 20.07-21.34 windowless in R2b/R3a. `--render`, 1 MiB,
  one run: 0.12-0.15 MB/s (the 1100x750 restored-frame run drew 436 frames at ~32 fps and
  warned of an unfocused surface). Not interleaved; the process went inactive during run 1
  of the 8 MiB launch. The September R1 figures (0.14 detached, 0.03-0.05 rendered, 1100x750)
  were the right order of magnitude after all; R2a-R3a never measured the windowed path.

- [x] **Phase R3c: First windowed baseline, and what a window costs when nothing draws**

  **Done 2026-10-23. No code changes.** Evidence, commands and deviations:
  `Docs/R3cBenchmarkResults.md`. Release `6b6de2a`, 8 MiB x 3, App Nap held, load 1.5-5.7.

  | Path | MB/s to sentinel |
  |---|---|
  | `--render-detached`, 1280x800 (3 interleaved pairs) | 1.75-2.08 |
  | `--render`, 1280x800 (~88-94 fps; Metal CPU 0.5-1.3 ms, GPU 1.2-2.0 ms per frame) | 0.14-0.16 |
  | both modes, 640x400 / 800x500 / 1480x893 | 1.73-2.17 / 0.13-0.17 |
  | Terminal.app peer, 8 MB | 30.8-34.8 |

  - **Window size makes no difference** in either mode, from 640x400 to 1480x893 (2560x1440
    doesn't fit the 1496x967-point screen). The old ">10x with cell count" came from comparing
    windowed with windowless runs.
  - **Activation makes no difference while the App Nap activity is held**: inactive launches
    measured what active ones did. The user worked in other apps for most of 1b and 2.
  - **The sandbox lead from R3b is refuted**: a launch from Claude Code's sandboxed shell got a
    window as well. No windowless launch exists without a code change.
  - **Attribution (Time Profiler, both windowed modes):** the main thread is 100% busy, and about
    78-79% of it is SwiftUI view-graph updates (`NSHostingView.beginTransaction` →
    `GraphHost.flushTransactions`). That covers view bodies (36% detached, 29% render), a
    `List`'s `OutlineListCoordinator.update` (19% detached), layout and CA commits.
    `MetalTerminalRenderer.draw(in:)` is 2.2% in render mode; the app's own MainActor
    bookkeeping (`recordParsedChunk`, `handleFeedOutcome`) is under 2%.
  - **Mechanism.** The parser task hops onto the MainActor twice per ~4 KB batch. Each batch
    writes `@Published bytesReceivedBySessionID`. Each publish writes the snapshot nonce, plus
    `scrollStateBySessionID`, `inputModeSnapshotsBySessionID` and title/cwd
    unconditionally. All share `SessionManager.objectWillChange`, which ~11 views observe
    (`HostsView`, `TerminalView`, tab bar, metadata, actions bar, sidebar…). Each MainActor job
    is followed by a full SwiftUI transaction, so throughput ≈ batch size / view-update cost.
  - **The stage budget misleads here:** `chunk record` (~26x, 4.06 s) and `history index`
    (~21x, 2.0 s) are timed around awaits that include **waiting for the main thread**, not
    work. Ground parse stayed at 99.4% CPU/elapsed.

- [ ] **Phase R4: High-frequency terminal state stops invalidating SwiftUI views**
  (proposed by R3c; split R4a/R4b, one session each)

  **Goal.** Output streaming must not re-run views that don't show the changed value. Target:
  windowed `--render-detached` close to the windowless ~20 MB/s, and `--render` limited by
  snapshot and draw cost, not SwiftUI.

  - **R4a: stop needless and per-batch publishes (small, measurable on its own).**
    1. `bytesReceivedBySessionID` / `bytesSentBySessionID`: move the counters to plain storage
       and publish a coalesced copy at most every ~250 ms (or only where a view reads it:
       `SessionManager+Queries` traffic summary → metadata view). Check every reader first,
       including `SessionShellIOCoordinator.swift:94` and the benchmark runner.
    2. In publish housekeeping, write `scrollStateBySessionID`, `inputModeSnapshotsBySessionID`,
       `windowTitleBySessionID` and `workingDirectoryBySessionID` only when the value changed
       (add `Equatable` where a type lacks it).
    3. Measure: interleaved windowed A/B (HEAD vs candidate, 1280x800, detached and render) plus
       one Time Profiler capture each. Report the main thread's SwiftUI share, not just MB/s.
  - **R4b: per-session live state out of `SessionManager.objectWillChange` (structural).**
    The snapshot nonce, scroll state and `shellBuffers` change at publish cadence. Give them a
    per-session observable (the surface model `MetalTerminalSurfaceModel`, or a small
    `SessionLiveState`), so only the surface, scrollbar and search views observe them. The
    nonce feeds `.onChange` → `MetalTerminalRenderer.updateSnapshot()` today, so keep that
    contract and the Bug 84 surface-model rules. Audit each `@EnvironmentObject`
    `SessionManager` view for what it actually reads.
  - **Don't:** lengthen the publish cadence or batch window to hide this (R2b's lesson), or
    move the history-index/chunk work off the MainActor before the SwiftUI cost is gone. The
    profile says that work is under 2% of the main thread.
  - **Tests:** `SessionManagerRenderingPathTests`, `TerminalSurfaceIdentityTests`,
    `TerminalSurfaceModelStoreTests`, `TerminalHistoryIndexTests`,
    `ThroughputBenchmarkRunnerTests`, plus a test that unchanged housekeeping does not emit
    `objectWillChange`.

- [ ] **Phase R3d: Does App Nap slow a real hidden window?** (after R3c)

  Measure a windowed session streaming output while the window is visible, occluded,
  minimized and hidden, active and inactive. Only if a hidden session's output falls behind,
  propose holding an activity while output streams (the user decides; it costs energy).

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
and said so. (R3b could not reproduce this from an unsandboxed shell; the explanation that
follows did not hold up. See R3b.) At the time: `open -n ProSSHMac.app` restored a window,
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

## Measurement caveats found in R2b (2026-10-23)

**App Nap decides the regime for windowless runs.** An inactive process with no visible
window is napped and digests output about 3.6x slower: ~5 MB/s against ~20, with about 3x
the CPU time for the same ground-text work. A direct binary launch is always inactive. An
`open -n` launch is active until the user switches apps. **Since R3a, both render modes
prevent App Nap by default.** The report prints `app nap:` in its header and
`process before/after: active=` on every run. To measure the napped regime on purpose, pass
`--benchmark-allow-app-nap`. Runs before R3a that recorded no activation state may be napped;
never compare across regimes.

**Oversubscription preempts the parser mid-work.** With more runnable threads than cores,
the CPU/elapsed ratio around synchronous ground-text work falls (4.5% at load 14) and a run
can drop 30x. Burst-mode transitions and batch sizes are downstream symptoms. A load
average of 3-5 from ordinary background activity did not reproduce this.

This may matter for the product as well as the benchmark. A ProSSHMac window that is hidden
or occluded while output streams is also eligible for App Nap. Not yet measured with a real
window.

---

## Gotchas

- ~~**`--perf-signposts` is not free on this path.**~~ Recorded here as ~19x (2.81 MB/s off vs 0.15
  on). **R2a could not reproduce it** — 2.78 on vs 2.86 off, back to back on one binary. See
  "Measurement caveats found in R2a". Signposts are free when off either way, which is the property
  that matters for shipping.
- **Whether there is a window dominates; its size does not.** R3c measured no size effect
  from 640x400 to 1480x893 in either mode, while a window at all costs ~10x. Record both the
  frame and `window: count=`. `--benchmark-window WxH` forces the frame (clamped to the screen).
- **`chunk record` and `history index` include MainActor wait.** They are timed around awaits
  from the detached parser task, so when the main thread is busy they grow without any extra
  work (R3c). Profile the main thread before optimizing either.
- **`MetalTerminalRenderer.benchmarkInstance` is a strong reference on purpose.** A weak one cannot
  distinguish "surface torn down" from "SwiftUI rebuilt the view", and that distinction is what
  revealed the zero-frame runs above.
- The rendered benchmark takes ~30 s per 1 MB run. Budget accordingly; 2 MB × 3 runs is ~3 minutes.
