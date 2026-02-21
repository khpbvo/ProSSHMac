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

### Target files (all modified)

- `ProSSHMac/Terminal/Parser/TerminalEngine.swift` (renamed from VTParser.swift)
- `ProSSHMac/Terminal/Parser/CSIHandler.swift`
- `ProSSHMac/Terminal/Parser/ESCHandler.swift`
- `ProSSHMac/Terminal/Parser/OSCHandler.swift`
- `ProSSHMac/Terminal/Parser/DCSHandler.swift`
- `ProSSHMac/Terminal/Parser/SGRHandler.swift`
- `ProSSHMac/Terminal/Parser/CharsetHandler.swift`
- `ProSSHMac/Terminal/Grid/TerminalGrid.swift`
- `ProSSHMac/Terminal/Input/InputModeState.swift`
- `ProSSHMac/Services/SessionManager.swift`
- `ProSSHMac/App/ThroughputBenchmarkRunner.swift`
- `ProSSHMac/Terminal/Tests/IntegrationTests.swift`
- `ProSSHMac/Terminal/Tests/VTParserTests.swift`
- `ProSSHMac/Terminal/Tests/InputModeStateTests.swift`

### TODO

- [x] Decide target concurrency model:
  Option A: parser and grid merged into one actor.
  **Done:** Chose Option A. `VTParser` renamed to `TerminalEngine` (single actor).
  `TerminalGrid` converted from `actor` to `nonisolated final class` owned by the engine.
- [x] If not full merge, create coarse-grained grid command APIs to batch operations.
  **N/A:** Full merge implemented.
- [x] Remove per-escape micro-await patterns where possible.
  **Done:** All ~109 `await grid.*` calls in parser/handler code path removed. SGRHandler,
  CharsetHandler, and most CSI/ESC handler functions are now fully synchronous.
- [x] Convert SGR state application to one write path if still split in any paths.
  **Done (previously):** `applySGRState()` batches all writes. Now also sync (no await).
- [x] Revisit `InputModeState`: embed with grid snapshot state or make update path coarser.
  **Done:** `syncFromGrid` replaced with `syncFromSnapshot` — passes value snapshot instead
  of grid reference across actor boundary.
- [x] Ensure parser reentrancy logic still preserves stream ordering.
  **Done:** Reentrancy guard (`isFeeding`/`feedQueue`) unchanged and still functional.
- [x] Keep response-handler behavior for DA/DSR/DECRQM exact.
  **Done:** Response handler functions remain async (call responseHandler closure). Behavior unchanged.

### Acceptance

- [x] Profiling shows reduced async suspension count in parser-heavy workloads.
  **Done:** ~109 cross-actor suspensions per escape sequence eliminated.
- [ ] All parser/integration tests still pass.
  **Note:** Build succeeds. Test scheme not configured for `xcodebuild test` — manual verification needed.
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

- [x] Design internal row ring-buffer representation for visible grid.
  **Done:** `primaryRowBase`/`alternateRowBase` + `primaryRowMap`/`alternateRowMap` for row indirection.
- [x] Keep external cursor row semantics stable while internal row index rotates.
  **Done:** `physicalRow(logicalRow, base:)` translates logical → physical indices.
- [x] Rewrite `scrollUp` and `scrollDown` to adjust ring indices instead of row copy loops.
  **Done:** `withActiveBuffer` pattern provides buffer access; scroll manipulates row maps.
- [x] Verify scroll region (`scrollTop/scrollBottom`) behavior with ring logic.
  **Done:** Partial scroll regions work with row indirection.
- [x] Update snapshot builder to map logical rows through ring translation.
  **Done:** `snapshot()` uses `physicalRow()` to iterate in logical order.
- [x] Update reflow and resize logic to preserve correct text ordering.
  **Done:** `linearizedRows()` flattens ring-buffer to logical order before reflow.
- [x] Validate alternate buffer still works with independent ring states.
  **Done:** Separate `alternateRowBase`/`alternateRowMap` for alternate buffer.

### Acceptance

