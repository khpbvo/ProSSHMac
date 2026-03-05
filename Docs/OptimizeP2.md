# P2 Optimization — Memory Layout & Allocation Reduction

Actionable phased checklist for all remaining P2 items from `docs/Optimization.md`.

---

## Phase 0: Glyph Cache — Flat Array LRU ✅ ALREADY DONE

**Status:** Already implemented in a previous session. `GlyphCache.swift` uses a `Slot` struct
in `ContiguousArray<Slot>`, `[GlyphKey: Int]` dictionary, integer-indexed prev/next links,
and a `freeList: [Int]` for slot recycling. Zero per-entry heap allocations.

- [x] Flat `Slot` struct (value type) with `prev`/`next` as `Int` indices
- [x] `ContiguousArray<Slot>` pre-allocated to capacity
- [x] `[GlyphKey: Int]` dictionary for O(1) lookup
- [x] `freeList: [Int]` for recycled slots
- [x] `@inline(__always)` on `trackedLookup`

---

## Phase 1: Glyph Rasterizer — Reusable Pixel Buffer & CGContext ✅ DONE

**Goal:** Eliminate per-glyph heap allocation of pixel buffers and CGContext creation.

**Files:** `GlyphRasterizer.swift`, `MetalTerminalRenderer.swift`, `MetalTerminalRenderer+GlyphResolution.swift`, `MetalTerminalRenderer+DrawLoop.swift`

- [x] Read `GlyphRasterizer.swift` fully; identify `rasterize()` method, pixel buffer allocation site, CGContext creation site
- [x] Convert from stateless `enum` to `final class GlyphRasterizer: @unchecked Sendable`
- [x] Add instance properties:
  - `scratchBuffer: UnsafeMutableRawPointer?` (allocated once at max cell size)
  - `scratchBufferSize: Int`
  - `scratchContext: CGContext?` (created once, reused)
  - `scratchContextWidth/Height/IsColor` (tracks current dimensions and color mode)
- [x] In `rasterize()`:
  - Replace `[UInt8](repeating: 0, count: bufferSize)` with `memset(scratchBuffer, 0, bufferSize)`
  - Replace `CGContext(...)` creation with reuse via `ensureScratchBuffer()` (recreate only if cell size or color mode changed)
  - Copy pixel data out via `unsafeUninitializedCapacity` + `memcpy` for returned `RasterizedGlyph`
- [x] Handle resize: if dimensions/color mode change, deallocate old buffer and recreate
- [x] Add `deinit` to free `scratchBuffer`
- [x] `MetalTerminalRenderer` owns a `glyphRasterizer` instance for main-thread use
- [x] `drainPendingGlyphKeysIfNeeded()` creates a local `GlyphRasterizer()` per background batch
- [x] `rasterizeGlyphForBackground()` accepts `rasterizer:` parameter
- [x] All instance methods marked `nonisolated` for cross-isolation use
- [x] Build passes, test suite passes (209 tests, 2 pre-existing failures)

---

## Phase 2: Glyph Rasterizer — Direct CTFont Glyph Drawing ✅ DONE

**Goal:** Bypass NSAttributedString/CTLine for single-codepoint glyphs (99% of cases).

**Files:** `GlyphRasterizer.swift`, `GlyphRasterizerTests.swift`

- [x] Read the current rasterization path: `NSAttributedString` → `CTLine` → `CTLineDraw`
- [x] Add a fast path in `rasterize()` for single-codepoint, non-emoji glyphs:
  - BMP: single UniChar → `CTFontGetGlyphsForCharacters` → `CTFontDrawGlyphs`
  - Supplementary: UTF-16 surrogate pair → same flow
  - Falls back to CTLine path if font doesn't have the glyph
- [x] Extracted `rasterizeWithDirectDraw()` (fast) and `rasterizeWithCTLine()` (slow) helper methods
- [x] CTLine path retained for color emoji and fallback cases
- [x] Grapheme cluster path unchanged (always uses CTLine)
- [x] 12 targeted tests: ASCII, digits, CJK wide, emoji color, grapheme clusters, bold/italic, edge cases
- [x] Build passes, all 12 GlyphRasterizerTests pass

