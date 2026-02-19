# Terminal Throughput Optimization Checklist

**Target:** `dd if=/dev/urandom bs=1024 count=100000 | base64` completes in 1.5 seconds (~89 MB/s throughput).

**Current:** ~10 minutes (estimated ~220 KB/s throughput — a **400x** gap).

Data pipeline:
```
PTY read (LocalShellChannel) → AsyncStream<Data> → SessionManager (MainActor)
  → VTParser actor → TerminalGrid actor → GridSnapshot → CellBuffer → Metal GPU
```

---

## P0 — CRITICAL (the 400x slowdown lives here)

### Grid

- [ ] **`scrollUp()` COW trap** — `TerminalGrid.swift:467-490`
  `var buf = cells` / `cells = buf` triggers a full copy-on-write of the entire `[[TerminalCell]]`
  array on every scroll. Base64 output at 76 chars/line = ~1.75 million scrolls. Each scroll copies
  10,000 cells (each containing a heap String). This alone accounts for minutes of runtime.
  **Fix:** Use `withActiveCells { buf in ... }` (already exists) instead of the local copy pattern.

- [ ] **Same COW trap in `eraseInLine()`** — `TerminalGrid.swift:564`
- [ ] **Same COW trap in `eraseInDisplay()`** — `TerminalGrid.swift:596`
- [ ] **Same COW trap in `eraseCharacters()`** — `TerminalGrid.swift:655`
- [ ] **Same COW trap in `insertBlanks()`** — `TerminalGrid.swift:700`
- [ ] **Same COW trap in `deleteCharacters()`** — `TerminalGrid.swift:680`
- [ ] **Same COW trap in `insertLines()`** — `TerminalGrid.swift:723`
- [ ] **Same COW trap in `deleteLines()`** — `TerminalGrid.swift:746`
- [ ] **Same COW trap in `screenAlignmentPattern()`** — `TerminalGrid.swift:1309`

