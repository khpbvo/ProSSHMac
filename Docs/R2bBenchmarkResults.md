# R2b benchmark evidence — 2026-09-06/07

Baseline: freshly built `af933f4`. Candidate: the uncommitted R2b changes described in
`RenderCost.md`. Both are Release, native arm64; baseline bundle also contains x86_64.
No builds or tests ran concurrently with these measurements. Host load was captured
before each launch. There were three runs per launch and three alternating A/B pairs
per experiment. No runs were removed from the tables below.

Every launch had **zero windows**, despite requesting 1280x800. These are real app-path
output-digestion measurements at the default grid geometry, with no rendering. They
cannot be compared with Terminal.app or any windowed measurement. The 8 MiB request is
base64-encoded, so the app measures about 10.67 MiB received. Detached “to settled” also
includes the benchmark's fixed 200 ms drain delay; it does not measure GPU completion.

The instrumented comparison is inconclusive for overall throughput: pair median
ratios change sign. Bimodality persists in both binaries and with instrumentation off
under direct launch. The source-level call reduction is implemented and tests pass,
but these data do not establish a repeatable end-to-end speedup. All three direct-off
pair medians favor the baseline, so a performance regression cannot be ruled out.
Treat this as a local candidate awaiting performance validation, not a proven optimization.

## Verification

- Debug and Release builds succeeded with normal project signing. Sandboxed signing
  could not access the development certificate; builds succeeded with Xcode/keychain
  access. No signing settings or entitlements were changed in the project.
- Focused tests: 167 tests, 0 failures, 2 instrumentation-only skips. Rendering 21,
  parser 125 (four new tests), history 8, perf 7, benchmark 6.
- No full-suite run or claim. The known local-shell flaky test passed in this run.

## Reproduction

Build the baseline from af933f4 in a separate checkout and the candidate from the
R2b working tree. For each, set BUILD_DIR to a distinct DerivedData directory:

```sh
xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" build
```

The candidate used `ONLY_ACTIVE_ARCH=YES`; both comparisons executed arm64 code.
Preserve both app bundles and alternate launches, waiting for the report before the
next launch. Record `sysctl -n vm.loadavg` and top CPU consumers before each launch.
Do not kill unrelated ProSSHMac sessions.

Instrumented experiment (APP and REPORT select the bundle and a new report path):

```sh
open -n "$APP" --args --benchmark-render-detached --benchmark-out "$REPORT" \
  --benchmark-window 1280x800 --benchmark-bytes 8388608 --benchmark-runs 3 \
  --perf-signposts
```

Control experiment: direct binary launch, instrumentation off:

```sh
"$APP/Contents/MacOS/ProSSHMac" --benchmark-render-detached --benchmark-out "$REPORT" \
  --benchmark-window 1280x800 --benchmark-bytes 8388608 --benchmark-runs 3
```

Focused verification command (Debug):

```sh
xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/prossh-r2b-candidate \
  ONLY_ACTIVE_ARCH=YES \
  -only-testing:ProSSHMacTests/VTParserTests \
  -only-testing:ProSSHMacTests/SessionManagerRenderingPathTests \
  -only-testing:ProSSHMacTests/TerminalPerfTests \
  -only-testing:ProSSHMacTests/TerminalHistoryIndexTests \
  -only-testing:ProSSHMacTests/ThroughputBenchmarkRunnerTests test
```

## Launch medians

Rates are MB/s as printed by the benchmark (MiB/s arithmetic). Ratios are candidate /
baseline, computed within each pair. Load columns contain 1/5/15-minute load averages.


### timed

| Pair | Baseline load | Candidate load | Sentinel baseline → candidate | Ratio | Settled baseline → candidate | Ratio |
|---|---|---|---|---|---|---|
| 1 | { 4.93 4.74 3.80 } | { 3.73 4.44 3.74 } | 3.79 → 18.99 | 5.01x | 3.54 → 13.90 | 3.93x |
| 2 | { 3.60 4.33 3.73 } | { 2.79 4.04 3.65 } | 15.70 → 5.15 | 0.33x | 12.12 → 4.68 | 0.39x |
| 3 | { 3.29 4.00 3.66 } | { 2.87 3.81 3.60 } | 17.42 → 17.80 | 1.02x | 13.09 → 13.25 | 1.01x |

### direct-off

| Pair | Baseline load | Candidate load | Sentinel baseline → candidate | Ratio | Settled baseline → candidate | Ratio |
|---|---|---|---|---|---|---|
| 1 | { 2.53 3.55 3.52 } | { 2.17 3.32 3.43 } | 5.77 → 5.09 | 0.88x | 5.20 → 4.62 | 0.89x |
| 2 | { 2.50 3.26 3.40 } | { 1.72 2.97 3.29 } | 16.53 → 4.87 | 0.29x | 12.52 → 4.46 | 0.36x |
| 3 | { 3.05 3.13 3.33 } | { 3.13 3.11 3.31 } | 16.89 → 14.69 | 0.87x | 12.81 → 11.43 | 0.89x |

## Interpretation and next diagnostic