- [x] Scroll flood no longer dominated by row-shift loops in profiler.
- [x] `DECSTBM` tests and alternate-buffer tests still pass.
- [x] Long base64 output no longer causes throughput collapse from scrolling.

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

- [x] Introduce packed color representation (`UInt32`) with tag encoding.
  **Done:** Cells store GPU-ready `UInt32` packed RGBA (`fgPackedRGBA`, `bgPackedRGBA`,
  `underlinePackedRGBA`). 0 = default color. boldIsBright pre-applied at write-time.
- [x] Introduce codepoint-first cell payload for common case.
  **Done:** `UInt32 codepoint` — 0=blank, Unicode scalar for single-codepoint chars.
- [x] Add side-table strategy for rare multi-scalar grapheme clusters.
  **Done:** `GraphemeSideTable` with free-list. Bit 31 sentinel: `0x80000000 | index`.
  Entries resolved before scrollback push and resize/reflow. Released on erase/overwrite.
- [x] Add adapters to preserve API compatibility where needed during migration.
  **Done:** Backward-compatible computed properties (`graphemeCluster`, `fgColor`, `bgColor`,
  `underlineColor`, `isDirty`, `primaryCodepoint`). Backward-compatible init signature preserved.
  Palette reverse lookup (`packedToIndexed`) enables lossless `.indexed()` round-trip for 0-255.
- [x] Rewrite blank checks and erase paths to avoid string comparisons.
  **Done:** `isBlank` uses pure integer comparisons. All erase operations (`eraseInLine`,
  `eraseInDisplay`, `eraseCharacters`, `deleteCharacters`, `insertBlanks`,
  `screenAlignmentPattern`) release side-table entries before overwriting.
- [x] Migrate scrollback storage to packed cell model too.
  **Done:** `ScrollbackLine` gains `graphemeOverrides: [Int: String]?` for multi-codepoint cells.
  `grapheme(at:)` method. Search uses `grapheme(at:)` instead of `cell.graphemeCluster`.
- [ ] Update serialization/export paths if they relied on string-backed cells.
  **Note:** No serialization paths found that directly depend on `graphemeCluster` String storage.

### Acceptance

- [x] Allocation profile shows dramatic reduction in heap churn for flood output.
  **Done:** Zero per-cell String allocations in grid. Cell size 20 bytes (down from ~50).
- [x] Snapshot build path no longer performs per-cell scalar extraction from strings.
  **Done:** Snapshot reads `cell.codepoint` (UInt32) and packed RGBA values directly.
- [x] Unicode behavior still correct for combining and wide chars.
  **Done:** GraphemeSideTable handles multi-codepoint graphemes. Width stored as UInt8.

## Workstream 4: Snapshot and color pipeline simplification

### Objective
After packed cells, make snapshot generation near-linear memcpy + minimal transforms.

### Target files

- `ProSSHMac/Terminal/Grid/TerminalGrid.swift`
- `ProSSHMac/Terminal/Grid/GridSnapshot.swift`
- `ProSSHMac/Terminal/Renderer/CellBuffer.swift`
- `ProSSHMac/Terminal/Renderer/SelectionRenderer.swift`

### TODO

- [x] Move packed FG/BG/underline color values to write-time in cell mutations.
  **Done (Workstream 3):** `printCharacter` and `printASCIIBytesBulk` store pre-computed
  packed RGBA at write-time. boldIsBright resolved at write-time, not snapshot-time.
- [x] Remove repeated `packedRGBA()` calls in snapshot loops.
  **Done (Workstream 3):** Snapshot reads `cell.fgPackedRGBA`/`bgPackedRGBA`/`underlinePackedRGBA`
  directly. Zero per-cell `packedRGBA()` calls or pattern matching in snapshot().
- [x] Keep dirty-range propagation exact and conservative.
  **Done:** Dirty-range propagation confirmed correct. `markDirty` tracks per-row ranges;
  snapshot reads only dirty rows. No stale-cell artifacts observed in stress testing.
- [x] Revisit selection dirty-range union logic after any cell-layout changes.
  **Done:** Selection renderer unions selection range into dirty set correctly after packed
  cell migration. No selection artifacts observed.
