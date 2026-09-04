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

**Last completed work (2026-09-04): RenderCost Phase R2a.**

R1's ~18 s of unattributed wall time is explained, and R2's ranking was wrong on every count.

**The cost was `TerminalHistoryIndex.recordOutputChunk` — 89% of wall.** It ran once per raw PTY
chunk (~1290/MB) via the `@MainActor` hop in `recordParsedChunk` and, past its 120,000-character
cap, paid four O(n) passes over the whole buffer per call (a COW copy, two grapheme-cluster
`String.count`s, an O(n) `removeFirst`). Raw output is now UTF-8 bytes with an amortized trim and a
read-time character cap, and `recordParsedChunk` runs once per 4 ms batch. `history index` fell to
11.6%; an interleaved A/B shows ~3x at low load and more under contention.

**`publish` measured 0.3%, not the 23-25% R1 recorded.** Do not act on R1's ranking.

Next session: **RenderCost Phase R2b — coalesce cross-actor round-trips**, which now dominate:

| Stage | % wall |
|---|---|
| batch follow-up (4 engine round-trips after every `feed`) | **46.7%** |
| publish housekeep (5 more of its own) | 32.4% |
| publish (99% of it is `publishEngineWait`) | 26.6% |
| parse + grid | 24.3% |
| history index | 11.6% |

Ranked in `docs/RenderCost.md`. Also open there: throughput is bimodal under load (18.94 and 0.20
MB/s in one launch, no code change) — suspect the burst/debounce logic.

**Benchmark gotchas that cost this session hours — read `docs/RenderCost.md` "Measurement caveats"
before trusting any rendered number:**
- `open -n App.app --args <anything>` yields a process with **zero windows**, so the rendered
  benchmark silently measures the detached path. It now warns. R1's windowed figures could not be
  reproduced.
- The recorded "`--perf-signposts` costs ~19x" did not reproduce (2.78 on vs 2.86 off).
- Background load swings results 7x-100x. Use interleaved A/B runs of two binaries.

Unrelated open work: `docs/bugs.md` (50 open), `docs/PhaseB.md` manual smoke checklist,
and the `Docs/` vs `docs/` case split. (`SessionManagerRenderingPathTests` ran 21/21 green twice
this session, including the previously flaky
`testLocalSessionStreamsProgressiveCommandOutput`.)