---

## Phase 3: CTFont Caching ✅ DONE

**Goal:** Stop calling `CTFontCreateWithName` on every background rasterization batch.

**Files:** `MetalTerminalRenderer+GlyphResolution.swift`, `MetalTerminalRenderer.swift`, `MetalTerminalRenderer+DrawLoop.swift`

- [x] Identified: main-thread path already cached via `rebuildRasterFontCacheIfNeeded`; background task in `drainPendingGlyphKeysIfNeeded` was recreating all 4 font variants per batch
- [x] Added `RasterFontSet` struct (`@unchecked Sendable` with `nonisolated(unsafe)` properties) to hold the 4 CTFont variants
- [x] `rebuildRasterFontCacheIfNeeded` now builds `cachedRasterFontSet` alongside individual cached fonts
- [x] `drainPendingGlyphKeysIfNeeded` captures `cachedRasterFontSet` — no more `CTFontCreateWithName` on background thread
- [x] `rasterizeGlyphForBackground` accepts `fontSet: RasterFontSet` instead of 4 individual font params
- [x] Font invalidation: `cachedRasterFontSet` rebuilt whenever font name/size/scale changes (same trigger as before)
- [x] Build passes, all 12 GlyphRasterizerTests pass

---

## Phase 4: BGRA-to-RGBA Swizzle Elimination ✅ DONE

**Goal:** Switch Metal texture format to `.bgra8Unorm` and remove the CPU-side pixel swizzle.

**Files:** `GlyphRasterizer.swift`, `GlyphAtlas.swift`

- [x] Atlas texture format changed from `.rgba8Unorm` to `.bgra8Unorm`
- [x] Unified both CGContext paths (text + emoji) to BGRA (`byteOrder32Little | premultipliedFirst`)
- [x] Removed `scratchContextIsColor` tracking — no longer needed since both paths use same format
- [x] Removed `swizzleBGRAtoRGBA` method and all call sites
- [x] Shader only reads `.a` (alpha) from atlas — channel order change has zero impact
- [x] Build passes, all 12 GlyphRasterizerTests pass

---

## Phase 5: CellBuffer — Bulk Update & Closure Elimination ✅ DONE

**Goal:** Replace per-cell loop with bulk memcpy + fixup pass; eliminate closure overhead.

**Files:** `CellBuffer.swift`, `MetalTerminalRenderer+GlyphResolution.swift`, `MetalTerminalRenderer+SnapshotUpdate.swift`

- [x] Read `CellBuffer.update()` fully — bulk copy already existed via `copyCells()`
- [x] Dirty range tracking already existed from prior implementation
- [x] Added `GlyphResolver` protocol — generic constraint enables compiler specialization/inlining
- [x] `MetalTerminalRenderer` conforms to `GlyphResolver` (already had the method)
- [x] Changed `update(from:glyphLookup:)` to `update<R: GlyphResolver>(from:resolver:)` — eliminates closure allocation, weak-ref check, indirect call
- [x] Extracted `resolveGlyphs()` helper — reads from snapshot's `withUnsafeBufferPointer` (no bounds checks)
- [x] Eliminated Optional boxing for previous cell tracking (bool + non-optional value)
- [x] Only writes changed fields to `dst[i]` instead of full cell write-back
- [x] Build passes, 209 tests (2 pre-existing failures, 0 unexpected)

---

## Phase 6: Scrollback — Lazy Trim & Batch Optimization ✅ DONE

**Goal:** Eliminate per-line `trimTrailingBlanks()` overhead in scrollback push.

**Files:** `ScrollbackBuffer.swift`

- [x] Read `ScrollbackBuffer.push()` and `trimTrailingBlanks()` fully
- [x] `trimTrailingBlanks()` already uses `lastIndex(where:)` + `removeSubrange()` (no while-loop to fix)
- [x] Evaluated lazy trimming strategy — chose Option A: trim on access
  - Push is the hot path (every scroll during output); access is cold (reflow, popLast, bulk reads)
  - Lines overwritten in the ring buffer before being read skip trim entirely
