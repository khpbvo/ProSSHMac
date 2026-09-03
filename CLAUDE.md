# CLAUDE.md — Working Memory

Read automatically at every session start. Current state only — no history, no dated entries.

---

## Memory Architecture

| Layer | File | Purpose |
|-------|------|---------|
| **Working memory** | `CLAUDE.md` (this file) | Current state, conventions, key files, gotchas. Read every session. |
| **Long-term log** | `docs/featurelist.md` | Dated work log, phase progress, loop-log entries. Append-only history. |
| **Feature specs** | `docs/<FeatureName>.md` | Per-feature phased checklist with architecture notes. Created at feature start. |

- `CLAUDE.md` holds **what is true now**. Update when architecture, conventions, key files, or gotchas change.
- `docs/featurelist.md` holds **what happened and when**. Every session appends a dated entry.
- Feature specs hold **what to do and how**. Each phase has a `- [ ]` checkbox, checked off when completed.

---

## Workflow

### Starting a New Feature

1. Create `docs/<FeatureName>.md` with:
   - Overview (goal, architecture sketch, affected files)
   - Phased checklist using `- [ ] Phase N: <title>` checkbox format
   - Each phase should be one session's worth of work
2. Add a reference row to the Reference Docs table below.
3. Log the feature start in `docs/featurelist.md` with today's date.

### Session Workflow (one phase per session)

Each Claude Code session implements exactly one phase from a feature spec.

**Start of session:**
1. This file is read automatically — instant project context.
2. Read the feature spec (`docs/<FeatureName>.md`) to find the current unchecked phase.
3. **Plan mode is enabled** before implementation. Design the phase before writing code.
4. Once the plan is confirmed, exit plan mode and implement.

**During session:**
- Work only on the current phase. Do not jump ahead.
- If a phase is too large for one context window, split it into sub-phases in the feature spec.

**End of session — do ALL of these before the final commit:**
1. Build passes and **targeted tests** pass (only test suites relevant to the changed code):
   `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`
   `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test -only-testing:ProSSHMacTests/<TestClassName>`
   Full test suite (`test` without `-only-testing`) is only needed before major releases or cross-cutting refactors.
2. Check off completed phase in `docs/<FeatureName>.md`
3. Append dated entry to `docs/featurelist.md` (what changed, files modified, build/test status)
4. Update this `CLAUDE.md` if architecture, conventions, key files, or gotchas changed
5. Write the **Next Session Plan** block at the bottom of this file
6. Commit all changes (code + docs) in a single commit

### Continuous Workflow Across Sessions

At the bottom of this file is a `<!-- NEXT SESSION PLAN -->

**Last completed work (2026-09-03): RenderCost Phases R0 and R1.**

The rendering cost is now measured, and the answer inverts the previous plan.

**Rendering (Metal) is cheap. The path around it is not.** Per frame the renderer costs ~4-6 ms CPU
and ~1 ms GPU with a 100% glyph cache hit rate. But end-to-end on the real path, in a 1100x750
active window:

| Path | MB/s |
|---|---|
| Parser/grid only (`--benchmark-base64`) | 36.44 |
| PTY -> `engine.feed` (`--pty-local`) | 19.20 |
| Real app path, terminal off-screen (`--render-detached`) | **0.14** |
| Real app path, terminal visible (`--render`) | **0.03-0.05** |
| Terminal.app (peer, with rendering) | 26.5 |

Two findings make the next step obvious:

1. **`parse + grid` is 0.1% of wall on the real path.** `FasterThenYouWillEverLiveToBe` Phase 4
   proposed optimising exactly that stage next. **Do not do it** — it is a rounding error. Mark
   Phase 4 abandoned rather than optional.
2. **`publish` is 23-25% of wall, at 4-8.5 ms per call**, and the draw loop is provably not the
   cause: runs where the surface was unbound drew **zero frames** and were just as slow. The cost
   is upstream of `draw(in:)`, in publish -> SwiftUI -> surface.

Next session: **RenderCost Phase R2.** Ranked in `docs/RenderCost.md`:
- `TerminalRenderingCoordinator.publishGridState` (@MainActor, once per 4 ms batch).
- Confirm cost scales with grid cell count — a small off-screen window measured 16x faster on the
  same code path with nothing rendering.
- The per-raw-chunk MainActor hop in `SessionShellIOCoordinator.recordParsedChunk` (~1290/MB).
- The stage budget sums to well under wall time; ~18 s of a 31.6 s run is spent waiting, not
  working. Find out where.

Unrelated open work: `docs/bugs.md` (50 open), `docs/PhaseB.md` manual smoke checklist,
the `Docs/` vs `docs/` case split, and the flaky
`SessionManagerRenderingPathTests.testLocalSessionStreamsProgressiveCommandOutput`.
