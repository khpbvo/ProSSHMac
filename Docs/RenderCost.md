# RenderCost — measuring what rendering actually costs

**Status:** Phases R0 and R1 complete (2026-09-03). R2 open.

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

- [ ] **Phase R2: Attack the dominant stage**

  The measurements below say where to look. In order of expected value:

  1. **`publish` is 23–25% of wall in every budget, at 4–8.5 ms per call.** In the parser-only
     benchmark it was negligible. `publishGridState` is `@MainActor` and runs once per 4 ms batch.
  2. **Cost scales with window size.** A 149×129 off-screen window measured 2.31 MB/s detached; a
     1100×750 on-screen one measured 0.14 MB/s on the same code path — 16x, with the terminal not
     even visible. The grid is larger, so every snapshot build and publish moves more cells.
     Confirm this is snapshot/publish cost scaling with cell count.
  3. **The MainActor hop per raw chunk** in `recordParsedChunk` (~1290 hops per MB) queues behind
     publishes and draws.
  4. Only then the draw loop, which is cheap per frame (see Results).

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

## Gotchas

- **`--perf-signposts` is not free on this path.** Detached measured 2.81 MB/s with signposts off
  and 0.15 MB/s with them on — ~19x. The parser-only benchmark showed no such effect (Phase 1 of
  `FasterThenYouWillEverLiveToBe` verified that), because the real path crosses far more signpost
  sites. **Only compare signpost-on numbers to other signpost-on numbers.** Signposts remain free
  when off, which is the property that matters for shipping.
- **Window size dominates.** Always record it.
- **`MetalTerminalRenderer.benchmarkInstance` is a strong reference on purpose.** A weak one cannot
  distinguish "surface torn down" from "SwiftUI rebuilt the view", and that distinction is what
  revealed the zero-frame runs above.
- The rendered benchmark takes ~30 s per 1 MB run. Budget accordingly; 2 MB × 3 runs is ~3 minutes.