The first instrumented pair appeared to improve fivefold; the second reversed the
ranking and the third was nearly even. Reporting only the first pair would be wrong.
In candidate pair 3, parse/grid time rose from 268.69 ms in run 2 to 780.42 ms in run 3,
while throughput fell from 19.74 to 5.88 MB/s. The parse/grid implementation did not
change. The slowdown is not confined to follow-up or publishing.

The call reduction is concrete: four post-feed engine reads become zero; ordinary
publishes use two engine calls with MainActor scroll resolution between them; drain
publishes use two calls per snapshot plus one final housekeeping call. In the first
candidate launch, median batch follow-up was 102.83 ms, publish-engine wait 4.41 ms,
and housekeeping 4.29 ms, versus 839.87 / 164.53 / 215.15 ms in its baseline. These are
one pair's measurements, not repeatable magnitude claims. Candidate visible-text
work stayed small, so no further text-scan optimization was made.

Timer boundaries changed deliberately: `feedCall` includes outcome collection;
ordinary-publish housekeeping capture is included in `publishEngineWait`. The drain
retains the outer `publishHousekeeping` timer. `visibleTextScan` sums extraction and
observation separately, so there can be two timer calls per text refresh; the old
standalone visible-text actor wait is no longer included there.

Next: compare thread CPU time with elapsed time around synchronous ground-text/grid
work, correlate burst transitions, batch sizes, process activity and host load, and
establish the cause of the slow regime before tuning scheduling constants. Do not
measure a thread CPU clock across an async suspension because execution can migrate
threads. Restore real window acquisition before making rendered-throughput claims.

## Parser-only control

A short sequential Release control used `--benchmark-base64 --benchmark-bytes 8388608
--benchmark-runs 3`, instrumentation off, after the app-path comparisons. Baseline averages
were 35.21 MB/s fullscreen and 35.21 partial; candidate averages were 33.94 and 31.76.
This was not an interleaved statistical comparison and proves no speedup or regression.
It did not reproduce the 3–4x app-path swings. The original Bool-returning feed implementation
is unchanged. The CPU-versus-wall diagnostic above is still required.

## Raw reports

These are the complete reports, in experiment/pair order. Load averages are preserved
in the table above. Temporary originals and full host snapshots are under
`/tmp/prossh-r2b-results`; this file is the durable record.


### timed-1-baseline

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: ENABLED

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 4.01 MB/s to sentinel, 3.72 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read   121.76 ms    4.2%      574 ms   21.2%        0 ms  (9539 calls, 10.67 MB)
  pty sanitize     7.17 ms    0.3%       21 ms   34.1%        0 ms  (40 calls, 0.03 MB)
  pty handoff    63.25 ms    2.2%      574 ms   11.0%        0 ms  (9539 calls, 10.67 MB)
  chunk record   628.42 ms   21.9%     2645 ms   23.8%       13 ms  (2578 calls, 10.67 MB)
  history index   372.30 ms   13.0%     2644 ms   14.1%       14 ms  (2578 calls, 10.67 MB)
  feed call  1122.58 ms   39.2%     2644 ms   42.5%       14 ms  (2578 calls, 10.67 MB)
  batch follow-up   847.61 ms   29.6%     2644 ms   32.1%       14 ms  (2578 calls, 10.67 MB)
  parse + grid  1066.18 ms   37.2%     2644 ms   40.3%       14 ms  (2578 calls, 10.67 MB)
  snapshot build    32.79 ms    1.1%     2636 ms    1.2%       31 ms  (380 calls)
  publish   145.17 ms    5.1%     2637 ms    5.5%       30 ms  (380 calls)
  publish engine wait   142.54 ms    5.0%     2637 ms    5.4%       30 ms  (760 calls)
  publish housekeep   176.38 ms    6.2%     2636 ms    6.7%       31 ms  (374 calls)
  visible text     7.15 ms    0.2%     2495 ms    0.3%       31 ms  (13 calls)
  wall  2866.62 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 2/3 [render-detached] 3.77 MB/s to sentinel, 3.50 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read   220.03 ms    7.2%      668 ms   33.0%        1 ms  (6307 calls, 10.67 MB)
  pty handoff    60.00 ms    2.0%      668 ms    9.0%        1 ms  (6307 calls, 10.67 MB)
  chunk record   702.38 ms   23.1%     2815 ms   25.0%       10 ms  (1788 calls, 10.67 MB)
  history index   408.18 ms   13.4%     2815 ms   14.5%       10 ms  (1788 calls, 10.67 MB)
  feed call  1212.57 ms   39.8%     2814 ms   43.1%       10 ms  (1788 calls, 10.67 MB)
  batch follow-up   839.87 ms   27.6%     2814 ms   29.8%       10 ms  (1788 calls, 10.67 MB)
  parse + grid  1167.14 ms   38.3%     2814 ms   41.5%       10 ms  (1788 calls, 10.67 MB)
  snapshot build    71.08 ms    2.3%     2811 ms    2.5%       26 ms  (433 calls)
  publish   303.05 ms    9.9%     2816 ms   10.8%       21 ms  (433 calls)
  publish engine wait   299.94 ms    9.8%     2816 ms   10.7%       21 ms  (866 calls)
  publish housekeep   482.13 ms   15.8%     2804 ms   17.2%       33 ms  (429 calls)
  visible text    22.49 ms    0.7%     2697 ms    0.8%       33 ms  (14 calls)
  wall  3046.04 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 3/3 [render-detached] 3.79 MB/s to sentinel, 3.54 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read   182.79 ms    6.1%      799 ms   22.9%        9 ms  (8841 calls, 10.67 MB)
  pty handoff    72.76 ms    2.4%      799 ms    9.1%        9 ms  (8841 calls, 10.67 MB)
  chunk record   726.33 ms   24.1%     2784 ms   26.1%       25 ms  (2359 calls, 10.67 MB)
  history index   394.09 ms   13.1%     2777 ms   14.2%       32 ms  (2359 calls, 10.67 MB)
  feed call  1178.14 ms   39.1%     2776 ms   42.4%       34 ms  (2359 calls, 10.67 MB)
  batch follow-up   833.35 ms   27.6%     2775 ms   30.0%       34 ms  (2359 calls, 10.67 MB)
  parse + grid  1123.79 ms   37.3%     2776 ms   40.5%       34 ms  (2359 calls, 10.67 MB)
  snapshot build    30.95 ms    1.0%     2773 ms    1.1%       45 ms  (402 calls)
  publish   167.22 ms    5.5%     2773 ms    6.0%       44 ms  (402 calls)
  publish engine wait   164.53 ms    5.5%     2773 ms    5.9%       44 ms  (804 calls)
  publish housekeep   215.15 ms    7.1%     2768 ms    7.8%       49 ms  (394 calls)
  visible text     9.49 ms    0.3%     2732 ms    0.3%       49 ms  (14 calls)
  wall  3014.73 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.

