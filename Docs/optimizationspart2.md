# Optimization Part 2: Throughput Recovery Handoff TODO

## Why this file exists
This document is the execution playbook for the remaining throughput work after Part 1.  
Use it as the single source of truth for what is left, in what order to do it, how to validate it, and what not to break.

## Current status snapshot
The following items are already implemented in Part 1 and should not be redone:

- [x] Parser hot path no longer materializes `Data -> ContiguousArray<UInt8>` per chunk.
- [x] `SessionManager` parser reader loop moved off `@MainActor`.
- [x] Session recording has byte-path ingestion (`recordOutputData`) to avoid per-chunk UTF-8 decode.
- [x] Renderer can preserve dirty-range uploads instead of always forcing full uploads.
- [x] Selection projection now updates bounded ranges instead of full-grid clear every frame.
- [x] libssh shell/forward read loops use larger reusable buffers and reduced conversion overhead.
- [x] Trailing blank trimming loops switched from repeated `removeLast()` to single-pass truncation.

## Primary goals and hard success criteria

- [ ] `dd if=/dev/urandom bs=1024 count=100000 | base64` should complete in terminal under 2.0s target on baseline machine profile.
- [ ] No regressions in VT behavior: wrapping, scroll regions, alternate screen, OSC, CSI, DECSC/DECRC.
- [ ] No regressions in Unicode behavior: wide chars, combining marks, emoji fallback.
- [ ] No visual regressions in renderer: stale cells, flicker, selection artifacts, cursor artifacts.
- [ ] Build must stay green in Debug with existing scheme.

## Session bootstrap checklist (first 20 minutes)

- [ ] `git status --short` and confirm unexpected modified files before touching throughput code.
- [ ] `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -configuration Debug -destination 'platform=macOS' build`
- [ ] Record baseline command timing outside terminal renderer:
  `time sh -c 'dd if=/dev/urandom bs=1024 count=100000 2>/dev/null | base64 > /dev/null'`
- [ ] Record baseline in-app terminal timing for the same command (manual run).
- [ ] Record current CPU profile in Instruments (Time Profiler) for 10-15 seconds during flood output.
- [ ] Save trace and timestamp in this file under the "Session Notes" section before coding.

## Workstream order (recommended)
Do work in this order. It minimizes risk and improves observability.

1. Actor-hop collapse and parser/grid ownership simplification.
2. O(1) scroll model for grid rows.
3. Packed cell model migration (`TerminalCell` redesign).
4. Snapshot pipeline simplification after packed model lands.
5. Extra throttle/policy work and benchmark harness hardening.

## Workstream 1: Collapse parser/grid actor hops

### Objective
Reduce suspend/resume and scheduler overhead by cutting high-frequency cross-actor calls.

### Target files

- `ProSSHMac/Terminal/Parser/VTParser.swift`
- `ProSSHMac/Terminal/Parser/CSIHandler.swift`
- `ProSSHMac/Terminal/Parser/ESCHandler.swift`
- `ProSSHMac/Terminal/Parser/SGRHandler.swift`
- `ProSSHMac/Terminal/Input/InputModeState.swift`
- `ProSSHMac/Services/SessionManager.swift`

### TODO

- [ ] Decide target concurrency model:
  Option A: parser and grid merged into one actor.
- [ ] If not full merge, create coarse-grained grid command APIs to batch operations.
- [ ] Remove per-escape micro-await patterns where possible.
- [ ] Convert SGR state application to one write path if still split in any paths.
- [ ] Revisit `InputModeState`: embed with grid snapshot state or make update path coarser.
- [ ] Ensure parser reentrancy logic still preserves stream ordering.
- [ ] Keep response-handler behavior for DA/DSR/DECRQM exact.

### Acceptance

- [ ] Profiling shows reduced async suspension count in parser-heavy workloads.
- [ ] All parser/integration tests still pass.
- [ ] Manual check: vim/htop/top/less behave correctly.

## Workstream 2: O(1) scroll operations in `TerminalGrid`

### Objective
Eliminate O(rows) row shifting during scroll-heavy text floods.

### Target files

- `ProSSHMac/Terminal/Grid/TerminalGrid.swift`
- `ProSSHMac/Terminal/Grid/GridSnapshot.swift`
- `ProSSHMac/Terminal/Grid/ScrollbackBuffer.swift`
- `ProSSHMac/Terminal/Grid/GridReflow.swift`

### TODO

- [ ] Design internal row ring-buffer representation for visible grid.
- [ ] Keep external cursor row semantics stable while internal row index rotates.
- [ ] Rewrite `scrollUp` and `scrollDown` to adjust ring indices instead of row copy loops.
- [ ] Verify scroll region (`scrollTop/scrollBottom`) behavior with ring logic.
- [ ] Update snapshot builder to map logical rows through ring translation.
- [ ] Update reflow and resize logic to preserve correct text ordering.
- [ ] Validate alternate buffer still works with independent ring states.

### Acceptance