- [ ] **Per-character `printCharacter()` overhead** — `TerminalGrid.swift:290-361`
  `processGroundTextBytes` → `printASCIIBytes` calls `printCharacter()` for every single byte.
  Each call does: pendingWrap check, ASCII cache lookup, `char.isWideCharacter` (Unicode check on
  ASCII!), TerminalCell construction, `withActiveCells` closure, `markDirty`, cursor advance.
  At ~133M characters this dominates.
  **Fix:** Write a dedicated bulk fast path inside `printASCIIBytes` that:
  - Skips `isWideCharacter` for ASCII bytes (they're never wide)
  - Calls `withActiveCells` once for the entire run, not per character
  - Calls `markDirty` once for the affected row range, not per character
  - Inlines cursor advance (simple `col += 1` / pending wrap)
  - Handles `performWrap` → `scrollUp` inline within the buffer closure

### Parser

- [ ] **`Data` → `Array<UInt8>` copy in `feed()`** — `VTParser.swift:152`
  `let bytes = Array(next)` copies the entire chunk (~32KB) into a new Array every time.
  **Fix:** Iterate `Data` directly (it conforms to `RandomAccessCollection<UInt8>`) or use
  `data.withUnsafeBytes`.

- [ ] **Second copy for fast-path slice** — `VTParser.swift:164`
  `Array(bytes[start..<index])` creates yet another Array copy for `processGroundTextBytes`.
  **Fix:** Pass `ArraySlice<UInt8>` or `UnsafeBufferPointer<UInt8>` instead.

### PTY Reader

- [x] **Redundant text stream** — `LocalShellChannel.swift:264-265`
  ```swift
  let text = String(decoding: accumulated, as: UTF8.self)
  await self?.yieldOutput(data: accumulated, text: text)
  ```
  The `output: AsyncStream<String>` is **never consumed** by the parser pipeline. This wastes a
  full UTF-8 decode + String allocation on 100% of PTY output.
  **Fix:** Remove the String decoding and `textContinuation.yield` call. Keep only `rawOutput`.
  **Done:** Removed `output: AsyncStream<String>` from `SSHShellChannel` protocol and all
  implementors. Eliminated UTF-8 `String(decoding:as:)` in `LibSSHShellChannel.readLoop()`.

### Actor Isolation Overhead

- [ ] **3 actor boundaries on every chunk** — SessionManager → VTParser → TerminalGrid
  Each `await` hop involves: suspension, executor scheduling, resumption. The parser and grid are
  always accessed sequentially — separate actors add overhead without concurrency benefit.
  **Fix (short-term):** Batch post-feed grid queries. Return sync mode state from `feed()` instead
  of a separate `await grid.synchronizedOutput` hop after every chunk.
  **Fix (long-term):** Merge VTParser and TerminalGrid onto a single actor/serial queue.

---

## P1 — HIGH (2-10x improvements each)

### Parser Table

- [ ] **`VTParserTables` uses `Dictionary` lookup per byte** — `VTParserTables.swift:55-58`
  `tables[state]` hashes the ParserState key on every single byte of terminal input.
  **Fix:** Replace with a flat 2D array: `transitions[state.rawValue * 256 + byte]`.
  Only 14 states × 256 bytes = 3,584 entries (~7KB). Pure O(1) indexed access, no hashing.

- [ ] **Pack `VTTransition` into `UInt16`** — `VTParserTables.swift`
  If `ParserAction` and `ParserState` are both `UInt8`-backed enums, pack them into one `UInt16`
  to halve the transition table size and improve cache line utilization.

### SGR / CSI Handler Actor Overhead

- [ ] **6 actor hops per SGR sequence** — `SGRHandler.swift:45, 359-364`
  Reads state with `await grid.sgrState()`, then applies with 5 separate `await grid.set*()`
  calls.
  **Fix:** Add a single `grid.applySGRState(attrs, fg, bg, ulColor, ulStyle)` method. 6 hops → 1.

- [ ] **`flatParams` allocates an Array on every CSI dispatch** — `CSIHandler.swift:25-27`
  `params.map { $0.first ?? 0 }` creates a new `[Int]` for every cursor move, color change, etc.
  **Fix:** Access params inline: `params[safe: n]?.first ?? 0`. No allocation needed.

- [ ] **All CSI/ESC handlers are `async`** — `CSIHandler.swift`, `ESCHandler.swift`
  Every cursor move, erase, or mode change goes through async/await overhead even though
  the parser and grid could share an actor.
  **Fix:** If parser + grid merge onto one actor, these become synchronous calls.

- [ ] **`setPrivateMode` iterates params for single-param sequences** — `CSIHandler.swift:251-258`
  Most DECSET/DECRST have one parameter. The `for p in params` loop adds overhead.
  **Fix:** Fast-path: `if params.count == 1 { handle(params[0]) } else { for p in ... }`.

### Snapshot Generation

- [x] **`snapshot()` allocates a new `[CellInstance]` every frame** — `TerminalGrid.swift:983`
  At 125 fps × 10,000 cells × 24 bytes = ~30 MB/s allocation churn.
  **Fix:** Pre-allocate a reusable `[CellInstance]` buffer. Only reallocate on resize.
  **Done:** Double-buffered `ContiguousArray<CellInstance>` with `swap()` for unique ownership.
  Indexed writes instead of append. Zero allocation in steady state.

- [ ] **3 `packedRGBA()` calls per cell in `snapshot()`** — `TerminalGrid.swift:1006-1023`
  Each goes through `resolvedRGB()` → switch → `ColorPalette.rgb()`. For `.default`
  (the common case), this is a switch + guard + return per cell, 30,000 evaluations per snapshot.
  **Fix:** Cache the packed RGBA value in `TerminalCell` when the color is set. The snapshot just
  reads the pre-computed value.

- [ ] **`graphemeCluster.unicodeScalars.first` per cell in `snapshot()`** — `TerminalGrid.swift:999`
  String property access + iterator creation per cell during snapshot.
  **Fix:** Store codepoint as `UInt32` in the cell (see P2 cell layout), read it directly.

### InputModeState

- [ ] **`syncFromGrid` does 5 sequential `await` calls** — `InputModeState.swift:79-85`
  Five actor hops to read grid state.
  **Fix:** Single `grid.inputModeSnapshot()` returning all five values at once.

- [ ] **`InputModeState` is its own actor** — `InputModeState.swift:24`
  CSIHandler calls both `await grid.set*()` and `await inputModeState?.set*()`, doubling hops.
  **Fix:** Make `InputModeState` `@MainActor`-isolated or embed it in the grid actor.

---

## P2 — MEDIUM (memory layout, allocation reduction)

### Cell Data Model

- [ ] **`TerminalCell.graphemeCluster` is `String`** — `TerminalCell.swift:78`
  Every cell stores a heap-allocated String. For a 200×50 grid = 10,000 Strings. For 10,000-line
  scrollback × 80 cols = 800,000 Strings.
  **Fix:** Store a `UInt32` codepoint for single-codepoint characters (99%+ of terminal content).
  Use a side-table `[Int: String]` for rare multi-codepoint grapheme clusters.

- [ ] **`TerminalColor` enum has hidden size overhead** — `TerminalCell.swift:13-48`
  Three TerminalColor fields per cell. The `.rgb(UInt8, UInt8, UInt8)` case is 3 bytes payload +
  1 byte discriminator, but Swift enum alignment may expand this to 5-8 bytes per color.
  **Fix:** Pack each TerminalColor into a `UInt32`: high byte = tag (0=default, 1=indexed, 2=rgb),
  lower 3 bytes = color data. Reduces each color from ~5-8 bytes to 4 bytes.

- [ ] **`TerminalCell.isBlank` does String operations** — `TerminalCell.swift:135-142`
  `graphemeCluster.isEmpty || graphemeCluster == " "` on every blank check.
  **Fix:** With UInt32 codepoint, becomes `codepoint == 0 || codepoint == 0x20`.

### Glyph Pipeline

- [ ] **`GlyphCache.Node` is a class (heap allocation)** — `GlyphCache.swift:51`
  Every new cache entry heap-allocates a linked list Node.
  **Fix:** Use a flat array-based LRU with integer indices. Dictionary maps
  `GlyphKey → Int` (index into the flat array). Eliminates per-entry heap allocations.

- [ ] **`GlyphCache.insert` clears `lastEvictedKeys` every time** — `GlyphCache.swift:134`
  `lastEvictedKeys.removeAll(keepingCapacity: true)` on every cache miss. The evicted keys
  are never consumed (atlas has no region recycling).
  **Fix:** Remove `lastEvictedKeys` tracking entirely, or only track when atlas recycling is added.

- [ ] **`GlyphCache.trackedLookup` double function call** — `GlyphCache.swift:261-268`
  Wraps `lookup()` adding an extra function call on the hottest render path.
  **Fix:** Mark as `@inline(__always)` or merge into the call site.

- [ ] **`GlyphRasterizer` allocates pixel buffer per glyph** — `GlyphRasterizer.swift:146`
  `[UInt8](repeating: 0, count: bufferSize)` — heap allocation per rasterization.
  **Fix:** Reuse a single pre-allocated scratch buffer (rasterization is single-threaded).

- [ ] **`CGContext` created per glyph** — `GlyphRasterizer.swift:167`
  `CGContext` creation is expensive. Each rasterization creates and destroys one.
  **Fix:** Create one context at max cell size, reuse it. Clear with `memset` between uses.

- [ ] **`NSAttributedString` + `CTLine` per glyph** — `GlyphRasterizer.swift:104-108`
  For single-codepoint glyphs (99% of cases), this is massive overkill.
  **Fix:** Use `CTFontGetGlyphsForCharacters` + `CTFontDrawGlyphs` directly — bypasses the
  entire attributed string / CTLine pipeline. 10-50x faster for single glyphs.

- [ ] **`CTFontCreateWithName` per cache miss** — `MetalTerminalRenderer.swift:377-378`
  Bridges String → CFString and calls CoreText per glyph rasterization.
  **Fix:** Cache the base CTFont and bold/italic/boldItalic variants as instance vars.
  Only recreate on font/scale change.

- [ ] **`CGColorSpaceCreateDeviceRGB()` per glyph** — `GlyphRasterizer.swift:155, 160`
  May or may not return a cached singleton.
  **Fix:** Cache as a `static let` property.

- [ ] **BGRA→RGBA swizzle is scalar** — `GlyphRasterizer.swift:351-361`
  Processes one pixel at a time in a loop.
  **Fix:** Process as `UInt32` words (swap bytes with bitwise ops), or use SIMD/Accelerate.
  Better yet, use `.bgra8Unorm` texture format and skip the swizzle entirely.

- [ ] **`computeSubpixelPenX` is a no-op** — `GlyphRasterizer.swift:239-250`
  Discards both parameters and returns 0. Dead code.
  **Fix:** Remove the function, replace calls with `0`.

- [ ] **`resolveRenderFont` allocates String + CFString + Arrays per cache miss** —
  `MetalTerminalRenderer.swift:445-475`
  **Fix:** For BMP codepoints (value ≤ 0xFFFF), use a stack-allocated `UInt16` directly with
  `CTFontGetGlyphsForCharacters`. No String/Array needed.

- [ ] **`isEmojiRange` cascading if-chain** — `MetalTerminalRenderer.swift:480-521`
  ~20 `ClosedRange.contains()` checks in sequence.
  **Fix:** Early exit at `v < 0x2300`, then binary search over a sorted range table.

- [ ] **Duplicate emoji/CJK/Powerline range tables** — 4 files
  `MetalTerminalRenderer.isEmojiRange`, `GlyphRasterizer.isEmojiCodepoint`,
  `CharacterWidth.isWide`, `FontManager.isEmojiScalar/isCJKScalar/isPowerlineScalar`.
  **Fix:** Consolidate into a single `UnicodeClassification` module.

### Tab Stops

- [ ] **`tabStops` uses `Set<Int>` — hashes on every lookup** — `CursorState.swift:178-186`
  `!tabStops.contains(nextCol)` hashes an Int up to 7 times per tab.
  **Fix:** Replace with `[Bool]` lookup array indexed by column. 80 bytes, O(1) direct indexing.

- [ ] **`reverseToTab` has the same Set lookup issue** — `CursorState.swift:189-196`

### CellBuffer

- [ ] **Per-cell loop in `update()`** — `CellBuffer.swift:186-216`
  Each cell is read, modified, written individually. Prevents SIMD optimization.
  **Fix:** `memcpy` the dirty range first, then fix up glyph indices in a second pass. Most cells
  don't need glyph changes between frames.

- [ ] **`isContinuationCell` re-reads previous cell every iteration** — `CellBuffer.swift:234-251`
  `snapshot.cells[index - 1]` — array bounds check + struct copy per cell.
  **Fix:** Carry a `previousWasWide: Bool` through the loop.

- [ ] **`glyphLookup` closure called per non-empty cell** — `CellBuffer.swift:212`
  Closure capture involves retain/release cycle.
  **Fix:** Pass as a direct function reference or inline the glyph resolution.

### Scrollback

- [ ] **`trimTrailingBlanks()` uses `removeLast()` in a while loop** — `ScrollbackBuffer.swift:30-33`
  **Fix:** Find trim index first via reverse scan, then truncate once.

- [ ] **`push` calls `trimTrailingBlanks` on every line** — `ScrollbackBuffer.swift:89`
  **Fix:** Trim lazily (on access) or batch-trim periodically.

- [ ] **`allLines()` copies entire ring buffer** — `ScrollbackBuffer.swift:159-167`
  Per-element subscript with modulo arithmetic.
  **Fix:** Return a lazy view, or bulk copy the two contiguous segments.

- [ ] **`search()` allocates String per scrollback line** — `ScrollbackBuffer.swift:184-197`
  `line.cells.map { $0.graphemeCluster }.joined()` — N allocations per search iteration.
  **Fix:** Build a reusable buffer, or search on raw codepoints.

- [ ] **`ScrollbackLine.cells` stores String per cell** — `ScrollbackBuffer.swift`
  Same issue as `TerminalCell.graphemeCluster` — 800,000 Strings for 10K-line scrollback.
  **Fix:** Use the UInt32 codepoint representation (see P2 cell data model above).

---

## P3 — LOW (polish, minor wins)

### Rendering

- [ ] **Continuous rendering when idle** — `MetalTerminalRenderer.swift:948-949`
  `view.isPaused = false; view.enableSetNeedsDisplay = false` — redraws at 60-120 fps
  even with no changes. Wastes GPU/CPU.
  **Fix:** Use `enableSetNeedsDisplay = true` and call `setNeedsDisplay` only when a new
  snapshot arrives. Or gate the encoder path on `isDirty`.

- [ ] **`CACurrentMediaTime()` called twice per frame** — `MetalTerminalRenderer.swift:669, 706`
  **Fix:** Call once, reuse the value.

- [ ] **Performance monitor creates `OSSignpostID` every frame** — `RendererPerformanceMonitor.swift:36`
  Heap allocation 60-120 times/sec.
  **Fix:** Gate behind `#if DEBUG` or use a single reusable signpost ID.

- [ ] **`commandBuffer.label = "TerminalFrame"` per frame** — `MetalTerminalRenderer.swift:653`
  **Fix:** Gate behind `#if DEBUG`.

- [ ] **Performance monitor `removeFirst` is O(n)** — `RendererPerformanceMonitor.swift:87-92`
  Shifts up to 240 elements every frame.
  **Fix:** Use a ring buffer (circular array with head/tail indices).

- [ ] **Performance monitor `percentile` sorts on every call** — `RendererPerformanceMonitor.swift:101`
  Allocates a sorted copy of up to 240 elements.
  **Fix:** Cache the sorted array, invalidate on append.

### Selection

- [ ] **`applySelection` always called even with no selection** — `MetalTerminalRenderer.swift:538`
  **Fix:** Check `selection == nil && !needsFullRefresh` before calling.

- [ ] **`applySelection` iterates ALL cells to clear flags** — `SelectionRenderer.swift:73-78`
  Maps over every cell just to clear one bit, triggering a full Array copy.
  **Fix:** Track whether any cells were previously selected. Skip the pass if not.

- [ ] **`applySelection` with selection does two passes** — `SelectionRenderer.swift:97-112`
  First clears all flags, then sets flags on selected cells.
  **Fix:** Single pass: set or clear per cell based on whether it's in the selection range.

- [ ] **`refreshSelectionColorFromSystemAccent` does color space conversion** —
  `SelectionRenderer.swift:52`
  **Fix:** Cache the result. Only recompute on system accent color change.

### Cursor

- [ ] **`CursorRenderer.frame(at:)` lerps every frame even when static** — `CursorRenderer.swift:114`
  Asymptotic lerp never converges exactly.
  **Fix:** Snap to target when `abs(delta) < epsilon`.

### SwiftUI / View Layer

- [ ] **`UserDefaults.didChangeNotification` fires on ANY change** —
  `MetalTerminalSessionSurface.swift:133-143`
  Reloads gradient/CRT/scanner settings on unrelated preference changes.
  **Fix:** Observe specific keys only.

- [ ] **`updateNSView` reassigns closures every SwiftUI update** — `TerminalMetalView.swift:64-70`
  Closure assignment involves reference counting.
  **Fix:** Compare before assigning, or use stable references.

- [ ] **`NSVisualEffectView` always active** — `TerminalMetalView.swift:117-148`
  The blur view consumes GPU even when background opacity is 1.0 (fully opaque).
  **Fix:** Hide or remove when opacity is 1.0.

- [ ] **Each session creates its own `FontManager`** — `MetalTerminalSessionSurface.swift:127-129`
  **Fix:** Share a single `FontManager` across sessions.

### OSC / String Handling

- [ ] **OSC handler creates Strings from raw bytes** — `OSCHandler.swift:50, 55`
  `String(bytes:encoding:)` allocates heap Strings for OSC code parsing.
  **Fix:** Parse OSC code number directly from ASCII digit bytes. No String needed.

- [ ] **`hexPair` uses `String(format:)`** — `OSCHandler.swift:358-359`
  Foundation/ObjC call for trivial hex conversion.
  **Fix:** Lookup table or manual hex conversion.

- [ ] **DSR/DECRQM response uses String interpolation** — `CSIHandler.swift:429-432`
  Creates String + `Array(response.utf8)` — two allocations.
  **Fix:** Build byte array directly from integer digits.

### Font Manager

- [ ] **`fontContainsGlyph` allocates arrays** — `FontManager.swift:648-653`
  `Array(String(scalar).utf16)` + `[CGGlyph]` per glyph check.
  **Fix:** For BMP codepoints, use stack variables: `var char: UInt16; var glyph: CGGlyph`.

- [ ] **`createFontIfAvailable` uses `lowercased()`** — `FontManager.swift:431, 437`
  Allocates new Strings for comparison.
  **Fix:** Use `caseInsensitiveCompare` instead.

### GridReflow

- [ ] **`extractLogicalLines` creates intermediate array** — `GridReflow.swift:174-231`
  Copies all scrollback + screen rows before processing.
  **Fix:** Stream-process without the intermediate array.

- [ ] **`wrapLogicalLine` marks every cell dirty individually** — `GridReflow.swift:267-269`
  **Fix:** Set a "whole grid dirty" flag instead.

- [ ] **`trimTrailingBlanks` in reflow triggers COW** — `GridReflow.swift:433-439`
  `var trimmed = cells` + `removeLast()` loop.
  **Fix:** Reverse-scan for trim index, then slice once.

### Atlas

- [ ] **No atlas defragmentation or region reuse** — `GlyphAtlas.swift`
  Atlas is append-only. Evicted glyphs leave dead space.
  **Fix:** Implement region recycling, or full rebuild when nearing capacity.

- [ ] **`texture(forPage:)` bounds-checks every frame** — `GlyphAtlas.swift:107-109`
  Page count is almost always 1.
  **Fix:** Cache the page-0 texture as a direct reference.

### Charset

- [ ] **`CharsetHandler.mapCharacter` always runs for slow-path bytes** — `VTParser.swift:411-412`
  `await grid.charsetState()` — actor hop per non-ASCII character in slow path.
  **Fix:** Cache charset state locally in the parser. Only re-fetch on charset change sequences.

### Parser Internals

- [ ] **`anywhereTransition` cascading switch per byte** — `VTParser.swift:237-303`
  Two switch statements evaluated for every byte that isn't fast-pathed.
  **Fix:** Merge into the precomputed transition table. The table should encode anywhere
  transitions directly, eliminating this function entirely.

---

## Architecture Notes

### Why actors hurt throughput here

Swift actors provide mutual exclusion, but VTParser and TerminalGrid are never accessed
concurrently — the parser always calls the grid sequentially. The actor boundary adds:
- Suspension point overhead per `await`
- Executor scheduling (even if immediately runnable)
- Stack frame save/restore

For a byte stream of 133 million characters, even microseconds per hop become seconds.

The ideal architecture for raw throughput:
1. **Single actor** owns both parser state and grid state
2. Parser methods call grid methods as **synchronous function calls** (no `await`)
3. Snapshot generation is the **only** async boundary (grid actor → MainActor for rendering)
4. PTY reader feeds data into this single actor via one `await` per chunk

### Memory layout ideal

Replace `TerminalCell` (currently ~48+ bytes with String + 3 enums + attributes) with a
packed 16-byte struct:
```
UInt32 codepoint        // 4 bytes (0 = blank, side-table for grapheme clusters)
UInt32 fgColor          // 4 bytes (packed: tag byte + RGB)
UInt32 bgColor          // 4 bytes
UInt16 attributes       // 2 bytes
UInt8  width            // 1 byte
UInt8  underlineStyle   // 1 byte
                        // = 16 bytes total, down from ~48+
```

This eliminates all String heap allocations in the grid and halves the memory footprint.
The snapshot generation becomes a near-trivial memcpy since the cell layout is already
GPU-compatible.