summary:
  render-detached to sentinel avg: 3.86 MB/s
  render-detached to settled  avg: 3.59 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### timed-1-candidate

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: ENABLED

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 18.44 MB/s to sentinel, 13.62 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    44.16 ms    5.6%      209 ms   21.1%        1 ms  (10196 calls, 10.67 MB)
  pty sanitize     8.42 ms    1.1%       21 ms   40.0%        1 ms  (65 calls, 0.03 MB)
  pty handoff    54.22 ms    6.9%      209 ms   25.9%        1 ms  (10196 calls, 10.67 MB)
  chunk record   157.63 ms   20.1%      566 ms   27.8%        8 ms  (2699 calls, 10.67 MB)
  history index    93.65 ms   12.0%      566 ms   16.5%        9 ms  (2699 calls, 10.67 MB)
  feed call   282.29 ms   36.0%      566 ms   49.9%        9 ms  (2699 calls, 10.67 MB)
  batch follow-up   106.04 ms   13.5%      566 ms   18.7%        9 ms  (2699 calls, 10.67 MB)
  parse + grid   274.25 ms   35.0%      566 ms   48.5%        9 ms  (2699 calls, 10.67 MB)
  snapshot build     1.07 ms    0.1%      561 ms    0.2%       17 ms  (51 calls)
  publish     4.27 ms    0.5%      561 ms    0.8%       17 ms  (51 calls)
  publish engine wait     4.10 ms    0.5%      561 ms    0.7%       17 ms  (102 calls)
  publish housekeep     7.18 ms    0.9%      561 ms    1.3%       18 ms  (41 calls)
  visible text     0.61 ms    0.1%      430 ms    0.1%       18 ms  (6 calls)
  wall   783.34 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 2/3 [render-detached] 19.31 MB/s to sentinel, 14.07 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    43.66 ms    5.8%      196 ms   22.3%        0 ms  (10234 calls, 10.67 MB)
  pty handoff    47.23 ms    6.2%      196 ms   24.1%        0 ms  (10234 calls, 10.67 MB)
  chunk record   147.65 ms   19.5%      542 ms   27.3%        5 ms  (2704 calls, 10.67 MB)
  history index    91.95 ms   12.1%      542 ms   17.0%        5 ms  (2704 calls, 10.67 MB)
  feed call   277.50 ms   36.6%      542 ms   51.2%        5 ms  (2704 calls, 10.67 MB)
  batch follow-up   102.83 ms   13.6%      542 ms   19.0%        5 ms  (2704 calls, 10.67 MB)
  parse + grid   270.04 ms   35.6%      542 ms   49.9%        5 ms  (2704 calls, 10.67 MB)
  snapshot build     1.07 ms    0.1%      542 ms    0.2%       13 ms  (53 calls)
  publish     4.61 ms    0.6%      542 ms    0.9%       13 ms  (53 calls)
  publish engine wait     4.41 ms    0.6%      542 ms    0.8%       13 ms  (106 calls)
  publish housekeep     4.29 ms    0.6%      542 ms    0.8%       13 ms  (41 calls)
  visible text     0.49 ms    0.1%      427 ms    0.1%       14 ms  (6 calls)
  wall   758.04 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 3/3 [render-detached] 18.99 MB/s to sentinel, 13.90 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    44.10 ms    5.7%      204 ms   21.6%        3 ms  (10223 calls, 10.67 MB)
  pty handoff    46.32 ms    6.0%      204 ms   22.7%        3 ms  (10223 calls, 10.67 MB)
  chunk record   149.79 ms   19.5%      549 ms   27.3%        8 ms  (2706 calls, 10.67 MB)
  history index    94.00 ms   12.3%      549 ms   17.1%        9 ms  (2706 calls, 10.67 MB)
  feed call   282.56 ms   36.8%      549 ms   51.5%        9 ms  (2706 calls, 10.67 MB)
  batch follow-up    97.25 ms   12.7%      549 ms   17.7%        9 ms  (2706 calls, 10.67 MB)
  parse + grid   274.73 ms   35.8%      549 ms   50.1%        9 ms  (2706 calls, 10.67 MB)
  snapshot build     1.23 ms    0.2%      544 ms    0.2%       17 ms  (50 calls)
  publish     4.80 ms    0.6%      545 ms    0.9%       17 ms  (50 calls)
  publish engine wait     4.64 ms    0.6%      545 ms    0.9%       17 ms  (100 calls)
  publish housekeep     4.29 ms    0.6%      544 ms    0.8%       18 ms  (40 calls)
  visible text     0.59 ms    0.1%      426 ms    0.1%       18 ms  (6 calls)
  wall   767.33 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.