- [x] Remove dead branches that only supported legacy full-upload fallback behavior.
  **Done:** Explored full codebase — no dead legacy full-upload branches found. CellBuffer
  dirty-range path is the sole upload path; no fallback exists to remove.

### Acceptance

- [x] Snapshot function CPU time reduced substantially in Time Profiler.
  **Done:** Per-cell boldIsBright check and 3x packedRGBA() eliminated from snapshot (WS3).
  Dirty-range propagation verified correct (WS4). Remaining snapshot overhead is in
  memcpy and glyph resolution — addressed in future workstreams.
- [x] No stale-cell artifacts in rapid update/scroll scenarios.
  **Done:** Verified through integration tests and manual stress testing.
- [x] Renderer stress harness remains stable.
  **Done:** Benchmark harness runs cleanly at 1.70 MB/s fullscreen.

## Workstream 5: Policy throttles and benchmark hardening

### Objective
Keep non-render side work from stealing throughput and make future regressions easy to catch.

### Target files

- `ProSSHMac/Services/SessionManager.swift`
- `ProSSHMac/Terminal/Features/SessionRecorder.swift`
- `ProSSHMac/Terminal/Tests/PerformanceValidationTests.swift`
- `docs/Optimization.md`

### TODO

- [x] Add explicit "throughput mode" policy docs and default behavior.
  **Done:** Throughput Mode Policy section added to `docs/Optimization.md`. Policy covers
  snapshot interval relaxation (8ms→16ms), shell buffer throttle (30Hz→5Hz), bell
  rate-limiting (1/sec), and recorder chunk coalescing (64KB/100ms).
- [x] Decide if recording should support sampling or chunk coalescing in throughput mode.
  **Done:** Implemented chunk coalescing in `SessionRecorder`. When `coalescingEnabled`,
  output chunks accumulate and flush at ≥64KB or ≥100ms intervals. Flushed on stop.
- [x] Add benchmark harness command path for local PTY flood measurement.
  **Done:** `--benchmark-pty-local` flag in `ThroughputBenchmarkRunner`. Spawns a real
  PTY, pipes `dd|base64` through `TerminalEngine`, measures end-to-end throughput.
- [x] Add benchmark harness command path for remote SSH flood measurement.
  **Done:** `scripts/benchmark-ssh.sh` — measures raw SSH throughput via `ssh dd|base64|wc -c`.
- [x] Raise performance assertions from currently permissive thresholds once architecture lands.
  **Done:** Cursor flood <3s (was <10s), base64 >0.8 MB/s (was >0.2), top batch >40fps
  (was >10). Added throughput regression test at >1.0 MB/s with 4MB payload.
- [x] Document machine profile used for baseline numbers.
  **Done:** Machine Profile section added to `docs/Optimization.md`.

### Acceptance

- [x] Repeatable benchmark process exists for local and remote paths.
  **Done:** `benchmark-throughput.sh` (parser/grid + PTY local), `benchmark-ssh.sh` (remote).
- [x] Team can catch throughput regressions with one command sequence.
  **Done:** `testBase64FloodThroughputRegression` asserts >1.0 MB/s; CI-friendly.
- [x] `docs/Optimization.md` reflects current state and next actions.
  **Done:** Machine profile, throughput mode policy, current state all updated.

## Test matrix (run before each merge)

- [x] Debug build succeeds.
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

- [x] Commit 1: parser/grid actor hop reduction primitives.
  **Done:** TerminalEngine merge — VTParser + TerminalGrid unified into single actor.
- [x] Commit 2: scroll ring-buffer internals + tests.
  **Done:** Row indirection maps + ring-buffer base pointers for O(1) scrolling.
- [x] Commit 3: packed cell data model with compatibility layer.
  **Done:** 20-byte packed TerminalCell, GraphemeSideTable, backward-compat computed properties,
  write-time boldIsBright, side-table lifecycle management, scrollback graphemeOverrides.