- [ ] Scroll flood no longer dominated by row-shift loops in profiler.
- [ ] `DECSTBM` tests and alternate-buffer tests still pass.
- [ ] Long base64 output no longer causes throughput collapse from scrolling.

## Workstream 3: Packed `TerminalCell` model migration

### Objective
Remove per-cell `String` and expensive enum resolution from core hot path.

### Target files

- `ProSSHMac/Terminal/Grid/TerminalCell.swift`
- `ProSSHMac/Terminal/Grid/TerminalGrid.swift`
- `ProSSHMac/Terminal/Grid/ScrollbackBuffer.swift`
- `ProSSHMac/Terminal/Renderer/CellBuffer.swift`
- `ProSSHMac/Terminal/Renderer/MetalTerminalRenderer.swift`
- `ProSSHMac/Terminal/Renderer/GlyphRasterizer.swift`
- `ProSSHMac/Terminal/Tests/*` (wide blast radius expected)

### TODO

- [ ] Introduce packed color representation (`UInt32`) with tag encoding.
- [ ] Introduce codepoint-first cell payload for common case.
- [ ] Add side-table strategy for rare multi-scalar grapheme clusters.
- [ ] Add adapters to preserve API compatibility where needed during migration.
- [ ] Rewrite blank checks and erase paths to avoid string comparisons.
- [ ] Migrate scrollback storage to packed cell model too.
- [ ] Update serialization/export paths if they relied on string-backed cells.

### Acceptance

- [ ] Allocation profile shows dramatic reduction in heap churn for flood output.
- [ ] Snapshot build path no longer performs per-cell scalar extraction from strings.
- [ ] Unicode behavior still correct for combining and wide chars.

## Workstream 4: Snapshot and color pipeline simplification

### Objective
After packed cells, make snapshot generation near-linear memcpy + minimal transforms.

### Target files

- `ProSSHMac/Terminal/Grid/TerminalGrid.swift`
- `ProSSHMac/Terminal/Grid/GridSnapshot.swift`
- `ProSSHMac/Terminal/Renderer/CellBuffer.swift`
- `ProSSHMac/Terminal/Renderer/SelectionRenderer.swift`

### TODO

- [ ] Move packed FG/BG/underline color values to write-time in cell mutations.
- [ ] Remove repeated `packedRGBA()` calls in snapshot loops.
- [ ] Keep dirty-range propagation exact and conservative.
- [ ] Revisit selection dirty-range union logic after any cell-layout changes.
- [ ] Remove dead branches that only supported legacy full-upload fallback behavior.

### Acceptance

- [ ] Snapshot function CPU time reduced substantially in Time Profiler.
- [ ] No stale-cell artifacts in rapid update/scroll scenarios.
- [ ] Renderer stress harness remains stable.

## Workstream 5: Policy throttles and benchmark hardening

### Objective
Keep non-render side work from stealing throughput and make future regressions easy to catch.

### Target files

- `ProSSHMac/Services/SessionManager.swift`
- `ProSSHMac/Terminal/Features/SessionRecorder.swift`
- `ProSSHMac/Terminal/Tests/PerformanceValidationTests.swift`
- `docs/Optimization.md`

### TODO

- [ ] Add explicit "throughput mode" policy docs and default behavior.
- [ ] Decide if recording should support sampling or chunk coalescing in throughput mode.
- [ ] Add benchmark harness command path for local PTY flood measurement.
- [ ] Add benchmark harness command path for remote SSH flood measurement.
- [ ] Raise performance assertions from currently permissive thresholds once architecture lands.
- [ ] Document machine profile used for baseline numbers.

### Acceptance

- [ ] Repeatable benchmark process exists for local and remote paths.
- [ ] Team can catch throughput regressions with one command sequence.
- [ ] `docs/Optimization.md` reflects current state and next actions.

## Test matrix (run before each merge)

- [ ] Debug build succeeds.
- [ ] Performance validation tests relevant to parser/grid pass.
- [ ] Integration tests for alternate screen and scroll region pass.
- [ ] Unicode and input tests pass.
- [ ] Manual smoke:
  vim open/exit, htop-like output, long `base64` flood, text selection drag, resize while flooding.

## Risk register and rollback strategy

- [ ] Keep each workstream in separate commits for easy revert.
- [ ] For high-risk changes, add temporary feature flags.
- [ ] Do not mix cell-model migration with actor-merge in one commit.
- [ ] If stale rendering appears, first rollback selection/snapshot diff logic, not parser logic.

## Commit plan template

- [ ] Commit 1: parser/grid actor hop reduction primitives.
- [ ] Commit 2: scroll ring-buffer internals + tests.
- [ ] Commit 3: packed cell data model with compatibility layer.
- [ ] Commit 4: snapshot/color path rewrite for packed model.
- [ ] Commit 5: benchmarks/docs/threshold updates.

## Session Notes (append-only)

### YYYY-MM-DD Session Start
- Baseline local shell flood:
- Baseline remote shell flood:
- Profiler hot spots:
- Workstream started:
- Commits made:
- Regressions observed:
- Next handoff note:

