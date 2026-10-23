# R4a benchmark results (2026-10-23)

Evidence for `Docs/RenderCost.md` Phase R4a: stop per-batch and needless `@Published` writes on
`SessionManager`. Baseline: Release build of HEAD `697e6f1` (a detached worktree). Candidate: the
same tree plus the R4a change. M1 Max, macOS 26.6.2, Xcode 27.0. Every launch: 8 MiB x 3 (unless
noted), window forced to 1280x800, App Nap held (`app nap: prevented`), `window: count=1`.

## Interleaved A/B, instrumentation off

MB/s to sentinel (the runner counts 10.67 MB on the wire per 8 MiB payload).

| Pair | Order | Baseline | Candidate | Load (1 min) |
|---|---|---|---|---|
| D1 `--render-detached` | base, cand | 1.88 / 1.87 / 1.92 | 17.93 / 17.47 / 18.07 | 4.8, 4.6 |
| D2 `--render-detached` | base, cand | 1.74 / 1.95 / 1.95 | 15.94 / 18.26 / 18.92 | 8.3, 8.5 |
| D3 `--render-detached` | cand, base | 2.05 / 2.11 / 2.08 | 17.58 / 17.80 / 18.43 | 12.0, 10.4 |
| R1 `--render` | base, cand | 0.15 / 0.17 / 0.16 | 7.76 / 4.57 / 5.44 | 9.2, 2.9 |
| R2 `--render` | cand, base | 0.15 / 0.16 / 0.16 | 4.21 / 4.78 / 6.00 | 4.1, 2.3 |

- **Detached: 1.74-2.11 → 15.94-18.92 MB/s (~9x)**, close to the windowless 20.07-20.91.
- **Render: 0.15-0.17 → 4.21-7.76 MB/s (25-50x)** to sentinel, with more run-to-run spread.
- D2/D3 ran at load 8-12 (`fileproviderd`, `spindump`, `bird` at 60-113% CPU); their ranges match
  D1's. The user worked in iTerm2 throughout, so most runs were inactive (28 of 30
  `process before: active=false`), which doesn't matter while the App Nap activity is held (R3c).

### "To settled" in `--render` is a timeout, not a measurement

Every candidate render run settles exactly ~10.5 s after its sentinel: 10.67 MB / 7.76 = 1.37 s
vs / 0.90 = 11.86 s, and so on. That is `waitForRendererSettled`'s cap (200 x 50 ms plus
overhead). The signposted run shows why: the publish stages end at ~2.2 s, but `draw frame`
spans 12.6 s (404 frames from 72 cell-buffer updates, ~32 fps). The renderer keeps drawing
after output and publishing have stopped, so the settle condition never holds. The baseline has
the same ~10 s tail inside its ~65 s runs. The user's scanner and gradient effects are off, so
neither explains it; cursor lerp, smooth scroll and the glyph re-raster loop are unchecked.
**Use the sentinel figure for `--render` until this is explained.** If a real session also
keeps drawing for 10 s or more after output ends, that's an energy bug.

## Stage budgets (signposts on, run 3 of 3)

| Stage | Baseline detached (2.10 MB/s) | Candidate detached (18.22) | Candidate render (4.94) |
|---|---|---|---|
| chunk record | 4177 ms, span 5069 | 141 ms, span 578 | 594 ms, span 2144 |
| history index | 2048 ms | 91 ms | 339 ms |
| feed call | 266 ms | 270 ms | 277 ms |
| batch follow-up | 610 ms | 150 ms | 1258 ms |
| publish (calls) | 337 ms (413) | 2.9 ms (44) | 171 ms (106) |
| draw frame | n/a | n/a | 998 ms, span 12562 (404 frames) |

`chunk record` and `history index` fell 30x and 22x with no change to their work: as R3c said,
they were timed around awaits that waited for the main thread. In the candidate's detached run,
`feed call` (the parser) is now the largest stage at 34% of wall. Fewer publishes per run (44
vs 413) is burst-mode coalescing at the higher rate, not a cadence change.

## Time Profiler (15 s attached, main thread)

"Busy" is main-thread samples / 15,000 (1 ms sampling). Shares are of main-thread samples, by
backtrace containing the frame. This counts only the `NSHostingView.beginTransaction` subtree,
so it reads lower than R3c's 78-79%, which also counted layout and CA commit outside it. Compare
within this table only.

| Capture | Payload | Main busy | SwiftUI transaction | `OutlineListCoordinator` | `MetalTerminalRenderer.draw` |
|---|---|---|---|---|---|
| Baseline detached | 8 MiB x 3 | ~91% | 58.4% | 19.2% | 0 |
| Candidate detached | 64 MiB x 4 | ~37% | 13.3% | 4.4% | 0 |
| Baseline render | 8 MiB x 1 | ~97% | 65.8% | 0 | 2.3% |
| Candidate render | 64 MiB x 1 | ~52% | 53.3% | 0 | 5.0% |

- Detached: the main thread is no longer saturated, and the hosts `List` (`OutlineListCoordinator`,
  the detached benchmark parks on `.hosts`, whose rows show traffic) fell from 19.2% to 4.4%.
- Render: still mostly SwiftUI, but with half the main thread idle. What's left is one
  transaction per publish (snapshot nonce, plus scroll state while scrollback grows) re-running
  every `SessionManager` observer, which is R4b.
- Candidate captures use larger payloads so streaming fills the window; a full scrollback
  changes nothing on the publish path.

## Commands

```sh
S=<scratchpad>
git worktree add --detach $S/base 697e6f1
xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath $S/rel-<base|cand> build
# One launch (run.sh refused if any ProSSHMac was running, logged load, top CPU and the
# front app, waited for exit with open -W, then a 5 s gap)
open -n -W $S/rel-<bin>/Build/Products/Release/ProSSHMac.app --args \
  --benchmark-render[-detached] --benchmark-out $REPORT --benchmark-window 1280x800 \
  --benchmark-bytes 8388608 --benchmark-runs 3 [--perf-signposts]
# Profile: launch without -W, wait for the pid, sleep 3 s (8 s for baseline render), then
xcrun xctrace record --template 'Time Profiler' --attach "$(pgrep -x ProSSHMac)" --time-limit 15s --output $T.trace
xcrun xctrace export --input $T.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > $T.xml
```

`--benchmark-bytes` takes its first occurrence, so profile launches passed their own payload.
The export summary resolved `id`/`ref` elements, took `tagged-backtrace` per row, and grouped
by the thread's `fmt`. `scripts/benchmark-throughput.sh` was not used: it runs
`pkill -9 -x ProSSHMac` first.