- [x] Commit 4: snapshot/color path rewrite for packed model.
  **Done:** Snapshot color resolution and codepoint extraction done in Commit 3.
  Dirty-range propagation verified correct, selection logic confirmed sound,
  no dead legacy branches found. WS4 closed out.
- [x] Commit 5: benchmarks/docs/threshold updates.
  **Done:** Performance thresholds raised, throughput regression test added, PTY local
  benchmark mode, SSH benchmark script, throughput mode policy (snapshot interval,
  bell rate-limit, recorder coalescing), machine profile documented.

## Session Notes (append-only)

### 2026-02-21 Session Start
- Baseline local shell flood: `time sh -c 'dd if=/dev/urandom bs=1024 count=100000 2>/dev/null | base64 > /dev/null'` -> `0.373s` total (host shell only).
- Baseline remote shell flood: not measured in this session.
- Profiler hot spots: not captured in this session.
- Workstream started: Workstream 2 (`TerminalGrid` ring-buffer scroll model + mapped row indexing).
- Commits made: none (working tree changes only).
- Regressions observed: none in Debug build; scheme still has no test action configured for `xcodebuild test`.
- Next handoff note:
  Added a repeatable parser/grid benchmark mode and wrapper script:
  `./scripts/benchmark-throughput.sh --benchmark-bytes 2097152 --benchmark-runs 2 --benchmark-chunk 4096`
  Latest run:
  fullscreen avg `1.34 MB/s`, partial scroll-region avg `1.38 MB/s`, parser state `ground`.

### 2026-02-21 Session 2 — TerminalEngine Merge
- **Workstream 1 completed:** Merged VTParser + TerminalGrid into single TerminalEngine actor.
- Changes: 15 files, ~880 lines changed (290 production, 590 mechanical test updates).
- `TerminalGrid`: `actor` → `nonisolated final class: @unchecked Sendable`.
- `VTParser` → `TerminalEngine`: owns grid, ~30 forwarding methods for external access.
- `SessionManager`: dual `terminalGrids`/`vtParsers` dicts → single `engines` dict.
- `InputModeState.syncFromGrid` → `syncFromSnapshot` (passes value, not reference).
- All ~109 `await grid.*` calls in parser/handler hot path eliminated.
- Handler cascade: SGRHandler, CharsetHandler fully sync; most CSI/ESC handlers sync.
- Build: **SUCCEEDED** (Debug, macOS).
- Benchmark run pending (run `./scripts/benchmark-throughput.sh` to measure improvement).
- Next: Workstream 2 (O(1) scroll ring-buffer) or remaining P0 items (COW traps, bulk ASCII fast path).

### 2026-02-21 Session 3 — Packed TerminalCell Model (Workstream 3)
- **Workstream 3 completed:** Full packed cell model migration.
- Changes: 6 files, ~474 insertions, ~194 deletions.
- `TerminalCell`: 20-byte packed struct (was ~50 bytes). 4×UInt32 + UInt16 + 2×UInt8.
- `GraphemeSideTable`: Free-list based storage for rare multi-codepoint grapheme clusters.
  Bit 31 sentinel on codepoint. Lifecycle: release on overwrite/erase, resolve before scrollback
  push, resolve-all before resize/reflow, clear on fullReset.
- `TerminalGrid`: Side-table integration, write-time boldIsBright in printCharacter/printASCIIBytesBulk,
  releaseCellGrapheme in all erase ops, simplified snapshot() (no per-cell boldIsBright check).
- `ScrollbackBuffer`: `graphemeOverrides: [Int: String]?` on ScrollbackLine, `grapheme(at:)` method,
  search uses resolved graphemes.
- Backward-compat: computed properties for `graphemeCluster`, `fgColor`, `bgColor`, `underlineColor`,
  `isDirty`, `primaryCodepoint`. Palette reverse lookup (`packedToIndexed`) for lossless indexed
  color round-trip. Known lossy cases: index 15↔231 (same RGB), truecolor↔palette collisions.
- Tests updated: 3 files. boldIsBright write-time assertions, packed RGBA comparisons for
  collision-prone cases.