summary:
  render-detached to sentinel avg: 18.91 MB/s
  render-detached to settled  avg: 13.86 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### timed-2-baseline

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: ENABLED

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 15.70 MB/s to sentinel, 12.12 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    45.36 ms    5.2%      216 ms   21.0%        1 ms  (10209 calls, 10.67 MB)
  pty sanitize    12.47 ms    1.4%       24 ms   52.4%        1 ms  (74 calls, 0.03 MB)
  pty handoff    58.43 ms    6.6%      216 ms   27.0%        1 ms  (10209 calls, 10.67 MB)
  chunk record   163.83 ms   18.6%      670 ms   24.4%        6 ms  (2700 calls, 10.67 MB)
  history index    94.97 ms   10.8%      668 ms   14.2%        8 ms  (2700 calls, 10.67 MB)
  feed call   283.25 ms   32.2%      668 ms   42.4%        8 ms  (2700 calls, 10.67 MB)
  batch follow-up   201.11 ms   22.9%      668 ms   30.1%        8 ms  (2700 calls, 10.67 MB)
  parse + grid   274.52 ms   31.2%      668 ms   41.1%        8 ms  (2700 calls, 10.67 MB)
  snapshot build     1.74 ms    0.2%      673 ms    0.3%       18 ms  (83 calls)
  publish     6.58 ms    0.7%      674 ms    1.0%       18 ms  (83 calls)
  publish engine wait     6.33 ms    0.7%      674 ms    0.9%       18 ms  (166 calls)
  publish housekeep     9.92 ms    1.1%      673 ms    1.5%       18 ms  (83 calls)
  visible text     1.02 ms    0.1%      639 ms    0.2%       18 ms  (4 calls)
  wall   880.03 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 2/3 [render-detached] 16.01 MB/s to sentinel, 12.29 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    42.90 ms    4.9%      186 ms   23.0%        4 ms  (10110 calls, 10.67 MB)
  pty handoff    43.72 ms    5.0%      186 ms   23.5%        4 ms  (10110 calls, 10.67 MB)
  chunk record   160.38 ms   18.5%      656 ms   24.5%        9 ms  (2696 calls, 10.67 MB)
  history index    96.88 ms   11.2%      655 ms   14.8%        9 ms  (2696 calls, 10.67 MB)
  feed call   281.76 ms   32.5%      655 ms   43.0%        9 ms  (2696 calls, 10.67 MB)
  batch follow-up   198.07 ms   22.8%      655 ms   30.2%        9 ms  (2696 calls, 10.67 MB)
  parse + grid   273.07 ms   31.5%      655 ms   41.7%        9 ms  (2696 calls, 10.67 MB)
  snapshot build     1.41 ms    0.2%      651 ms    0.2%       17 ms  (71 calls)
  publish     5.03 ms    0.6%      651 ms    0.8%       17 ms  (71 calls)
  publish engine wait     4.81 ms    0.6%      651 ms    0.7%       17 ms  (142 calls)
  publish housekeep     7.32 ms    0.8%      651 ms    1.1%       18 ms  (70 calls)
  visible text     0.64 ms    0.1%      617 ms    0.1%       18 ms  (4 calls)
  wall   867.83 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 3/3 [render-detached] 15.05 MB/s to sentinel, 11.73 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    48.30 ms    5.3%      218 ms   22.1%        2 ms  (10156 calls, 10.67 MB)
  pty handoff    53.23 ms    5.9%      218 ms   24.4%        3 ms  (10156 calls, 10.67 MB)
  chunk record   179.82 ms   19.8%      698 ms   25.8%        8 ms  (2696 calls, 10.67 MB)
  history index   113.06 ms   12.4%      697 ms   16.2%        8 ms  (2696 calls, 10.67 MB)
  feed call   286.55 ms   31.5%      697 ms   41.1%        8 ms  (2696 calls, 10.67 MB)
  batch follow-up   214.61 ms   23.6%      697 ms   30.8%        8 ms  (2696 calls, 10.67 MB)
  parse + grid   277.11 ms   30.5%      697 ms   39.7%        8 ms  (2696 calls, 10.67 MB)
  snapshot build     1.70 ms    0.2%      694 ms    0.2%       16 ms  (83 calls)
  publish     6.82 ms    0.7%      694 ms    1.0%       16 ms  (83 calls)
  publish engine wait     6.56 ms    0.7%      694 ms    0.9%       16 ms  (166 calls)
  publish housekeep     9.00 ms    1.0%      694 ms    1.3%       16 ms  (82 calls)
  visible text     0.62 ms    0.1%      627 ms    0.1%       16 ms  (4 calls)
  wall   909.29 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.

