# R3c benchmark results — first windowed baseline, and what a window costs

Evidence for `Docs/RenderCost.md` Phase R3c (2026-10-23). Release, HEAD `6b6de2a`, one bundle
built into a scratch DerivedData folder and used for every run. 8 MiB x 3 runs per launch
unless noted. Apple Silicon (built-in 3456x2234 Retina display, 1496x967 points).

## Summary

| Path | MB/s to sentinel | Notes |
|---|---|---|
| `--render-detached`, 1280x800 window | **1.75-2.08** (active runs) | 3 interleaved pairs |
| `--render`, 1280x800 window | **0.14-0.16** | ~88-94 fps, Metal CPU 0.5-1.3 ms, GPU 1.2-2.0 ms per frame |
| Detached / render, 640x400 to 1480x893 | 1.73-2.17 / 0.13-0.17 | **no window-size effect** |
| Terminal.app peer (`benchmark-peer-emulator.sh --mb 8`) | **30.8-34.8** | between two 1280x800 render launches (0.14-0.15) |
| Windowless detached (R2b candidate, same pipeline) | 20.07-20.91 | not re-measured: no windowless launch exists now |

**Cause, from Time Profiler:** the main thread is 100% busy in both windowed modes, and
~78-79% of it is SwiftUI view-graph updates (`NSHostingView.beginTransaction` →
`GraphHost.flushTransactions`). Metal drawing is 2.2% of the main thread in render mode. The
parser pipeline hops onto the MainActor twice per ~4 KB batch (`recordParsedChunk` and the return
from the history-index actor), so it gets whatever main-thread time SwiftUI leaves. Every batch
writes `@Published bytesReceivedBySessionID`, and every publish writes the snapshot nonce plus
`scrollStateBySessionID`, `inputModeSnapshotsBySessionID`, `windowTitleBySessionID` and
`workingDirectoryBySessionID` whether or not they changed. All of these share `SessionManager`'s
one `objectWillChange`, which every `@EnvironmentObject` observer (Hosts, Terminal, tab bar,
metadata, sidebar…) listens to.

## Conditions and deviations from the plan

- **Activation.** The plan required `active=true` throughout. The first launch ran while the
  screen was locked (`lsappinfo front` = `loginwindow`, `active=false`; kept as `locked-D`, 2.38-2.40,
  not used). After unlock, 1a's detached launches and one render launch stayed active. From
  16:56 on, the user worked in other apps (a front-app log in every `.meta` records Safari,
  Firefox, Mail, Chrome, Terminal), so most later launches went inactive within 1-5 s.
  **With the App Nap activity held, activation made no difference:** 1a's inactive pair
  measured 1.62-1.98 / 0.15-0.16 against 1.75-2.08 / 0.14-0.16 active. So inactive runs are
  reported, with their state, instead of being rejected.
- **Window sizes.** 2560x1440 does not fit a 1496x967-point screen; the largest frame was
  clamped to 1480x893. Sizes used: 640x400, 800x500, 1280x800, 1480x893.
- **Windowless arm.** The plan launched it from Claude Code's sandboxed shell, expecting zero
  windows (R3b's lead). **The sandboxed launch got a window** (`count=1`, 2.04-2.17 MB/s), so the
  sandbox lead is refuted, and there is no windowless launch without a code change. The Time
  Profiler capture made the windowless arm unnecessary: it attributes the cost directly. The
  stage budget is compared with R2b's windowless candidate reports instead (same pipeline;
  R3a/R3b changed only the activity and comments).
- Load ranged 1.5-5.7 (1-minute). Top consumers apart from ProSSHMac: WindowServer (15-45%),
  iTerm2 (18-40%), Safari, and once `corespotlightd` at 106% (16:46, before the rerun of pair 3).

## 1a. Render vs detached, 1280x800, interleaved

| Launch | Start | Load | Runs (MB/s to sentinel) | Activation | fps |
|---|---|---|---|---|---|
| D1 | 16:36:05 | 1.53 | 1.75 / 1.76 / 1.78 | active | – |
| R1 | 16:36:39 | 2.04 | 0.15 / 0.15 / 0.14 | active, run 3 ended inactive | 88 / 88 / 87 |
| D2 | 16:41:11 | 2.66 | 1.75 / 1.78 / 1.78 | active | – |
| R2 | 16:41:39 | 3.63 | 0.14 / 0.14 / 0.14 | active | 88 / 87 / 87 |
| D3 (inactive) | 16:46:18 | 3.74 | 1.62 / 1.98 / 1.80 | inactive after run 1 start | – |
| R3 (inactive) | 16:46:46 | 3.44 | 0.15 / 0.16 / 0.15 | inactive | 93 / 93 / 93 |
| D3 (rerun) | 16:51:30 | 1.76 | 2.06 / 2.08 / 2.06 | active | – |
| R3 (rerun) | 16:51:55 | 1.84 | 0.15 / 0.16 / 0.14 | active for run 1 | 92 / 93 / 92 |