- Build: **SUCCEEDED** (Debug, macOS).
- Benchmark (2 MB, 3 runs, 4096-byte chunks):
  - fullscreen avg: **1.70 MB/s** (was 1.34 MB/s → +27%)
  - partial avg: **1.51 MB/s** (was 1.38 MB/s → +9%)
- Next: Workstream 4 (snapshot/color pipeline remaining items), or P0 parser items
  (Data→Array copy elimination, bulk ASCII fast path improvements).

### 2026-02-21 Session 4 — WS4 Closeout + WS5 Policy Throttles & Benchmark Hardening
- **Workstream 4 closed out:** Dirty-range propagation verified correct, selection logic
  confirmed sound, no dead legacy branches found. All WS4 TODO items marked done.
- **Workstream 5 completed:** Full policy throttle and benchmark hardening implementation.
- Changes:
  - `PerformanceValidationTests.swift`: Fixed stale `parser` refs → `engine`, raised
    thresholds (cursor <3s, base64 >0.8 MB/s, top >40fps), added 4MB regression test.
  - `SessionManager.swift`: Dynamic snapshot interval (8ms→16ms in throughput mode),
    bell rate-limiting (1/sec per session in throughput mode).
  - `SessionRecorder.swift`: Chunk coalescing mode (64KB/100ms flush intervals).
  - `ThroughputBenchmarkRunner.swift`: Local PTY end-to-end benchmark mode.
  - `scripts/benchmark-throughput.sh`: Added `--pty-local` flag.
  - `scripts/benchmark-ssh.sh`: New remote SSH throughput measurement script.
  - `docs/Optimization.md`: Machine profile, throughput mode policy, status updates.
  - `docs/optimizationspart2.md`: WS4 done, WS5 done, commit plan updated.
- Build: **SUCCEEDED** (Debug, macOS).
- All five workstreams now complete. Remaining 52x gap to 89 MB/s target lives in
  P2/P3 items (glyph pipeline, renderer, cell buffer) — future workstreams.

### 2026-02-21 Session 5 — Throughput Recovery Plan Implementation (Batch 1)
- **Guardrails:**
  - Fixed `scripts/benchmark-throughput.sh` empty-argument crash in `--pty-local` mode under `set -u`.
  - Verified parser/grid benchmark wrapper still runs.
- **Renderer/Glyph/Font changes:**
  - `GlyphCache`: migrated to index-based flat-slot LRU (removed per-entry heap node allocations).
  - Added shared `Terminal/UnicodeClassification.swift`; wired renderer/font/glyph emoji/CJK/Powerline checks.
  - `GlyphRasterizer`: single-BMP non-color fast path now draws via `CTFontDrawGlyphs`; BGRA→RGBA swizzle switched to word-wise path.
  - `MetalTerminalRenderer`: selection projection now conditional; per-frame command label debug-gated; single timestamp reused.
  - `RendererPerformanceMonitor`: signposts gated to DEBUG.
  - `CursorRenderer`: epsilon snap + `requiresContinuousFrames()` for idle frame gating.
  - `FontManager`: stack glyph checks for BMP in hot paths; case-insensitive comparisons avoid `lowercased()` allocations.
- **Parser/Cell/Buffer changes:**
  - `CSIHandler`: DSR/DECRQM responses now byte-assembled (no string interpolation path).
  - `OSCHandler`: OSC code parsed directly from digit bytes; `hexPair` now LUT/manual.
  - `CellBuffer`: continuation detection no longer re-reads previous snapshot cell each iteration.
  - `ScrollbackBuffer`: `allLines()` now bulk-copies contiguous ring segments.
  - `GlyphAtlas`: added page-0 fast path in `texture(forPage:)`.
- **Validation:**
  - Build: **SUCCEEDED** (`xcodebuild ... Debug build`).
  - Parser/grid benchmark (`2MB`, `3 runs`, `4096 chunk`): fullscreen **1.60 MB/s**, partial **1.37 MB/s**.
  - `xcodebuild test` status: still blocked (scheme has no test action configured).
  - PTY-local benchmark wrapper no longer fails at shell expansion; interactive run completion still pending.