summary:
  render-detached to sentinel avg: 15.59 MB/s
  render-detached to settled  avg: 12.05 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### timed-2-candidate

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: ENABLED

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 5.15 MB/s to sentinel, 4.68 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read   127.79 ms    5.6%      578 ms   22.1%        1 ms  (9223 calls, 10.67 MB)
  pty sanitize    18.25 ms    0.8%       35 ms   52.5%        1 ms  (38 calls, 0.03 MB)
  pty handoff    77.46 ms    3.4%      578 ms   13.4%        1 ms  (9223 calls, 10.67 MB)
  chunk record   625.99 ms   27.5%     2058 ms   30.4%        8 ms  (2463 calls, 10.67 MB)
  history index   366.13 ms   16.1%     2057 ms   17.8%        9 ms  (2463 calls, 10.67 MB)
  feed call   998.91 ms   43.8%     2048 ms   48.8%       18 ms  (2463 calls, 10.67 MB)
  batch follow-up   383.97 ms   16.9%     2048 ms   18.7%       18 ms  (2463 calls, 10.67 MB)
  parse + grid   953.55 ms   41.9%     2048 ms   46.6%       18 ms  (2463 calls, 10.67 MB)
  snapshot build    18.08 ms    0.8%     2047 ms    0.9%       27 ms  (181 calls)
  publish   103.64 ms    4.5%     2047 ms    5.1%       27 ms  (181 calls)
  publish engine wait   101.96 ms    4.5%     2047 ms    5.0%       27 ms  (362 calls)
  publish housekeep    63.53 ms    2.8%     2047 ms    3.1%       28 ms  (128 calls)
  visible text     8.07 ms    0.4%     1880 ms    0.4%       28 ms  (20 calls)
  wall  2278.20 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 2/3 [render-detached] 4.90 MB/s to sentinel, 4.48 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read   104.28 ms    4.4%      544 ms   19.2%        2 ms  (9667 calls, 10.67 MB)
  pty handoff    59.44 ms    2.5%      544 ms   10.9%        2 ms  (9667 calls, 10.67 MB)
  chunk record   664.82 ms   27.9%     2162 ms   30.7%       14 ms  (2622 calls, 10.67 MB)
  history index   409.15 ms   17.2%     2162 ms   18.9%       14 ms  (2622 calls, 10.67 MB)
  feed call  1046.71 ms   43.9%     2161 ms   48.4%       16 ms  (2622 calls, 10.67 MB)
  batch follow-up   409.20 ms   17.2%     2160 ms   18.9%       16 ms  (2622 calls, 10.67 MB)
  parse + grid  1007.79 ms   42.3%     2161 ms   46.6%       16 ms  (2622 calls, 10.67 MB)
  snapshot build    15.66 ms    0.7%     2161 ms    0.7%       26 ms  (179 calls)
  publish    76.93 ms    3.2%     2162 ms    3.6%       25 ms  (179 calls)
  publish engine wait    75.19 ms    3.2%     2162 ms    3.5%       25 ms  (358 calls)
  publish housekeep    60.95 ms    2.6%     2161 ms    2.8%       26 ms  (138 calls)
  visible text     7.03 ms    0.3%     2106 ms    0.3%       26 ms  (22 calls)
  wall  2382.46 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 3/3 [render-detached] 5.16 MB/s to sentinel, 4.69 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read   153.66 ms    6.8%      575 ms   26.7%        0 ms  (7835 calls, 10.67 MB)
  pty handoff    57.21 ms    2.5%      575 ms    9.9%        0 ms  (7835 calls, 10.67 MB)
  chunk record   583.61 ms   25.7%     2057 ms   28.4%        9 ms  (2074 calls, 10.67 MB)
  history index   361.61 ms   15.9%     2057 ms   17.6%       10 ms  (2074 calls, 10.67 MB)
  feed call  1067.30 ms   47.0%     2056 ms   51.9%       10 ms  (2074 calls, 10.67 MB)
  batch follow-up   371.41 ms   16.3%     2056 ms   18.1%       10 ms  (2074 calls, 10.67 MB)
  parse + grid  1029.87 ms   45.3%     2056 ms   50.1%       10 ms  (2074 calls, 10.67 MB)
  snapshot build    18.84 ms    0.8%     2044 ms    0.9%       29 ms  (172 calls)
  publish    97.10 ms    4.3%     2045 ms    4.7%       28 ms  (172 calls)
  publish engine wait    95.39 ms    4.2%     2045 ms    4.7%       28 ms  (344 calls)
  publish housekeep    75.50 ms    3.3%     2043 ms    3.7%       31 ms  (123 calls)
  visible text     7.67 ms    0.3%     1902 ms    0.4%       31 ms  (20 calls)
  wall  2273.14 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.