Rendering costs a further ~12-14x on top of the window: about 1.6 KB of output is digested
per frame drawn.

## 1b. Window scaling (two round-robin rounds, mostly inactive)

| Frame | Detached round 1 / round 2 | Render round 1 / round 2 | Render fps |
|---|---|---|---|
| 640x400 | 1.73 / 2.07 / 2.12 — 2.06 / 1.97 / 1.94 | 0.16 / 0.17 / 0.16 — 0.15 / 0.13 / 0.15 | 82-101 |
| 800x500 | 1.76 / 2.15 / 2.13 — 2.17 / 2.09 / 2.12 | 0.15 / 0.14 / 0.15 — 0.14 / 0.14 / 0.14 | 86-92 |
| 1480x893 | 2.03 / 1.98 / 1.92 — 2.10 / 2.08 / 2.11 | 0.15 / 0.15 / 0.14 — 0.13 / 0.14 / 0.15 | 86-94 |

No size effect in either mode. The documented ">10x with cell count" gotcha came from
comparing windowed with windowless runs, not from window size.

## 1c. Terminal.app peer

`./scripts/benchmark-peer-emulator.sh --app Terminal --mb 8 --runs 3`, 17:35, load ~3.5:
0.26 s → 30.77, 0.24 s → 33.33, 0.23 s → 34.78 MB/s. ProSSHMac `--render` 1280x800 either side:
0.15 / 0.15 / 0.16 (17:30:56) and 0.14 / 0.14 / 0.14 (17:35:18). The peer script times with
0.01 s resolution on a ~0.25 s run, so treat the peer figure as ±5%. An earlier peer attempt
overlapped a running ProSSHMac at 99% CPU and was discarded (`1c-peer-overlapped`).

## 2. Attribution

### Stage budget: windowed (now) vs windowless (R2b candidate)

Detached, 1280x800, `--perf-signposts --perf-scheduling`, run 3 of launch `2-WL1` (2.17 MB/s),
against R2b's `timed-1-candidate` (`Docs/R2bBenchmarkResults.md`). Same ~2,700 batches, 10.67 MB.

| Stage | windowless | windowed | growth |
|---|---|---|---|
| chunk record | 147.65-157.63 ms | 4,064.92 ms (79.2% wall, busy 82.7%) | ~26x |
| history index | 91.95-93.65 ms | 1,999.27 ms (39.0%) | ~21x |
| batch follow-up | 102.83-106.04 ms | 573.75 ms | ~5.5x |
| parse + grid | – | 247.27 ms (4.8%) | – |
| publish engine wait | – | 320.59 ms | – |
| wall | 783 ms | 5,130.63 ms | 6.6x |

Ground work stayed at 99.4% CPU/elapsed (`qos=25`), so the parser is not descheduled.
`chunk record` and `history index` are timed in the detached parser task around
`await self?.recordParsedChunk(...)` and `await terminalHistoryIndex.recordOutputChunk(...)`
(`SessionShellIOCoordinator.swift:344-346, 406-412`). **They include the wait for the main
thread**, which is why they grow while the work inside them doesn't.

### Time Profiler, windowed detached (`2-TP`, 15 s attached, 1 ms samples)

Main thread: 14,446 samples, **all Running**, 14,416 on P cores. Inclusive:

| Frame | Share of main thread |
|---|---|
| run-loop observers (`__CFRunLoopDoObservers`) | 82.7% |
| SwiftUI `NSRunLoop.flushObservers` | 78.9% |
| `ViewGraphRootValueUpdater._updateViewGraph` | 61.4% |
| `NSHostingView.beginTransaction` → `GraphHost.flushTransactions` | 59.9% |
| `DynamicBody.updateValue` (view bodies) | 36.0% |
| `OutlineListCoordinator.update` (a `List`) | 18.6% |
| `CA::Transaction::commit` | 15.9% |
| `NSTableView enumerateAvailableRowViews` | 13.3% |
| window layout (`layoutSubtreeIfNeeded`) | 9.1% |
| `Button.body` | 8.4% |
| `HostsView.body` | 4.8% |
| `List.body` | 4.6% |
| `SessionShellIOCoordinator.startParserReader` closure | 1.8% |
| `recordParsedChunk` | 0.9% |
| `TerminalRenderingCoordinator.handleFeedOutcome` | 0.8% |

### Time Profiler, windowed render (`2-TPR`, 2 MiB x 3, 15 s attached)

