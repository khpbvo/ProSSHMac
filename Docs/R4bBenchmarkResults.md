# R4b benchmark results (2026-10-23)

Evidence for `Docs/RenderCost.md` Phase R4b. Baseline: unchanged HEAD `1e8fb04` from a
`git archive` copy. Candidate: the same tree plus R4b. Both were built as universal Release
apps with Xcode 27.1 on macOS 26.6.2 (`MacBookPro18,2`). The benchmark used 1280×800 windows,
8 MiB × 3 runs, App Nap prevention, and the **to-sentinel** rate. Every included launch reported
`window: count=1`; the runner's “to settled” value still includes its ~10 s timeout.

## Interleaved A/B

MB/s to sentinel. Each launch made its own window and exited; no `pkill` was used.

| Pair | Order | Baseline | R4b | Window state |
|---|---|---:|---:|---|
| D1 `--render-detached` | base, candidate | 17.41–18.15 | 19.83–20.48 | one, active, both |
| D2 `--render-detached` | candidate, base | 16.50–17.19 | 19.71–20.20 | one, candidate inactive, base active |
| R1 `--render` | base, candidate | 2.50–3.35 | 12.30–13.89 | one, active, both |

The detached candidate is close to the prior windowless ~20 MB/s rate. The rendered candidate
is about 4.6× the baseline in the valid pair, though still below Terminal.app's 30.8–34.8 MB/s
R3c peer result. Rendered runs were mostly at ~30 fps with an unfocused-surface warning; both
sides of R1 had the same condition. Background load and top CPU consumers were **not captured
at the instant of these desktop launches**, so the ranges are more trustworthy than a claim
about a stable absolute rate.

The second rendered candidate launch reported **two windows** (12.44–13.62 MB/s), while its
baseline reported one (4.01–7.04 MB/s). Another candidate retry also had two windows and no
usable key window. Those runs are excluded from the A/B table. Direct `open -n -W` launches
from the shell reported zero windows (about 20 MB/s detached); they were excluded too. A
temporary ad-hoc-signed copy of each app, launched through the desktop, produced the valid
one-window runs. The original project sources and benchmark settings were identical between
each baseline/candidate pair.

## Time Profiler

Separate 128 MiB × 1 rendered launches each reported one active 1280×800 window and App Nap
prevention. Baseline: 6.67 MB/s to sentinel; candidate: 12.32 MB/s. Both captures attached to
the running process for 15 s; the table uses the **first 10 s** of each trace, when both runs
were still streaming. A sample counts as SwiftUI transaction work if its backtrace contains
`GraphHost.flushTransactions()`.

| Main thread | Baseline | R4b |
|---|---:|---:|
| Busy share of wall time | 73.3% | 44.5% |
| `GraphHost.flushTransactions` share of main-thread samples | 35.6% | 20.2% |
| Transaction samples as share of wall time | 26.1% | 9.0% |
| `MetalTerminalRenderer.draw(in:)` share of main-thread samples | 2.3% | 6.6% |

The transaction share fell about 2.9× as a share of wall time. The larger draw share is a
percentage of a less busy main thread, not evidence that drawing got more expensive.
These are sampling estimates, and the captures were not simultaneous or controlled for
background load. A first candidate profile had two windows and was excluded.

## View-reader audit

`SessionManager` still owns the session registry, metadata, input modes, bell, recording state,
traffic, and action methods. `HostsView` reads sessions/traffic; terminal tab, header, metadata,
actions and file sidebar read session/metadata/action state; Transfers and Settings read their
own low-frequency manager state. None need the snapshot nonce, scroll state or shell text to
invalidate their entire body on each publish. Those three values now have a manager-owned
`SessionLiveState` for each session. The Metal surface observes the nonce and retains its
`.onChange` → snapshot application path; the scrollbar subscribes only to scroll changes; the
open search bar and classic-text fallback subscribe to shell lines. Nonreactive lookups remain
on `SessionManager` for tools and existing callers. Session close removes the live state.

## Verification and remaining limit

The Debug and Release app builds passed with the Metal shader included. The five focused suites
in R4's checklist passed **70 tests** after the final scrollbar/search subscription narrowing;
the rendering-path suite was rerun after the last nonce arithmetic cleanup. A live local zsh
session in the rebuilt app accepted a command, which verifies basic terminal input and session
creation. ScreenCaptureKit failed to
capture the app window in this environment, so a visual regression check of scrolling, search,
and duplicate-pane rendering remains useful. The persistent ~30 fps draw after output stops is
still an open energy finding; R4b did not change the renderer's continuous-frame policy.