summary:
  render-detached to sentinel avg: 5.07 MB/s
  render-detached to settled  avg: 4.62 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### timed-3-baseline

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: ENABLED

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=true count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 17.94 MB/s to sentinel, 13.33 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    43.53 ms    5.4%      198 ms   21.9%        1 ms  (10126 calls, 10.67 MB)
  pty sanitize     9.15 ms    1.1%       17 ms   53.3%        1 ms  (57 calls, 0.03 MB)
  pty handoff    52.70 ms    6.6%      198 ms   26.6%        1 ms  (10126 calls, 10.67 MB)
  chunk record   140.84 ms   17.6%      587 ms   24.0%        6 ms  (2705 calls, 10.67 MB)
  history index    85.44 ms   10.7%      587 ms   14.6%        6 ms  (2705 calls, 10.67 MB)
  feed call   270.18 ms   33.8%      587 ms   46.0%        6 ms  (2705 calls, 10.67 MB)
  batch follow-up   159.15 ms   19.9%      587 ms   27.1%        6 ms  (2705 calls, 10.67 MB)
  parse + grid   263.34 ms   32.9%      587 ms   44.9%        6 ms  (2705 calls, 10.67 MB)
  snapshot build     1.45 ms    0.2%      582 ms    0.2%       15 ms  (69 calls)
  publish     5.54 ms    0.7%      582 ms    1.0%       15 ms  (69 calls)
  publish engine wait     5.40 ms    0.7%      582 ms    0.9%       15 ms  (138 calls)
  publish housekeep     6.27 ms    0.8%      582 ms    1.1%       15 ms  (68 calls)
  visible text     0.63 ms    0.1%      416 ms    0.2%       15 ms  (3 calls)
  wall   800.48 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 2/3 [render-detached] 17.42 MB/s to sentinel, 13.09 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    43.91 ms    5.4%      196 ms   22.4%        0 ms  (10298 calls, 10.67 MB)
  pty handoff    45.78 ms    5.6%      196 ms   23.3%        0 ms  (10298 calls, 10.67 MB)
  chunk record   144.94 ms   17.8%      603 ms   24.0%        5 ms  (2697 calls, 10.67 MB)
  history index    87.93 ms   10.8%      603 ms   14.6%        6 ms  (2697 calls, 10.67 MB)
  feed call   269.13 ms   33.0%      603 ms   44.6%        6 ms  (2697 calls, 10.67 MB)
  batch follow-up   174.63 ms   21.4%      603 ms   28.9%        6 ms  (2697 calls, 10.67 MB)
  parse + grid   261.95 ms   32.1%      603 ms   43.4%        6 ms  (2697 calls, 10.67 MB)
  snapshot build     1.22 ms    0.1%      595 ms    0.2%       14 ms  (61 calls)
  publish     4.23 ms    0.5%      595 ms    0.7%       14 ms  (61 calls)
  publish engine wait     4.10 ms    0.5%      595 ms    0.7%       14 ms  (122 calls)
  publish housekeep     5.41 ms    0.7%      595 ms    0.9%       15 ms  (60 calls)
  visible text     0.60 ms    0.1%      430 ms    0.1%       15 ms  (3 calls)
  wall   814.88 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 3/3 [render-detached] 16.98 MB/s to sentinel, 12.81 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    44.30 ms    5.3%      197 ms   22.5%        0 ms  (10252 calls, 10.67 MB)
  pty handoff    46.24 ms    5.6%      197 ms   23.4%        0 ms  (10252 calls, 10.67 MB)
  chunk record   158.87 ms   19.1%      623 ms   25.5%        5 ms  (2703 calls, 10.67 MB)
  history index    95.66 ms   11.5%      623 ms   15.4%        5 ms  (2703 calls, 10.67 MB)
  feed call   270.27 ms   32.5%      623 ms   43.4%        6 ms  (2703 calls, 10.67 MB)
  batch follow-up   179.53 ms   21.6%      623 ms   28.8%        6 ms  (2703 calls, 10.67 MB)
  parse + grid   262.84 ms   31.6%      623 ms   42.2%        6 ms  (2703 calls, 10.67 MB)
  snapshot build     1.26 ms    0.2%      630 ms    0.2%       14 ms  (63 calls)
  publish     5.03 ms    0.6%      630 ms    0.8%       14 ms  (63 calls)
  publish engine wait     4.85 ms    0.6%      630 ms    0.8%       14 ms  (126 calls)
  publish housekeep     6.04 ms    0.7%      629 ms    1.0%       15 ms  (61 calls)
  visible text     0.74 ms    0.1%      431 ms    0.2%       15 ms  (3 calls)
  wall   832.63 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.