Main thread: 14,427 samples, all Running. SwiftUI graph update 77.5%, `GraphHost.runTransaction`
65.6%, view bodies 28.8%, layout (`StackLayout` / `_FlexFrameLayout.sizeThatFits`) ~21%,
CA commit 30.5%. App frames: `Button.body` 7.3%, `TerminalView.body` 2.4%,
`TerminalView.terminalLifecycleView` 1.9%, `TerminalSessionTabBar` 1.2%, `TerminalSurfaceView`
0.9%, `TerminalKeyboardShortcutLayer` 0.8%, `TerminalSessionMetadataView` 0.6%.
**`MetalTerminalRenderer.draw(in:)` 2.2%.** CVDisplayLink thread: 45 samples. The profiled
launch measured 0.14 / 0.15 / 0.15 MB/s at 66-73 fps (profiling overhead).

### Where SessionManager publishes on this path

- Per batch (`SessionShellIOCoordinator.recordParsedChunk`): `bytesReceivedBySessionID += n`.
- Per publish (`TerminalRenderingCoordinator` housekeeping, ~380 per run): `gridSnapshotNonceBySessionID += 1`,
  `scrollStateBySessionID[id] = …` (unconditional), `inputModeSnapshotsBySessionID[id] = …`
  (unconditional), `windowTitleBySessionID` / `workingDirectoryBySessionID` (whenever non-empty).
- Throttled: `shellBuffers[id] = visibleLines`.

`@Published` emits `objectWillChange` on every write, equal value or not. Observers by
`@EnvironmentObject`: `HostsView`, `TerminalView`, `TerminalSurfaceView`, `TerminalSessionTabBar`,
`TerminalSessionActionsBar`, `TerminalSessionMetadataView`, `TerminalFileBrowserSidebar`,
`TransfersView`, `SettingsView`, `ExternalTerminalWindowView`; `TerminalScrollbarView` by
`@ObservedObject`.

## Commands

```sh
APP=<scratch>/rel/Build/Products/Release/ProSSHMac.app   # xcodebuild -configuration Release -derivedDataPath <scratch>/rel build
# One launch (the scratch run.sh wrapped this, logged load/top/front app, waited for exit, 5 s gap)
open -n "$APP" --args --benchmark-render[-detached] --benchmark-out "$REPORT" \
  --benchmark-window 1280x800 --benchmark-bytes 8388608 --benchmark-runs 3 [--perf-signposts --perf-scheduling]
# Profile: attach once the process exists
xcrun xctrace record --template 'Time Profiler' --attach "$(pgrep -x ProSSHMac)" --time-limit 15s --output tp.trace
xcrun xctrace export --input tp.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > tp.xml
# Peer
./scripts/benchmark-peer-emulator.sh --app Terminal --mb 8 --runs 3
```

`scripts/benchmark-throughput.sh` was not used: it runs `pkill -9 -x ProSSHMac` first. The
wrapper refused to launch while any ProSSHMac was running. Reading `tp.xml` needs id/ref
resolution and `tagged-backtrace` rows; aggregate main-thread frames by thread `fmt`.

## Raw stage budget (2-WL1, run 3)

```
run 3/3 [render-detached] 2.17 MB/s to sentinel, 2.08 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    35.11 ms    0.7%      192 ms   18.3%        5 ms  (10464 calls, 10.67 MB)
  pty handoff    47.85 ms    0.9%      192 ms   24.9%        5 ms  (10464 calls, 10.67 MB)
  chunk record  4064.92 ms   79.2%     4917 ms   82.7%       10 ms  (2718 calls, 10.67 MB)
  history index  1999.27 ms   39.0%     4915 ms   40.7%       12 ms  (2718 calls, 10.67 MB)
  feed call   259.56 ms    5.1%     4912 ms    5.3%       15 ms  (2718 calls, 10.67 MB)
  batch follow-up   573.75 ms   11.2%     4912 ms   11.7%       15 ms  (2718 calls, 10.67 MB)
  parse + grid   247.27 ms    4.8%     4912 ms    5.0%       15 ms  (2718 calls, 10.67 MB)
  snapshot build     6.65 ms    0.1%     4903 ms    0.1%       35 ms  (405 calls)
  publish   321.31 ms    6.3%     4903 ms    6.6%       34 ms  (405 calls)
  publish engine wait   320.59 ms    6.2%     4903 ms    6.5%       34 ms  (810 calls)
  publish housekeep   293.26 ms    5.7%     4899 ms    6.0%       39 ms  (380 calls)
  visible text    25.99 ms    0.5%     5049 ms    0.5%       39 ms  (52 calls)
  wall  5130.63 ms
scheduling diagnostic (synchronous ground work only):
  qos=25 calls=2718 bytes=11185055 cpu=205.00ms elapsed=206.18ms cpu/elapsed=99.4%
  batches=2718 bytes=11185055 mean=4115 max=6144 under4K=2
  events: burstEnter=1 publishRequest=2718
```

Every other launch's per-run figures are in the tables above; the reports themselves (with
`process before/after` lines and frame stats) were not kept in the repo.