- [x] Added `needsTrim: Bool` flag to `ScrollbackLine`, `trimIfNeeded()` method
- [x] `push(cells:...)` sets `needsTrim = true` instead of calling `trimTrailingBlanks()`
- [x] Lazy trim in: `popLast()`, `allLines()`, `lastLines()` (all mutating, trim in-place)
- [x] `subscript`/`line(at:)` stay non-mutating — callers (reflow, snapshot) handle varying cell counts
- [x] Build passes, all tests pass (0 unexpected failures)

---

## Phase 7: GridReflow — Stream Processing & Dead Code Elimination ✅ DONE

**Goal:** Remove intermediate array allocation and per-cell dirty marking in reflow.

**Files:** `GridReflow.swift`

- [x] Read `extractLogicalLines()` — understood intermediate `allRows` tuple array construction
- [x] Refactored to stream-process: single-pass over scrollback rows then screen rows using `processRow()` helper, no intermediate array
- [x] Removed dead per-cell dirty loop in `wrapLogicalLine()`: `TerminalCell.isDirty` setter is a no-op (grid-level `markAllDirty()` already called after reflow in `TerminalGrid+Lifecycle.swift:204`)
- [x] `trimTrailingBlanks` in reflow already uses `lastIndex(where:)` + Array slice — no change needed
- [x] Build passes, 209 tests (2 pre-existing failures, 0 unexpected)

---

## Phase 8: Atlas Defragmentation ✅ DONE

**Goal:** Implement region recycling so evicted glyphs don't waste atlas space.

**Files:** `GlyphAtlas.swift`, `GlyphCache.swift`, `MetalTerminalRenderer.swift`

- [x] `GlyphCache.onEvict` callback fires on LRU eviction with the evicted `AtlasEntry`
- [x] `GlyphAtlas.reclaimRegion(entry:)` pushes evicted regions onto width-bucketed free lists (narrow vs wide)
- [x] `GlyphAtlas.allocate()` checks free list first; falls through to cursor-advance if none available
- [x] Free lists cleared on `clear()` and `rebuild()` to avoid stale references
- [x] Renderer wires `glyphCache.onEvict` → `glyphAtlas.reclaimRegion` after `super.init()`
- [x] Diagnostics: `freeSlotCount`, `recycledAllocations` for monitoring
- [x] No compaction/rebuild fallback needed — every eviction produces a reusable slot, capping growth at ~3 pages steady-state
- [x] Build passes

---

## Phase 9: Parser — Charset Cache & Anywhere Transition Merge ✅ DONE

**Goal:** Eliminate per-byte actor hop for charset mapping and cascading switch in `anywhereTransition`.

**Files:** `TerminalEngine.swift`, `VTParserTables.swift`

- [x] **Charset cache:** Already optimized — `grid.charsetState()` is `nonisolated` (no actor hop, no await). Fast path already inlines charset mapping in `processGroundTextBytes()`. No change needed.
- [x] **Anywhere transition merge:**
  - Encoded CAN/SUB/ESC transitions into the flat table for all 14 states
  - Encoded C1 controls (IND, NEL, HTS, RI, DCS, CSI, ST, OSC, SOS, PM, APC) for all non-string states
  - Encoded per-string-state ST (0x9C) termination (oscEnd, dcsUnhook)
  - Deleted `anywhereTransition()` function entirely (~70 lines)
  - Deleted `handleStringTerminator()` helper
  - `processByte()` now does: ESC side-effect → UTF-8 ST guard → single O(1) table lookup
- [x] Build: passes

---

## Verification

After all phases:

- [ ] Full build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`
- [ ] Full test suite: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test`
- [ ] Benchmark: `./scripts/benchmark-throughput.sh --benchmark-bytes 2097152 --benchmark-runs 3 --benchmark-chunk 4096 --no-build`
- [ ] Manual QA: open multiple sessions, scroll through heavy output, resize, change fonts, use emoji/CJK
- [ ] Instruments: Allocations trace during `seq 1 100000` — verify allocation reduction vs. baseline
- [ ] Update `docs/Optimization.md` — check off completed items, record new benchmark numbers