summary:
  render-detached to sentinel avg: 17.45 MB/s
  render-detached to settled  avg: 13.08 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### timed-3-candidate

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: ENABLED

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 17.80 MB/s to sentinel, 13.25 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    44.11 ms    5.5%      224 ms   19.7%        0 ms  (10204 calls, 10.67 MB)
  pty sanitize     8.95 ms    1.1%       35 ms   25.4%        0 ms  (38 calls, 0.03 MB)
  pty handoff    55.83 ms    6.9%      224 ms   24.9%        0 ms  (10204 calls, 10.67 MB)
  chunk record   165.23 ms   20.5%      591 ms   28.0%        6 ms  (2702 calls, 10.67 MB)
  history index    99.80 ms   12.4%      590 ms   16.9%        6 ms  (2702 calls, 10.67 MB)
  feed call   281.76 ms   35.0%      590 ms   47.7%        6 ms  (2702 calls, 10.67 MB)
  batch follow-up   107.88 ms   13.4%      590 ms   18.3%        7 ms  (2702 calls, 10.67 MB)
  parse + grid   274.01 ms   34.0%      590 ms   46.4%        7 ms  (2702 calls, 10.67 MB)
  snapshot build     1.08 ms    0.1%      583 ms    0.2%       17 ms  (48 calls)
  publish     3.68 ms    0.5%      583 ms    0.6%       17 ms  (48 calls)
  publish engine wait     3.51 ms    0.4%      583 ms    0.6%       17 ms  (96 calls)
  publish housekeep     5.98 ms    0.7%      582 ms    1.0%       17 ms  (41 calls)
  visible text     2.01 ms    0.2%      419 ms    0.5%       17 ms  (6 calls)
  wall   805.33 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 2/3 [render-detached] 19.74 MB/s to sentinel, 14.33 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    44.06 ms    5.9%      174 ms   25.4%        3 ms  (10266 calls, 10.67 MB)
  pty handoff    40.53 ms    5.4%      174 ms   23.3%        3 ms  (10266 calls, 10.67 MB)
  chunk record   146.99 ms   19.8%      529 ms   27.8%        6 ms  (2706 calls, 10.67 MB)
  history index    90.15 ms   12.1%      529 ms   17.0%        6 ms  (2706 calls, 10.67 MB)
  feed call   276.40 ms   37.1%      529 ms   52.2%        6 ms  (2706 calls, 10.67 MB)
  batch follow-up    94.59 ms   12.7%      529 ms   17.9%        6 ms  (2706 calls, 10.67 MB)
  parse + grid   268.69 ms   36.1%      529 ms   50.8%        6 ms  (2706 calls, 10.67 MB)
  snapshot build     1.01 ms    0.1%      525 ms    0.2%       15 ms  (50 calls)
  publish     4.14 ms    0.6%      526 ms    0.8%       15 ms  (50 calls)
  publish engine wait     3.99 ms    0.5%      526 ms    0.8%       15 ms  (100 calls)
  publish housekeep     4.46 ms    0.6%      525 ms    0.8%       15 ms  (38 calls)
  visible text     0.60 ms    0.1%      426 ms    0.1%       15 ms  (6 calls)
  wall   744.18 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.
run 3/3 [render-detached] 5.88 MB/s to sentinel, 5.26 MB/s to settled
stage budget (render-detached):
  stage time  %wall  span  busy  at
  pty read    64.23 ms    3.2%      344 ms   18.7%        2 ms  (10326 calls, 10.67 MB)
  pty handoff    55.91 ms    2.8%      344 ms   16.3%        3 ms  (10326 calls, 10.67 MB)
  chunk record   596.13 ms   29.4%     1803 ms   33.1%        8 ms  (2711 calls, 10.67 MB)
  history index   316.12 ms   15.6%     1803 ms   17.5%        8 ms  (2711 calls, 10.67 MB)
  feed call   814.34 ms   40.2%     1803 ms   45.2%        8 ms  (2711 calls, 10.67 MB)
  batch follow-up   355.14 ms   17.5%     1803 ms   19.7%        8 ms  (2711 calls, 10.67 MB)
  parse + grid   780.42 ms   38.5%     1803 ms   43.3%        8 ms  (2711 calls, 10.67 MB)
  snapshot build    10.32 ms    0.5%     1798 ms    0.6%       17 ms  (144 calls)
  publish    52.61 ms    2.6%     1798 ms    2.9%       17 ms  (144 calls)
  publish engine wait    51.81 ms    2.6%     1798 ms    2.9%       17 ms  (288 calls)
  publish housekeep    33.13 ms    1.6%     1798 ms    1.8%       17 ms  (109 calls)
  visible text     4.30 ms    0.2%     1694 ms    0.3%       17 ms  (18 calls)
  wall  2027.74 ms
  note: PTY reader and parser run concurrently — stages overlap and
        do not partition wall time. span = first start to last end,
        busy = time/span, at = first start after reset.

summary:
  render-detached to sentinel avg: 14.47 MB/s
  render-detached to settled  avg: 10.95 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### direct-off-1-baseline

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: off

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 4.07 MB/s to sentinel, 3.77 MB/s to settled
run 2/3 [render-detached] 5.77 MB/s to sentinel, 5.20 MB/s to settled
run 3/3 [render-detached] 18.39 MB/s to sentinel, 13.55 MB/s to settled

summary:
  render-detached to sentinel avg: 9.41 MB/s
  render-detached to settled  avg: 7.51 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### direct-off-1-candidate

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: off

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 5.09 MB/s to sentinel, 4.62 MB/s to settled
run 2/3 [render-detached] 5.03 MB/s to sentinel, 4.59 MB/s to settled
run 3/3 [render-detached] 17.01 MB/s to sentinel, 12.85 MB/s to settled

summary:
  render-detached to sentinel avg: 9.04 MB/s
  render-detached to settled  avg: 7.35 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### direct-off-2-baseline

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: off

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 16.46 MB/s to sentinel, 12.46 MB/s to settled
run 2/3 [render-detached] 16.53 MB/s to sentinel, 12.52 MB/s to settled
run 3/3 [render-detached] 18.02 MB/s to sentinel, 13.28 MB/s to settled

summary:
  render-detached to sentinel avg: 17.00 MB/s
  render-detached to settled  avg: 12.75 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### direct-off-2-candidate

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: off

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 5.09 MB/s to sentinel, 4.64 MB/s to settled
run 2/3 [render-detached] 4.87 MB/s to sentinel, 4.46 MB/s to settled
run 3/3 [render-detached] 4.62 MB/s to sentinel, 4.25 MB/s to settled

summary:
  render-detached to sentinel avg: 4.86 MB/s
  render-detached to settled  avg: 4.45 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### direct-off-3-baseline

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: off

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 14.47 MB/s to sentinel, 11.36 MB/s to settled
run 2/3 [render-detached] 16.89 MB/s to sentinel, 12.81 MB/s to settled
run 3/3 [render-detached] 17.53 MB/s to sentinel, 13.12 MB/s to settled

summary:
  render-detached to sentinel avg: 16.30 MB/s
  render-detached to settled  avg: 12.43 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```


### direct-off-3-candidate

```text
==> ProSSHMac Rendered End-to-End Benchmark
    mode=render-detached kilobytes=8192 runs=3
    signposts/stage-timers: off

  WARNING: this process has no windows at all. The grid is at its default
           geometry and nothing renders, so this number is NOT comparable
           to any windowed run — state that alongside the result.
    window: active=false count=0 frame=0x0@0,0 (forced)
run 1/3 [render-detached] 4.92 MB/s to sentinel, 4.50 MB/s to settled
run 2/3 [render-detached] 17.58 MB/s to sentinel, 13.15 MB/s to settled
run 3/3 [render-detached] 14.69 MB/s to sentinel, 11.43 MB/s to settled

summary:
  render-detached to sentinel avg: 12.39 MB/s
  render-detached to settled  avg: 9.69 MB/s
  (no Metal surface attached — this is the no-rendering baseline)
```

### parser-baseline

```text
==> ProSSHMac Throughput Benchmark
    bytes=8388608 chunk=4096 runs=3 lineLength=76
    signposts/stage-timers: off

run 1/3 [fullscreen] 34.30 MB/s in 0.233s (state=ground)
run 1/3 [partial]    34.42 MB/s in 0.232s (state=ground)
run 2/3 [fullscreen] 35.97 MB/s in 0.222s (state=ground)
run 2/3 [partial]    35.04 MB/s in 0.228s (state=ground)
run 3/3 [fullscreen] 35.38 MB/s in 0.226s (state=ground)
run 3/3 [partial]    36.18 MB/s in 0.221s (state=ground)

summary:
  fullscreen avg: 35.21 MB/s
  partial    avg: 35.21 MB/s
  delta: 0.01% slower in partial scroll region
```

### parser-candidate

```text
==> ProSSHMac Throughput Benchmark
    bytes=8388608 chunk=4096 runs=3 lineLength=76
    signposts/stage-timers: off

run 1/3 [fullscreen] 33.06 MB/s in 0.242s (state=ground)
run 1/3 [partial]    33.94 MB/s in 0.236s (state=ground)
run 2/3 [fullscreen] 34.43 MB/s in 0.232s (state=ground)
run 2/3 [partial]    27.84 MB/s in 0.287s (state=ground)
run 3/3 [fullscreen] 34.34 MB/s in 0.233s (state=ground)
run 3/3 [partial]    33.50 MB/s in 0.239s (state=ground)

summary:
  fullscreen avg: 33.94 MB/s
  partial    avg: 31.76 MB/s
  delta: 6.43% slower in partial scroll region
```
